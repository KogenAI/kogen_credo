# KogenCredo

Credo checks for recurring generated-code mistakes and verification integrity:
error handling, test quality, global state, structural limits and query regressions.

Version **0.1.0**. Source: [KogenAI/kogen_credo](https://github.com/KogenAI/kogen_credo).

## Start here

- [Check catalog](docs/checks.md): detectors, defaults, limits and source links.
- [Explicit configuration example](docs/configuration.md): select checks and supply
  project-specific parameters before enabling them in CI.
- [Diff checks](docs/diff-checks.md): compare changed functions with their base.
- [Migration guide](docs/migration.md): names moved from OptimumCredo.
- [Changelog](CHANGELOG.md): version history and release changes.

## Installation

Add the Hex dependency:

```elixir
{:kogen_credo, "~> 0.1.0", only: [:dev, :test], runtime: false}
```

Requires Credo 1.7.19 or newer in the 1.x series. When adopting this version,
update Credo together with it; an older locked Credo does not provide the token
metadata these checks need, and older releases cannot lint Elixir 1.20 reliably.

For development with a sibling checkout:

```elixir
defp deps do
  [
    {:kogen_credo, path: "../kogen_credo", only: [:dev, :test], runtime: false}
  ]
end
```

Enable individual checks in `.credo.exs`:

```elixir
%{
  configs: [
    %{
      name: "default",
      checks: %{
        enabled: [
          {KogenCredo.Check.Warning.SkippedTest, []},
          {KogenCredo.Check.Readability.JustifiedCoverageIgnore, []},
          {KogenCredo.Check.Warning.BroadRescue, []},
          {KogenCredo.Check.Warning.RepoAllThenTrim, []}
        ]
      }
    }
  ]
}
```

Run `mix credo --strict` to include low-priority advice. Neither installing this
library nor copying a package example establishes the right policy for an
application. Review actual findings and configure namespaces, codecs, domain
roots, allowed serial tests and resource groups where needed.

OptimumCredo remains independent and owns code-review preferences. Enable both
libraries where useful, choosing between overlapping policies deliberately.

## Integrity and static-analysis limits

`KogenCredo.Integrity` provides suppression scanning and comparison with a golden
Credo configuration. Parsing a configuration for comparison does not evaluate
arbitrary Elixir. Store golden policy in a location the code-writing agent cannot
change. The library cannot establish that trust boundary by itself.

`NoCredoDisable` is an advisory Credo detector, not a tamper-proof enforcement
mechanism: Credo can suppress its own checks. The separate integrity scan exists
for enforcement outside Credo's suppression pipeline.

`mix kogen.unused_public` reports public functions with no observed compiled
caller. It is advisory by default and needs compiled debug information. Callbacks,
entry points, external library consumers, dynamic dispatch and macros limit what
static analysis can establish; read the task/module documentation before acting.

## Module names

Analysed code names modules, it does not load them. Aliases, imports, `defmodule` nesting,
`__MODULE__` and module parameters are resolved to dotted names (`MyApp.Repo`; Erlang modules keep
their colon, `:ets`) and compared as strings, so code whose modules are not compiled, not loaded
or do not exist is analysed like any other, and no atom is created for a module the analysis only
reads. Module parameters keep the form they always had: atoms for `broad_exceptions`,
`codec_modules`, `ForbiddenCall` calls, `stub_exceptions`, `shared` and domain namespaces
(a string is still rejected, so a typo cannot look like "nothing configured"); full-name strings
for `repo_modules`. Repo names, function names and fields (including the diff CLI's
`--sensitive-field`, `--cast-sensitive-field` and `--repo-name`) are compared by name and are
never turned into atoms. Only `mix kogen.unused_public` handles real module atoms, because it
reads installed BEAM debug information. `KogenCredo.Integrity.parse_config/1` returns modules
written in a config as `KogenCredo.Integrity.ModuleRef` structs for the same reason.

## Framework boundaries and test scope

`StringKeyAccess` recognises literal Phoenix/Oban/Ecto callback boundaries,
connection fields, JSON query paths and directly encoded wire documents. Other
wire adapters still need `codec_modules` or `codec_globs`. Recognition is static;
it does not track values across arbitrary calls or variable shadowing.

The `ForbiddenCall` async-test preset uses `only_async: true` rules and checks
literal `async: true` modules. Explicit rules can inspect other scopes. `SizeLimits`
excludes `~H` markup from function length; use `count_template_lines: true` to count it.

Checks that infer test state through custom case templates need a `case_templates`
map, for example `%{"MyApp.DataCase" => :inherit, "MyAppWeb.ConnCase" => :inherit}`.
Supply it to the relevant checks before treating zero findings as coverage of
those templates. Serial-case exemptions should describe reviewed shared resources.

## Development

After `mix deps.get`, run `make ci` for formatting, compilation, tests,
strict Credo and documentation checks. The individual commands are:

```sh
mix deps.get
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
```

The checked-in self-lint policy (`mix credo --strict`) reports no findings. Passing it, like
test/format/compile success, says nothing about the precision of the detectors.

Test violations, valid lookalikes, parameter changes and lexical scope. Run the
suite across supported Elixir versions before publication. New diff rules remain
advisory until their precision is demonstrated on real history; unit tests alone
are not that evidence.

Folder map: `lib/kogen_credo/check/` owns Credo detectors;
`lib/kogen_credo/diff/` owns function comparison and reporting;
`lib/mix/tasks/` owns command entry points; remaining library modules own shared
analysis helpers and integrity checks; `test/` owns regression coverage; `docs/`
owns the catalog and usage/migration details.

## Origin and license

`EmptySetupBlock`, `JustifiedCoverageIgnore`, `RuntimeEnvDevDefault` and
`SkippedTest` originated in OptimumCredo and retain its copyright notice. Other
checks grow from the retained Kogen research prototypes and original
implementations. The two packages do not depend on one another.

MIT. See [LICENSE](LICENSE).
