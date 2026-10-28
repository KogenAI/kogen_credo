# Changelog

## Unreleased

- Added 35 configurable checks for generated-code mistakes, error handling, test quality, shared state, structural limits and query regressions, with regression coverage and explicit configuration examples.
- Preserved the four checks extracted from OptimumCredo and their copyright notices; documented the module migration.
- Added suppression and golden-configuration integrity helpers; source-derived identities remain strings rather than allocating atoms.
- Require Credo 1.7.19 or newer within 1.x.
- Added seven advisory regression diff rules and `mix kogen.diff_check`, with explicit path, revision and incomplete-analysis handling.
- Added advisory unused-public analysis from compiled BEAM debug information, including incomplete-analysis reporting.
