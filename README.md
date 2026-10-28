# KogenCredo

Credo checks that catch AI slop and keep test gates honest: skipped tests, unexplained coverage ignores, developer-machine paths in runtime config and scaffolding with no purpose.

## Origin

All four checks were written in [optimum_credo](https://github.com/optimumBA/optimum_credo) (0.4.0 and the uncommitted 0.4.1 work) and moved here, with their tests, under the `KogenCredo.Check.*` namespace. The split rule: a pattern found in model-written code, or one that defeats a gate, lives here; a style preference from human code review stays in optimum_credo. The two packages do not depend on each other.

## Installation

Add the `:kogen_credo` package to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:kogen_credo, path: "../kogen_credo", only: [:dev, :test], runtime: false}
  ]
end
```

## Usage

Enable the checks in your `.credo.exs`:

```elixir
%{
  configs: [
    %{
      name: "default",
      requires: ["./deps/kogen_credo/lib/**/*.ex"],
      checks: [
        {KogenCredo.Check.Readability.EmptySetupBlock, []},
        {KogenCredo.Check.Readability.JustifiedCoverageIgnore, []},
        {KogenCredo.Check.Warning.RuntimeEnvDevDefault, []},
        {KogenCredo.Check.Warning.SkippedTest, []}
      ]
    }
  ]
}
```

## Available Checks

### Readability

#### EmptySetupBlock

Detects empty `setup` blocks in test files (`setup do :ok end`, `setup do end`, `setup do {:ok, %{}} end`) that add noise without providing test setup value. File-scoped to `*_test.exs` files and `test/support/`.

#### JustifiedCoverageIgnore

Enforces reason text on `coveralls-ignore-*` markers, so a coverage exclusion cannot be added without saying why. Supports an `allow_bare_until` param (an ISO date) that tolerates bare markers until that date, to ease migration.

### Warning

#### RuntimeEnvDevDefault

Detects `System.get_env("VAR", "/Users/...")` calls in `config/runtime.exs` where the default is a developer-machine path (`/Users/`, `/home/`, `~/`). Such defaults silently break on production servers. File-scoped to `config/runtime.exs`.

#### SkippedTest

Detects `@tag :skip`, `@tag skip: true`, `@moduletag :skip`, and related annotations that hide failing tests. Supports an `allow_with_comment: true` param to exempt tags that carry an inline explanatory comment.

## Testing

```bash
mix test
mix credo --strict
```

## License

MIT. See `LICENSE`; the checks originate in optimum_credo and keep its copyright notice.
