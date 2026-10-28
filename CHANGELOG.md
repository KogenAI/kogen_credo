# Changelog

## Unreleased

## 0.1.0 (2026-10-28)

- Initial release with 35 configurable Credo checks for generated-code mistakes, error handling, test quality, shared state, structural limits and query regressions. See `docs/checks.md` for behavior and parameters.
- Preserved `EmptySetupBlock`, `RuntimeEnvDevDefault`, `SkippedTest` and the previously unreleased `JustifiedCoverageIgnore` from OptimumCredo, including their original copyright notices. See `docs/migration.md` for the renamed modules.
- Added seven advisory regression diff rules and `mix kogen.diff_check`, suppression and golden-configuration integrity helpers, and the advisory `mix kogen.unused_public` task.
- Added explicit configuration examples and regression coverage for valid lookalikes, lexical scope, framework boundaries and parameter changes. Source-derived identities remain strings rather than allocating atoms.
- Require Elixir 1.17 or newer and Credo 1.7.19 or newer within 1.x. Diff analysis and unused-public findings remain advisory and have documented static-analysis limits.
