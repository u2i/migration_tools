# frozen_string_literal: true

require File.expand_path 'helper', __dir__

describe MigrationTools do
  before do
    ENV['GROUP'] = nil

    ActiveRecord::Base.establish_connection(
      adapter: 'sqlite3',
      database: ':memory:'
    )

    Rake::Task.clear
    Rake::Task.define_task('environment')
    Rake::Task.define_task('db:schema:dump')
    Rake::Task.define_task('db:structure:dump')

    @task = MigrationTools::Tasks.new
  end

  after do
    MigrationTools.instance_variable_set('@forced', false)
  end

  def migrations
    [Alpha, Beta, Delta, Kappa]
  end

  def proxies
    @proxies ||= migrations.map { |m| migration_proxy(m) }
  end

  def migration_proxy(m)
    name = m.name
    version = migrations.index(m)

    proxy = ActiveRecord::MigrationProxy.new(name, version, nil, nil)
    proxy.instance_variable_set(:@migration, m.new)
    proxy
  end

  it 'grouping' do
    assert_equal([Alpha, Beta], migrations.select { |m| m.migration_group == 'before' })
    assert_equal([Delta], migrations.select { |m| m.migration_group == 'change' })
    assert_equal([Kappa], migrations.select { |m| m.migration_group.nil? })
  end

  it 'runtime_checking' do
    eval("class Kappa < MIGRATION_CLASS; group 'drunk'; end")
    raise 'You should not be able to specify custom groups'
  rescue RuntimeError => e
    assert e.message.index('Invalid group "drunk" - valid groups are ["before", "during", "after", "change"]')
  end

  it 'migration_proxy_delegation' do
    proxy = ActiveRecord::MigrationProxy.new(:name, :version, :filename, :scope)
    proxy.expects(:migration).returns(Delta)
    assert_equal 'change', proxy.migration_group
  end

  it 'forcing' do
    assert !MigrationTools.forced?
    MigrationTools.forced!
    assert MigrationTools.forced?

    @task.migrator(0).run

    begin
      @task.migrator(3).run
      raise 'You should not be able to run migrations without groups in forced mode'
    rescue StandardError => e
      assert e.message =~ /Cowardly refusing/
    end
  end

  it 'task_presence' do
    assert Rake::Task['db:migrate:list']
    assert Rake::Task['db:migrate:group']
    assert Rake::Task['db:migrate:group:before']
    assert Rake::Task['db:migrate:group:during']
    assert Rake::Task['db:migrate:group:after']
    assert Rake::Task['db:migrate:group:change']
  end

  it 'migrate_list_without_pending_without_group' do
    0.upto(3).each { |i| @task.migrator(i).run }

    MigrationTools::Tasks.any_instance.expects(:notify).with('Your database schema is up to date', '').once

    Rake::Task['db:migrate:list'].invoke
  end

  it 'migrate_list_without_pending_with_group' do
    @task.migrator(0).run
    @task.migrator(1).run

    MigrationTools::Tasks.any_instance.expects(:notify).with('Your database schema is up to date', 'before').once

    ENV['GROUP'] = 'before'
    Rake::Task['db:migrate:list'].invoke
  end

  it 'migrate_list_with_pending_without_group' do
    MigrationTools::Tasks.any_instance.expects(:notify).with('You have 4 pending migrations', '').once
    MigrationTools::Tasks.any_instance.expects(:notify).with('     0 before Alpha').once
    MigrationTools::Tasks.any_instance.expects(:notify).with('     1 before Beta').once
    MigrationTools::Tasks.any_instance.expects(:notify).with('     2 change Delta').once
    MigrationTools::Tasks.any_instance.expects(:notify).with('     3        Kappa').once

    Rake::Task['db:migrate:list'].invoke
  end

  it 'migrate_list_with_pending_with_group' do
    ENV['GROUP'] = 'before'

    MigrationTools::Tasks.any_instance.expects(:notify).with('You have 2 pending migrations', 'before').once
    MigrationTools::Tasks.any_instance.expects(:notify).with('     0 before Alpha').once
    MigrationTools::Tasks.any_instance.expects(:notify).with('     1 before Beta').once

    Rake::Task['db:migrate:list'].invoke
  end

  it 'abort_if_pending_migrations_with_group_without_migrations' do
    @task.stubs(:notify)

    begin
      Rake::Task['db:abort_if_pending_migrations:after'].invoke
    rescue SystemExit
      raise "aborted where it shouldn't"
    end
  end

  if ActiveRecord::VERSION::STRING >= '5.0.0'
    require 'active_support/testing/stream'
    include ActiveSupport::Testing::Stream
  end
  it 'abort_if_pending_migrations_with_group_with_migrations' do
    assert_raises(SystemExit, 'did not abort') do
      silence_stream($stdout) do
        silence_stream($stderr) do
          Rake::Task['db:abort_if_pending_migrations:before'].invoke
        end
      end
    end
  end

  it 'migrate_group_with_group_without_pending' do
    @task.migrator(0).run
    @task.migrator(1).run

    MigrationTools::Tasks.any_instance.expects(:notify).with('Your database schema is up to date').once

    ENV['GROUP'] = 'before'
    Rake::Task['db:migrate:group'].invoke
  end

  it 'migrate_group_with_pending' do
    ENV['GROUP'] = 'before'

    assert_equal 4, @task.migrator.pending_migrations.count

    Rake::Task['db:migrate:group'].invoke

    assert_equal 2, @task.migrator.pending_migrations.count
  end

  it 'migrate_with_invalid_group' do
    ENV['GROUP'] = 'drunk'

    begin
      Rake::Task['db:migrate:group'].invoke
      raise 'Should throw an error'
    rescue RuntimeError => e
      assert e.message =~ /Invalid group/
    end
  end

  it 'convenience_list_method' do
    MigrationTools::Tasks.any_instance.expects(:notify).with('You have 2 pending migrations', 'before').once
    MigrationTools::Tasks.any_instance.expects(:notify).with('     0 before Alpha').once
    MigrationTools::Tasks.any_instance.expects(:notify).with('     1 before Beta').once

    Rake::Task['db:migrate:list:before'].invoke
  end

  # New tests for multi-database functionality
  describe 'multi-database functionality' do
    before do
      unless ActiveRecord::VERSION::MAJOR >= 6 && ActiveRecord::Base.configurations.respond_to?(:configs_for)
        skip 'Multi-database functionality requires ActiveRecord 6.0+'
      end

      # Mock the database_configs_hash method to simulate multiple databases
      @primary_config = mock('primary_config')
      @primary_config.stubs(:spec_name).returns('primary')
      @primary_config.stubs(:config).returns({
                                               adapter: 'sqlite3',
                                               database: ':memory:'
                                             })

      @secondary_config = mock('secondary_config')
      @secondary_config.stubs(:spec_name).returns('secondary')
      @secondary_config.stubs(:config).returns({
                                                 adapter: 'sqlite3',
                                                 database: ':memory:',
                                                 migrations_paths: 'db/secondary_migrate'
                                               })

      @configs = [@primary_config, @secondary_config]
      @task.stubs(:database_configs_hash).returns(@configs)
    end

    it 'detects multi-database setup' do
      assert @task.multi_database_setup?, 'Should detect multi-database setup'
    end

    it 'returns pending migrations for each database' do
      # Setup mock migration contexts
      connection = mock('connection')

      schema_migration = mock('schema_migration')
      connection.stubs(:schema_migration).returns(schema_migration)

      ActiveRecord::Base.stubs(:establish_connection).returns(mock('ar_connection'))
      ActiveRecord::Base.connection.stubs(:establish_connection).returns(connection)

      migration_context = mock('migration_context')
      migration_context.stubs(:migrations).returns(proxies)
      ActiveRecord::MigrationContext.stubs(:new).returns(migration_context)

      # Execute the method
      result = @task.multi_db_pending_migrations

      # Verify results
      assert_equal 2, result.size, 'Should return info for 2 databases'
      assert result.key?('primary'), 'Should include primary database'
      assert result.key?('secondary'), 'Should include secondary database'
      assert result['primary'].key?(:pending_migrations), 'Should include pending migrations for primary'
      assert result['secondary'].key?(:pending_migrations), 'Should include pending migrations for secondary'
    end

    it 'checks for pending migrations across all databases' do
      # Setup for a case WITH pending migrations
      @task.stubs(:multi_db_pending_migrations).returns({
                                                          'primary' => { pending_migrations: [proxies.first],
                                                                         db_config: @primary_config },
                                                          'secondary' => { pending_migrations: [],
                                                                           db_config: @secondary_config }
                                                        })
      assert @task.any_pending_migrations_for_multi_database?, 'Should detect pending migrations'

      # Setup for a case WITHOUT pending migrations
      @task.stubs(:multi_db_pending_migrations).returns({
                                                          'primary' => { pending_migrations: [],
                                                                         db_config: @primary_config },
                                                          'secondary' => { pending_migrations: [],
                                                                           db_config: @secondary_config }
                                                        })
      assert_equal false, @task.any_pending_migrations_for_multi_database?,
                   'Should not detect pending migrations when there are none'
    end

    it 'runs migrations for multiple databases' do
      # Setup migrations
      @task.stubs(:multi_db_pending_migrations).returns({
                                                          'primary' => {
                                                            pending_migrations: [proxies.first],
                                                            db_config: @primary_config
                                                          },
                                                          'secondary' => {
                                                            pending_migrations: [proxies[1]],
                                                            db_config: @secondary_config
                                                          }
                                                        })

      # Expect migrations to be run for each database
      single_db_migrator = mock('single_db_migrator')
      single_db_migrator.expects(:run).times(2)
      @task.expects(:migrator_for_multi_database).with(@primary_config,
                                                       proxies.first.version).returns(single_db_migrator)
      @task.expects(:migrator_for_multi_database).with(@secondary_config,
                                                       proxies[1].version).returns(single_db_migrator)

      # Expect schema dump
      @task.expects(:dump_schema).times(2)

      # Execute the method
      @task.run_migrations_for_multi_database
    end
    it 'lists pending migrations for multi-database' do
      # Setup
      ENV['GROUP'] = 'before'
      @task.stubs(:multi_database_setup?).returns(true)
      @task.stubs(:multi_db_pending_migrations).returns({
                                                          'primary' => {
                                                            pending_migrations: [proxies[0]],
                                                            db_config: @primary_config
                                                          },
                                                          'secondary' => {
                                                            pending_migrations: [proxies[1]],
                                                            db_config: @secondary_config
                                                          }
                                                        })

      # Expectations
      @task.expects(:notify).with('You have 1 pending migrations for primary', 'before').once
      @task.expects(:notify).with('You have 1 pending migrations for secondary', 'before').once
      @task.expects(:notify_pending_migrations).with([proxies[0]]).once
      @task.expects(:notify_pending_migrations).with([proxies[1]]).once

      # Execute the method
      @task.check_multi_db_pending_migrations
    end
  end
end
