# frozen_string_literal: true

require 'rake'
require 'rake/tasklib'

module MigrationTools
  class Tasks < ::Rake::TaskLib
    def initialize
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

    def migrations_paths
      ActiveRecord::Migrator.migrations_paths
    end

    def database_configs_hash
      @database_configs_hash ||= ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
    end

    def multi_database_setup?
      @multi_database_setup ||= if ActiveRecord::VERSION::MAJOR >= 6
                                  database_configs_hash.reject { |c| c.spec_name.end_with?('_replica') }.size > 1
                                else
                                  false
                                end
    end

    def migrator(target_version = nil)
      if ActiveRecord::VERSION::MAJOR >= 6
        migrate_up(ActiveRecord::MigrationContext.new(
          migrations_paths,
          ActiveRecord::SchemaMigration
        ).migrations, ActiveRecord::SchemaMigration, target_version)
      elsif ActiveRecord::VERSION::MAJOR == 5 && ActiveRecord::VERSION::MINOR == 2
        migrate_up(ActiveRecord::MigrationContext.new(migrations_paths).migrations, target_version)
      else
        migrate_up(ActiveRecord::Migrator.migrations(migrations_paths), target_version)
      end
    end

    def migrate_up(migrations, schema_migration, target_version)
      if ActiveRecord::VERSION::MAJOR >= 6
        ActiveRecord::Migrator.new(:up, migrations, schema_migration, target_version)
      else
        ActiveRecord::Migrator.new(:up, migrations, target_version)
      end
    end

    def migrator_for_multi_database(db_config, target_version)
      connection = ActiveRecord::Base.establish_connection(db_config.config).connection

      migrations_paths = db_config.config[:migrations_paths] || db_config.config['migrations_paths'] || 'db/migrate'

      migrations_paths = Array(migrations_paths)

      migrations = ActiveRecord::MigrationContext.new(migrations_paths, connection.schema_migration).migrations

      migrate_up(migrations, connection.schema_migration, target_version)
    end

    def multi_db_pending_migrations
      return @multi_db_pending_migrations if defined?(@multi_db_pending_migrations) && @multi_db_pending_migrations

      @multi_db_pending_migrations ||= database_configs_hash.each_with_object({}) do |db_config, hash|
        single_db_migrator = migrator_for_multi_database(db_config, nil)
        hash[db_config.spec_name] = {
          pending_migrations: filter_pending_migrations_for_group(single_db_migrator.pending_migrations),
          db_config: db_config
        }
      end

      @multi_db_pending_migrations
    end

    def pending_migrations
      return [] if multi_database_setup?
      return @pending_migrations if defined?(@pending_migrations) && @pending_migrations

      @pending_migrations = filter_pending_migrations_for_group(migrator.pending_migrations)

      @pending_migrations
    end

    def filter_pending_migrations_for_group(pending_migrations)
      pending_migrations.select { |proxy| group.empty? || proxy.migration_group == group }
    end

    def notify_pending_migrations(pending_migrations)
      pending_migrations.each do |migration|
        notify format('  %4d %s %s', migration.version, migration.migration_group.to_s[0..5].center(6),
                      migration.name)
      end
    end

    def check_multi_db_pending_migrations
      count = 0
      multi_db_pending_migrations.each do |db_name, db_hash|
        pending_migrations = db_hash[:pending_migrations]
        next unless pending_migrations.any?

        count += 1
        notify "You have #{pending_migrations.size} pending migrations for #{db_name}", group
        notify_pending_migrations(pending_migrations)
      end

      notify 'Your databases schemas are up to date' if count.zero?
    end

    def any_pending_migrations_for_multi_database?
      multi_db_pending_migrations.any? { |_, db_hash| db_hash[:pending_migrations].any? }
    end

    def run_migrations_for_multi_database
      multi_db_pending_migrations.each do |db_name, db_hash|
        pending_migrations = db_hash[:pending_migrations]
        db_config = db_hash[:db_config]
        next unless pending_migrations.any?

        notify "Running #{group.upcase} migrations for #{db_name}"
        pending_migrations.each do |migration|
          migrator_for_multi_database(db_config, migration.version).run
        end

        Rake::Task['db:schema:dump'].invoke if ActiveRecord::Base.schema_format == :ruby
        Rake::Task['db:structure:dump'].invoke if ActiveRecord::Base.schema_format == :sql
      end
    end

    def define_migrate_list
      namespace :db do
        namespace :migrate do
          desc 'Lists pending migrations'
          task list: :environment do
            if multi_database_setup?
              check_multi_db_pending_migrations
            elsif pending_migrations.empty?
              notify 'Your database schema is up to date', group
            else
              notify "You have #{pending_migrations.size} pending migrations", group
              notify_pending_migrations(pending_migrations)
            end
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
            elsif multi_database_setup?
              run_migrations_for_multi_database
            elsif pending_migrations.empty?
              notify 'Your database schema is up to date'
            else
              pending_migrations.each do |migration|
                migrator(migration.version).run
              end

              Rake::Task['db:schema:dump'].invoke if ActiveRecord::Base.schema_format == :ruby
              Rake::Task['db:structure:dump'].invoke if ActiveRecord::Base.schema_format == :sql
            end
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
                desc "#{ns == :list ? 'Lists' : 'Executes'} the migrations for group #{migration_group}"
                task migration_group => :environment do
                  self.group = migration_group.to_s
                  Rake::Task["db:migrate:#{ns}"].invoke
                  Rake::Task["db:migrate:#{ns}"].reenable
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
              if any_pending_migrations_for_multi_database? || pending_migrations.any?
                abort 'Run "rake db:migrate" to update your database then try again.'
              end
            end
          end
        end
      end
    end

    def notify(string, group = '')
      if group.empty?
        puts string
      else
        puts "#{string} for group \"#{group}\""
      end
    end
  end
end
