defmodule Mix.Tasks.Kogen.DiffCheck do
  @shortdoc "Run diff-aware AST rules on functions changed in a git range"
  @moduledoc """
  Judges each function changed in a git range against its own base version.

      mix kogen.diff_check origin/main...HEAD
      mix kogen.diff_check v1.0..HEAD --path lib/ --format github

  `A...B` compares `B` with the merge base of `A` and `B`; `A..B` compares the two commits
  directly. The task only reads git objects (`rev-parse`, `merge-base`, `diff --name-status`,
  `cat-file`): it creates no commits, installs no hooks and writes nothing.

  ## Options

    * `--repo PATH` - repository directory (default `.`)
    * `--path P` - path relative to `--repo`, repeatable (default `lib/`); a path matching
      no file in either tree is an error (exit 2)
    * `--format text|json|github` - output (default `text`); `github` prints escaped
      `::warning`/`::error` annotations
    * `--rules a,b` - only these rule ids (default all)
    * `--error-rules a,b` - promote these rules from advisory to error
    * `--fail-on advisory|error|none` - which findings give exit 1 (default `error`)
    * `--sensitive-field F` - query scope field for `query-lost-scope`, repeatable
    * `--cast-sensitive-field F` - field `changeset-weakened` flags when added to `cast`
    * `--repo-name Name` - last alias segment that denotes a repo, repeatable (default `Repo`)

  Rule ids: `query-lost-limit`, `query-lost-scope`, `new-repo-in-loop`, `new-silent-fallback`,
  `changeset-weakened`, `lost-transaction`, `widened-api`. Every rule is advisory by default;
  see `KogenCredo.Diff` for what is and is not measured.

  ## Exit codes

  `0` nothing at or above `--fail-on`; `1` such findings; `2` usage error, git failure, or a
  file whose source could not be parsed (never reported as success). Needs only Elixir and git;
  the project does not have to compile.
  """
  use Mix.Task

  alias KogenCredo.Diff.CLI

  @impl Mix.Task
  def run(argv) do
    case CLI.run(argv) do
      {output, 0} ->
        Mix.shell().info(output)

      {output, 1} ->
        Mix.shell().info(output)
        exit({:shutdown, 1})

      {"kogen.diff_check: " <> _ = output, code} ->
        Mix.shell().error(output)
        exit({:shutdown, code})

      {output, code} ->
        Mix.shell().info(output)
        exit({:shutdown, code})
    end
  end
end
