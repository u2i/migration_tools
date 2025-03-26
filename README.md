# Migration Tools  [![Build Status](https://github.com/zendesk/migration_tools/workflows/CI/badge.svg)](https://github.com/zendesk/migration_tools/actions?query=workflow%3ACI)

Rake tasks for grouping migrations.

## Groups

The migration tools allow you to specify a group in your migrations. This is used to allow you to run your migrations in groups, as opposed to all at once. This is useful if you want to run a certain group of migrations before a deploy, another group during deploy and a third group after deploy.

We use this technique to be able to QA new production code in an isolated environment that runs against the production database. It also reduces the number of moving parts come deploy time, which is helpful when you're doing zero downtime deploys.

You specify which group a migration belongs to inside the migration, like so:

```ruby
  class CreateHello < ActiveRecord::Migration
    group :before

    def self.up
      ...
    end
  end
```

The names of the possible groups are predefined to avoid turning this solution in to a generic hammer from hell. You can use the following groups: before, during, after, change. We define these as:

*before* this is for migrations that are safe to run before a deploy of new code, e.g. adding columns/tables

*during* this is for migrations that require the data structure and code to deploy "synchronously"

*after* this is for migrations that should run after the new code has been pushed and is running

*change* this is a special group that you run whenever you want to change DB data which you'd otherwise do in script/console


## Commands

The list commands

```
  $ rake db:migrate:list - shows pending migrations by group
  $ rake db:migrate:list:before - shows pending migrations for the before group
  $ rake db:migrate:list:during - shows pending migrations for the during group
  $ rake db:migrate:list:after  - shows pending migrations for the after group
  $ rake db:migrate:list:change - shows pending migrations for the change group
```

The group commands

```
  $ GROUP=before rake db:migrate:group - runs the migrations in the specified group
  $ rake db:migrate:group:before - runs pending migrations for the before group
  $ rake db:migrate:group:during - runs pending migrations for the during group
  $ rake db:migrate:group:after  - runs pending migrations for the after group
  $ rake db:migrate:group:change - runs pending migrations for the change group
```
Note that rake db:migrate is entirely unaffected by this.

## Multi-Database Support

As of version 1.7.1, Migration Tools automatically supports Rails 6.0+ multi-database configurations.

### How It Works

- Multiple databases are automatically detected for Rails 6.0+ applications
- Migration commands run against all configured databases in your Rails application
- Migration groups are respected across all databases
- Each database's migrations are tracked separately

### Output Format

When working with multiple databases, the tool will:
- Show pending migrations organized by database name
- Display database-specific contexts in all outputs
- Run migrations for each database separately while maintaining group constraints

Example output for `rake db:migrate:list`:

```
You have 3 pending migrations for primary
  1234 before  CreateUsers
  1235 after  AddIndexToUsers
You have 1 pending migration for animals
  1236 before  CreatePets
```

All existing commands function the same way but now operate across all your configured databases. No additional configuration is needed - the tools automatically adapt to your Rails database configuration.

## Development

In order to run and develop tests you can find docker setup instructions below.

### Using Docker (Recommended)

1. Install Docker and Docker Compose
2. Build and start the development container:
   ```bash
   docker compose build dev
   docker compose up dev
   ```
3. Inside the container, you can:
   - Run all tests: `test-all`
   - Run specific gemfile tests: `run-test [gemfile]`
     ```bash
     run-test rails6.1
     run-test activerecord6.1_no_rails
     ```

## License

Copyright 2015 Zendesk

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
