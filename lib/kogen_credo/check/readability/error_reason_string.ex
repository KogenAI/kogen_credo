defmodule KogenCredo.Check.Readability.ErrorReasonString do
  @moduledoc """
  Flags `{:error, "text"}` (and interpolated strings) where the error is
  *constructed*, e.g. returned from a function.

  Callers cannot pattern match on prose, messages get reworded and break matches
  silently, and the string tends to be shown to users unchanged. Return an atom
  (`{:error, :not_found}`), a tagged tuple (`{:error, {:invalid, field}}`), or an
  exception/struct that renders its own message.

  Match patterns are not reported: left sides of `->`, `<-` and `=`, and function
  heads are skipped, so code that *handles* a library's string error is fine.

  ## Limitations

  Syntactic. Line numbers come from a second parse of the source that keeps literal
  positions, so they are exact for every string, heredoc and repeated message. A file
  that does not parse yields no issues (Credo reports the syntax error itself). Strings built in a variable first (`msg = "..."; {:error, msg}`) are not
  seen. Layers whose contract really is human text (Mix tasks, CLI output) should be
  excluded with `excluded_paths`. Set `flag_interpolated: false` to skip strings with
  `\#{...}` interpolation.
  """

  use Credo.Check,
    category: :readability,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/"],
      excluded_paths: ["lib/mix/"],
      flag_interpolated: true
    ],
    explanations: [
      check: """
      Return a machine-matchable reason, not prose: `{:error, :not_found}`, `{:error, {:invalid, :email}}`
      or an exception struct. Render human text at the edge (controller, CLI, UI).
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped (Mix tasks by default).",
        flag_interpolated: "Also report interpolated strings."
      ]
    ]

  alias KogenCredo.CoreSupport.Paths

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)
      interpolated? = Params.get(params, :flag_interpolated, __MODULE__)

      source_file
      |> reason_hits(interpolated?)
      |> Enum.map(&reason_issue(issue_meta, &1))
    else
      []
    end
  end

  defp reason_hits(source_file, interpolated?) do
    {_, hits} =
      source_file
      |> SourceFile.source()
      |> parse_with_literal_lines()
      |> strip_patterns()
      |> Macro.prewalk([], &collect_hit(&1, &2, interpolated?))

    Enum.sort_by(hits, fn {line, _} -> line end)
  end

  defp collect_hit(
         {:__block__, _, [{{:__block__, _, [:error]}, reason}]} = node,
         hits,
         interpolated?
       ),
       do: {node, hit(reason, interpolated?) ++ hits}

  defp collect_hit(node, hits, _), do: {node, hits}

  defp reason_issue(issue_meta, {line, text}) do
    format_issue(issue_meta,
      message:
        "`{:error, #{text}}` returns prose as the error reason. Return an atom or tagged tuple " <>
          "(`{:error, :not_found}`) so callers can match, and render text at the edge.",
      trigger: ":error",
      line_no: line
    )
  end

  # Credo's own AST has no line metadata on plain literals. Parsing the source again with a
  # `literal_encoder` wraps every literal (strings, atoms, 2-tuples) in a `{:__block__, meta, [_]}`
  # node that carries its real line, so no text search is needed.
  defp parse_with_literal_lines(source) do
    encoder = fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end

    case Code.string_to_quoted(source,
           literal_encoder: encoder,
           token_metadata: true,
           columns: true
         ) do
      {:ok, ast} -> ast
      {:error, _} -> nil
    end
  end

  defp hit({:__block__, meta, [text]}, _) when is_binary(text),
    do: [{meta[:line] || 1, inspect(text, limit: 40, printable_limit: 40)}]

  defp hit({:<<>>, meta, _} = reason, true),
    do: [
      {meta[:line] || 1,
       reason
       |> Macro.to_string()
       |> truncate()}
    ]

  defp hit(_, _), do: []

  # Replaces pattern positions with `nil` so only constructed values remain.
  defp strip_patterns(ast), do: Macro.prewalk(ast, &strip_pattern/1)

  defp strip_pattern({:->, meta, [_, body]}), do: {:->, meta, [[], body]}
  defp strip_pattern({:<-, meta, [_, rhs]}), do: {:<-, meta, [nil, rhs]}
  defp strip_pattern({:=, meta, [_, rhs]}), do: {:=, meta, [nil, rhs]}
  defp strip_pattern({:match?, meta, [_, expr]}), do: {:match?, meta, [nil, expr]}

  defp strip_pattern({kind, meta, [_, body]}) when kind in [:def, :defp, :defmacro, :defmacrop],
    do: {kind, meta, [nil, body]}

  defp strip_pattern(node), do: node

  defp truncate(text) when byte_size(text) > 48, do: String.slice(text, 0, 45) <> "...\""
  defp truncate(text), do: text
end
