defmodule KogenCredo.Check.Warning.SkippedTest do
  @moduledoc """
  A check that finds skipped tests via `@tag :skip`, `@moduletag :skip` or `@describetag :skip`
  (also the keyword forms `skip: true`/`skip: "reason"`, alone or among other options;
  `skip: false` and `skip: nil` do not skip).

  Skipped tests hide failures and erode the test suite over time. Every skipped
  test should either be fixed and re-enabled, or deleted entirely.

  ## Param: `allow_with_comment`

  When set to `true`, the check does NOT fire if a non-empty comment appears on
  the same line as the `@tag`, `@moduletag` or `@describetag` annotation. Only real comments
  count: a `#` inside a string does not. This lets teams
  annotate intentionally-skipped tests with a reason (e.g. `@tag :skip # TODO #123`).

  Default: `false` — fire unconditionally, regardless of inline comments.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allow_with_comment: false],
    explanations: [
      check: """
      Skipped tests (`@tag :skip`, `@tag skip: true`, `@moduletag :skip`, etc.)
      hide failures and erode the test suite over time.

      Every skipped test should either be fixed and re-enabled, or deleted entirely.

      ## Examples

      **Bad:**
      ```elixir
      @tag :skip
      test "something" do
        assert 1 == 2
      end
      ```

      **Good:**
      ```elixir
      test "something" do
        assert 1 == 1
      end
      ```
      """,
      params: [
        allow_with_comment:
          "When true, skip the check if a non-empty comment follows the @tag on the same line."
      ]
    ]

  @tags [:tag, :moduletag, :describetag]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    allow_with_comment = Params.get(params, :allow_with_comment, __MODULE__)

    commented_lines =
      if allow_with_comment, do: commented_lines(source_file), else: MapSet.new()

    Credo.Code.prewalk(
      source_file,
      &traverse(&1, &2, issue_meta, allow_with_comment, commented_lines)
    )
  end

  defp traverse(ast, issues, issue_meta, allow_with_comment, commented_lines) do
    case find_skip_issue(ast, issue_meta, allow_with_comment, commented_lines) do
      nil -> {ast, issues}
      issue -> {ast, [issue | issues]}
    end
  end

  # `@tag :skip`, `@tag skip: value` (alone or among other options), `@tag [:skip, ...]`;
  # the same for `@moduletag` and `@describetag`. `skip: false` / `skip: nil` do not skip.
  defp find_skip_issue({:@, meta, [{tag, _, [arg]}]}, issue_meta, allow?, commented)
       when tag in @tags do
    line_no = meta[:line] || 1

    cond do
      not skip_arg?(arg) -> nil
      allow? and MapSet.member?(commented, line_no) -> nil
      true -> format_issue(issue_meta, message: skip_message(tag), line_no: line_no)
    end
  end

  defp find_skip_issue(_, _, _, _), do: nil

  defp skip_arg?(:skip), do: true

  defp skip_arg?(options) when is_list(options) do
    Enum.any?(options, fn
      :skip -> true
      {:skip, value} -> value not in [false, nil]
      _ -> false
    end)
  end

  defp skip_arg?(_), do: false

  defp skip_message(:tag), do: "Skipped test via @tag :skip — fix or delete the test."

  defp skip_message(:moduletag),
    do: "Skipped test module via @moduletag :skip — fix or delete the test."

  defp skip_message(:describetag),
    do: "Skipped describe block via @describetag :skip — fix or delete the tests."

  # Lines carrying a real, non-empty comment (a `#` inside a string or atom is not one).
  defp commented_lines(source_file) do
    source = Credo.SourceFile.source(source_file)

    case Code.string_to_quoted_with_comments(source, emit_warnings: false) do
      {:ok, _, comments} ->
        for %{line: line, text: text} <- comments,
            comment_text(text) != "",
            into: MapSet.new(),
            do: line

      {:error, _} ->
        MapSet.new()
    end
  end

  defp comment_text(text) do
    text
    |> String.trim_leading("#")
    |> String.trim()
  end
end
