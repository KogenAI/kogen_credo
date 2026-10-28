defmodule KogenCredo.Check.Warning.NoCredoDisable do
  @moduledoc """
  Reports `# credo:disable-for-...` comments (real comments only; text inside
  strings and heredocs is ignored).

  ## This check is advisory

  It runs inside Credo, and Credo applies suppression comments and configuration
  to its own checks. A `# credo:disable-for-this-file` comment, an `.credo.exs`
  that removes this check, or `files.excluded` all silence it. It therefore cannot
  secure Credo against suppressions that were added to bypass it. Use it to surface
  suppressions in review and local runs; for enforcement, also scan the repository
  for the directive in CI with a tool that does not execute Credo (for example `grep`) and
  protect `.credo.exs`.

  ## Params

    * `allowed_directives`: directive names that may be used, e.g. `["disable-for-next-line"]`
      (`"disable-for-lines"` allows every `disable-for-lines:N`).
    * `allowed_checks`: Credo check names (e.g. `"Credo.Check.Readability.Specs"`) whose
      suppression is allowed; a directive naming only allowed checks passes.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [allowed_directives: [], allowed_checks: []],
    explanations: [
      check: """
      `# credo:disable-for-...` hides a finding instead of fixing it. Fix the code, or change the
      check configuration in a reviewed place. Note: this check is advisory and can itself be
      suppressed or disabled, see the module documentation.
      """,
      params: [
        allowed_directives: "Directive names allowed (e.g. `disable-for-next-line`).",
        allowed_checks: "Check names whose suppression is allowed."
      ]
    ]

  alias KogenCredo.CoreSupport.Settings

  # Same trigger as Credo's own comment finder (`~r/#\s*credo\:([\w\-\:]+)\s*(.*)/im`): the `credo`
  # prefix is case-insensitive, the instruction is compared literally. Prose that merely mentions a
  # directive after other words is not reported, while everything Credo honours is.
  @directive ~r/#\s*(?i:credo):(disable-for-(?:this-file|next-line|previous-line|lines:[+-]?\d*))(?![\w\-:])\s*(.*)$/

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    {allowed_directives, allowed_checks} = allowances(params)
    source = SourceFile.source(source_file)

    case Code.string_to_quoted_with_comments(source, columns: true, emit_warnings: false) do
      {:ok, _, comments} ->
        for %{line: line, text: text} <- comments,
            [_, directive, rest] <- [Regex.run(@directive, text)],
            not allowed?(directive, rest, allowed_directives, allowed_checks) do
          directive_issue(issue_meta, line, directive)
        end

      _ ->
        []
    end
  end

  defp allowances(params) do
    allowed_directives =
      params
      |> Params.get(:allowed_directives, __MODULE__)
      |> Settings.strings!(:allowed_directives)

    allowed_checks =
      params
      |> Params.get(:allowed_checks, __MODULE__)
      |> Settings.strings!(:allowed_checks)

    {allowed_directives, allowed_checks}
  end

  defp directive_issue(issue_meta, line, directive) do
    format_issue(issue_meta,
      message:
        "`credo:#{directive}` hides a finding instead of fixing it. Fix the code or change the check " <>
          "configuration. (Advisory: this check cannot prevent suppression of itself.)",
      line_no: line,
      trigger: "credo:" <> directive
    )
  end

  defp allowed?(directive, rest, allowed_directives, allowed_checks) do
    names = String.split(rest, [" ", ","], trim: true)

    base =
      directive
      |> String.split(":")
      |> hd()

    directive in allowed_directives or base in allowed_directives or
      (names != [] and Enum.all?(names, &(&1 in allowed_checks)))
  end
end
