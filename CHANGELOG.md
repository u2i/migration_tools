# Changelog

## 1.7.1 (2024-04-29)

### Added
- Multi-database support for Rails 6.0+
- Enhanced output to show database information
- Smart detection of multi-database setups with `multi_database_setup?` method
- Database-specific migration handling with contextual execution
- Parallel migration tracking across all configured databases
- Database-specific schema migrations respecting configuration paths

### Changed
- Dropped official support for Rails 5.1 and lower
- Updated documentation with multi-database usage examples
- Refactored migration execution code for better database context handling
- Modified migration tasks to automatically detect and adapt to multi-database environments
- Enhanced notification system to display database context in outputs

## 1.7.0 (Previous release)

[Details of previous release] 
