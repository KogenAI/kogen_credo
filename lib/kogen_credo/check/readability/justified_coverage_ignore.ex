defmodule KogenCredo.Check.Readability.JustifiedCoverageIgnore do
  @moduledoc """
  Enforces that every `coveralls-ignore-*` marker includes a reason.

  Bare markers like `# coveralls-ignore-next-line` are disallowed.
  Justified markers like `# coveralls-ignore-next-line: Shell git not-found branch` pass.

  This check enables gradual phaseout of coverage ignores during audit cycles.

  Markers are taken from the file's real comments (`Code.string_to_quoted_with_comments/2`), so
  marker-looking text inside strings and heredocs is not reported. A comment trailing code on the
  same line is a comment too and is checked. If the file does not parse, the check falls back to
  scanning lines that start with `#`; in that mode a marker inside a heredoc can be reported.

  **Parameters**:
  - `allow_bare_until` (optional, ISO 8601 date string): Grace period for bare markers.
    Default: nil (no grace). Example: `"2026-05-26"` allows bare markers until that date.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    param_defaults: [
      allow_bare_until: nil
    ],
    explanations: [
      check: """
      Coverage ignores must document their reason so future audits can justify or remove them.

      Use format: `# coveralls-ignore-next-line: <reason>` or `# coveralls-ignore-start: <reason>`

      Valid reasons:
      - Shell git not-found branch (covered by FakeShell in Phase 3.1)
      - OS subprocess glue, exercised by `make llm` integration
      - Mix-task entrypoint, no test-loop coverage
      - GenServer init/terminate, hostile to ExUnit lifecycle
      - Logger.warning side effect with no return contract
      - Mailgun/Stripe/Bunny webhook crash branch, fail-safe-only
      """,
      params: [
        allow_bare_until: """
        ISO 8601 date string (e.g. "2026-05-26"). Bare markers are allowed until this date.
        Default: nil — bare markers always fail.
        """
      ]
    ]

  @doc false
  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%Credo.SourceFile{} = source_file, params) do
    allow_bare_until = Params.get(params, :allow_bare_until, __MODULE__)
    cutoff_date = parse_cutoff_date(allow_bare_until)
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> comment_lines()
    |> Enum.flat_map(&check_line(&1, issue_meta, cutoff_date))
  end

  defp comment_lines(source_file) do
    source = Credo.SourceFile.source(source_file)

    case Code.string_to_quoted_with_comments(source, columns: true, emit_warnings: false) do
      {:ok, _, comments} ->
        for %{line: line, text: text} <- comments, do: {line, text}

      {:error, _} ->
        for {line_no, line} <- Credo.SourceFile.lines(source_file),
            comment_line?(line),
            do: {line_no, line}
    end
  end

  defp comment_line?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, "#")
  end

  defp check_line({line_no, line}, issue_meta, cutoff_date) do
    if bare_marker?(line) and not within_grace_period?(cutoff_date) do
      [
        format_issue(issue_meta,
          message:
            "Coverage ignore marker lacks reason. Use: `# coveralls-ignore-<scope>: <reason>`",
          line_no: line_no,
          trigger: "coveralls-ignore"
        )
      ]
    else
      []
    end
  end

  defp bare_marker?(line) do
    trimmed = String.trim_leading(line)

    Regex.match?(~r/^#\s*coveralls-ignore-(next-line|start)(\s|$)/, trimmed) and
      not Regex.match?(~r/coveralls-ignore-(next-line|start):\s*\S/, trimmed)
  end

  defp within_grace_period?(nil), do: false

  defp within_grace_period?(cutoff_date) do
    Date.compare(Date.utc_today(), cutoff_date) == :lt
  end

  defp parse_cutoff_date(nil), do: nil

  defp parse_cutoff_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        date

      {:error, _} ->
        raise ArgumentError,
              "allow_bare_until must be an ISO 8601 date string (\"2026-05-26\") or nil, got: #{inspect(date_str)}"
    end
  end

  defp parse_cutoff_date(other) do
    raise ArgumentError,
          "allow_bare_until must be an ISO 8601 date string (\"2026-05-26\") or nil, got: #{inspect(other)}"
  end
end
