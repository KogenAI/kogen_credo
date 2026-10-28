# Regression diff checks

`mix kogen.diff_check` compares the base and head versions of changed Elixir
functions. Credo's ordinary checks inspect a single source version; these rules
identify changes relative to the base.

```sh
mix kogen.diff_check origin/main...HEAD
mix kogen.diff_check HEAD~1..HEAD --format json
mix kogen.diff_check origin/main...HEAD --format github
```

Two dots compare the named revisions directly. Three dots use the merge base.
Git failures, invalid options and source that cannot be parsed produce an error;
invalid source is not silently treated as a successful analysis.

| Rule | Detects |
| --- | --- |
| `query-lost-limit` | A query loses its SQL bound |
| `query-lost-scope` | A query loses a configured owner/tenant predicate |
| `new-repo-in-loop` | A new database call is introduced inside a loop |
| `new-silent-fallback` | A newly added error/fallback branch silently returns a default |
| `changeset-weakened` | A changeset loses validation/constraints or widens sensitive cast fields |
| `lost-transaction` | A transaction is removed while multiple writes remain |
| `widened-api` | A private function becomes public or the public surface grows |

These rules ship as advice. New implementation tests do not establish the old
prototype's historical precision measurements for the revised code. Configure
error severity only after reviewing findings and measuring the desired policy.

The task supports text, JSON and escaped GitHub annotations. Its default
`--fail-on error` does not fail merely because an advisory finding exists;
`--fail-on advisory` does. `--fail-on none` still does not turn parser, Git or
usage errors into success. `--error-rules` selects rule ids to elevate, and
`--rules` selects the rules to run. Read `Mix.Tasks.Kogen.DiffCheck` and
`KogenCredo.Diff.CLI` for exact options, including sensitive-field configuration.

Dynamic query builders, macro expansion, runtime authorization and indirect
behavior outside analysed local functions remain static-analysis limits. These
checks supplement tests and review; they do not prove equivalent behavior.

## Project roots and umbrella paths

Paths are relative to the directory passed through `--repo`, including its default
`lib/`. Output filenames remain relative to the Git repository root. A path that
matches no file in either the base or head tree is a usage/path error (exit 2),
rather than a successful empty scan. An unchanged range over existing paths is clean.

For an umbrella, point at the app or pass its path explicitly:

```sh
mix kogen.diff_check base..HEAD --repo apps/billing
mix kogen.diff_check base..HEAD --repo . --path apps/billing/lib/
```

Passing `--repo lib` now means `lib/lib/` by default; use the project root instead.
The task needs Git 2.28 or newer for consistent root-relative diff output.
