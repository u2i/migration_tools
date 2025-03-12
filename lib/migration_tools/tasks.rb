require 'rake'
require 'rake/tasklib'

module MigrationTools
  class Tasks < ::Rake::TaskLib
    def initialize
      @migrations_hash = {}
      define_migrate_list
      define_migrate_group
      define_convenience_tasks
    end

    def group
      return @group if defined?(@group) && @group

      @group = ENV['GROUP'].to_s
      raise "Invalid group \"#{@group}\"" if !@group.empty? && !MIGRATION_GROUPS.member?(@group)

      @group
    end

    def group=(group)
      @group = nil
      @pending_migrations = nil
      ENV['GROUP'] = group
    end

    def database
      @database = ENV['DATABASE'].to_s
      @database
    end

    def database=(database)
      @database = nil
      ENV['DATABASE'] = database
    end

    # TODO: that works
    def define_migrate_list
      namespace :db do
        namespace :migrate do
          desc 'Lists pending migrations'
          task list: :environment do
            notify 'Checking pending migrations for all groups across all databases', true
            check_system_migrations
            require 'pry'
            binding.pry
          end
        end
      end
    end

    def define_migrate_group
      namespace :db do
        namespace :migrate do
          desc 'Runs pending migrations for a given group'
          task group: :environment do
            if group.empty?
              notify 'Please specify a migration group'
            elsif multi_database_setup? && database.empty?
              run_for_all_databases
            else
              run_pending_migrations_for_db_and_group(database, @migrations_hash[database][group])
            end
            reset_migrations_hash
          end
        end
      end
    end

    def define_convenience_tasks
      namespace :db do
        namespace :migrate do
          %i[list group].each do |ns|
            namespace ns do
              MigrationTools::MIGRATION_GROUPS.each do |migration_group|
                task migration_group => :environment do
                  self.group = migration_group.to_s
                  check_migrations_for_group
                  ns == :group ? run_pending_migrations_for_db_and_group(database, @migrations_hash[database][group]) : nil
                end
              end
            end
          end
        end

        namespace :abort_if_pending_migrations do
          MigrationTools::MIGRATION_GROUPS.each do |migration_group|
            desc "Raises an error if there are pending #{migration_group} migrations"
            task migration_group do
              self.group = migration_group.to_s
              Rake::Task['db:migrate:list'].invoke
              Rake::Task['db:migrate:list'].reenable
              abort 'Run "rake db:migrate" to update your database then try again.' if @migrations_hash.empty?
            end
          end
        end
      end
    end

    attr_reader :migrations_hash

    private

    def multi_database_setup?
      @multi_database_setup ||= if ActiveRecord::VERSION::MAJOR >= 6
                                  configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
                                  configs.reject { |c| c.spec_name.end_with?('_replica') }.size > 1
                                else
                                  false
                                end
    end

    def run_for_all_databases
      check_system_migrations

      @migrations_hash.each do |db_name, groups|
        notify "Processing migrations for #{db_name} database"
        self.database = db_name

        groups.each do |group_name, migrations|
          next unless group_name == group

          run_pending_migrations_for_db_and_group(db_name, migrations)
        end
      end
    end

    def reset_migrations_hash
      @migrations_hash = {}
    end

    def check_system_migrations
      reset_migrations_hash
      if group.empty?
        MigrationTools::MIGRATION_GROUPS.each do |migration_group|
          self.group = migration_group.to_s
          check_migrations_for_group
        end
      else
        check_migrations_for_group
      end
      @migrations_hash
    end

    def check_migrations_for_group
      notify "\n\t\t#{group.upcase}"

      if multi_database_setup?
        check_all_databases
      else
        check_pending_for_database(nil)
      end
    end

    def validate_group!(group_name)
      return if MigrationTools::MIGRATION_GROUPS.include?(group_name)

      raise "Invalid group \"#{group_name}\". Valid groups are: #{MigrationTools::MIGRATION_GROUPS.join(', ')}"
    end

    def check_all_databases
      database_configs_hash.each do |config_hash|
        notify "\n== Checking #{config_hash.spec_name} database =="
        self.database = config_hash&.spec_name
        check_pending_for_database(config_hash)
      end
    end

    def database_configs_hash
      @database_configs_hash ||= ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
    end

    def database_connection(db_config)
      if db_config
        validate_adapter!(db_config)

        ActiveRecord::Base.establish_connection(db_config.config).connection
      else
        ActiveRecord::Base.connection
      end
    end

    def validate_adapter!(db_config)
      return if db_config.config[:adapter] || db_config.config['adapter']

      raise "No adapter specified for database #{db_config.spec_name}"
    end

    def get_migrations_paths(db_config_hash)
      if db_config_hash
        migrations_paths = db_config_hash.config[:migrations_paths] || db_config_hash.config['migrations_paths']
        Array(migrations_paths || 'db/migrate/')
      else
        Array(ActiveRecord::Migrator.migrations_paths)
      end
    end

    def check_pending_for_database(db_config_hash)
      connection = database_connection(db_config_hash)
      executed_versions = connection.select_all('SELECT version FROM schema_migrations').to_a.map { |r| r['version'] }
      paths = get_migrations_paths(db_config_hash)

      pending_count = check_pending_migrations(paths, executed_versions)

      display_results(pending_count)
    ensure
      restore_connection
    end

    def check_pending_migrations(paths, executed_versions)
      pending_count = 0
      notify "\nChecking migrations in paths: #{paths.join(', ')}"

      db_key = database.presence || 'primary'

      paths.each do |path|
        next unless File.directory?(path)

        Dir.glob(File.join(path, '*.rb')).sort.each do |file|
          version = File.basename(file).split('_').first
          next if executed_versions.include?(version)

          content = File.read(file)
          next unless content =~ /group\s+:#{group}\b/

          pending_count += 1
          migration_name = File.basename(file)
          notify "Pending: #{version} - #{migration_name}"

          @migrations_hash[db_key] ||= {}
          @migrations_hash[db_key][group] ||= []
          @migrations_hash[db_key][group] << version
        end
      end

      pending_count
    end

    def display_results(pending_count)
      if pending_count.zero?
        notify "No pending migrations for group '#{group}' from #{database.presence ? database : 'primary'}"
      else
        notify "Found #{pending_count} pending migration(s) for group '#{group}' from #{database.presence ? database : 'primary'}"
      end
    end

    # TODO: is this necessary?
    def restore_connection
      ActiveRecord::Base.establish_connection(Rails.env.to_sym)
    end

    def run_pending_migrations_for_db_and_group(db_name, migrations)
      migrations.each do |migration|
        execute_migration(db_name, migration)
      end
    end

    def execute_migration(db_name, migration)
      notify "Executing migration #{migration} for #{db_name} database"
      ENV['VERSION'] = migration
      Rake::Task["db:migrate:#{db_name}"].invoke
      Rake::Task["db:migrate:#{db_name}"].reenable

      # Remove migration from hash after executing
      @migrations_hash[db_name][group]&.delete(migration)
    end

    def notify(string, mark = false)
      message = string
      message = "----- #{message} -----" if mark

      puts message
    end
  end
end
