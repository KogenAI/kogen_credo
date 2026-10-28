defmodule KogenCredo.Check.Warning.UnescapedLikeInput do
  @moduledoc """
  Flags `like`/`ilike` patterns built from dynamic input without escaping the
  LIKE wildcards.

  `ilike(u.name, ^"%\#{term}%")` passes `term` straight into the pattern, so a
  user who types `%` or `_` controls the wildcards (broad scans, enumeration,
  surprising matches). The input should be escaped (`\\`, `%`, `_`) before the
  author's own wildcards are added.

  ## What is detected

    * `like/2` and `ilike/2` (names configurable with `like_functions`) and
      `fragment("... ILIKE ?", ...)` whose pattern is an interpolated string
      (`"%\#{x}%"`) or a `<>` concatenation (`"%" <> x <> "%"`) containing a
      literal `%` or `_` plus a dynamic part
    * the same pattern bound to a variable earlier in the same function and
      passed as `^pattern`

  A dynamic part counts as escaped when it contains a call to one of
  `escape_functions` (matched by function name, local or remote) or a
  `String.replace/3` that mentions `%`.

  ## Limitations

  Syntactic and advisory. Patterns that arrive through function arguments,
  other modules, `dynamic/2` or variables bound in another function are not
  followed; a bare `ilike(f, ^input)` with no author-written wildcard is not
  reported. Escaping done by an unlisted helper is a false positive (add it to
  `escape_functions`). Module attributes and literals are treated as trusted.
  Tests are excluded by default.
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      like_functions: [:like, :ilike],
      escape_functions: [
        "escape_like",
        "sanitize_like",
        "escape_like_pattern",
        "like_escape",
        "escape_wildcards"
      ],
      included_paths: [],
      excluded_paths: ["test/**"]
    ],
    explanations: [
      check: """
      A LIKE pattern built from input without escaping lets the input contain
      wildcards.

      **Bad:**
      ```elixir
      where(q, [u], ilike(u.name, ^"%\#{term}%"))
      ```

      **Good:**
      ```elixir
      where(q, [u], ilike(u.name, ^"%\#{escape_like(term)}%"))
      ```

      where `escape_like/1` escapes `\\`, `%` and `_`. Heuristic: only patterns
      with an author-written wildcard plus dynamic input are reported.
      """,
      params: [
        like_functions: "Query functions that take a LIKE pattern as 2nd argument.",
        escape_functions: "Function names that escape LIKE input (matched by name).",
        included_paths: "Globs of files to check; empty means every file.",
        excluded_paths: "Globs of files to skip (default `[\"test/**\"]`)."
      ]
    ]

  alias KogenCredo.QuerySupport

  @doc false
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    ast = QuerySupport.expanded_ast(source_file)

    if ast && QuerySupport.in_scope?(source_file, params, __MODULE__) do
      ctx = context(params)
      issue_meta = IssueMeta.for(source_file, params)

      ast
      |> scopes()
      |> Enum.flat_map(&scope_hits(&1, ctx))
      |> Enum.uniq()
      |> Enum.map(&like_issue(issue_meta, &1))
    else
      []
    end
  end

  defp context(params) do
    %{
      like:
        params
        |> Params.get(:like_functions, __MODULE__)
        |> QuerySupport.names(),
      escapes:
        params
        |> Params.get(:escape_functions, __MODULE__)
        |> Enum.map(&to_string/1)
    }
  end

  defp scopes(ast) do
    top = Macro.prewalk(ast, &strip_def/1)
    defs = QuerySupport.defs(ast)
    Enum.concat(defs, [top])
  end

  defp like_issue(issue_meta, {line, trigger}) do
    format_issue(issue_meta,
      message:
        "Input is interpolated into a #{trigger} pattern without escaping `%`, `_` and `\\`, " <>
          "so callers control the wildcards. Escape it first (e.g. an escape_like/1 helper) and add your own wildcards around it.",
      trigger: trigger,
      line_no: line
    )
  end

  defp strip_def({kind, _, [_, _]}) when kind in [:def, :defp, :defmacro, :defmacrop], do: nil
  defp strip_def(node), do: node

  defp scope_hits(scope, ctx) do
    assigns = assignments(scope)
    {_, acc} = Macro.prewalk(scope, [], &like_hit(&1, &2, assigns, ctx))
    Enum.reverse(acc)
  end

  defp like_hit({fun, meta, [_, pattern]} = node, acc, assigns, ctx)
       when is_atom(fun) and fun != :fragment do
    if QuerySupport.listed?(fun, ctx.like) and unsafe?(strip_pin(pattern), assigns, ctx, 3),
      do: {node, [{meta[:line] || 1, Atom.to_string(fun)} | acc]},
      else: {node, acc}
  end

  defp like_hit({:fragment, meta, [template | args]} = node, acc, assigns, ctx)
       when is_binary(template) do
    like? = Regex.match?(~r/\bi?like\b/i, template)

    if like? and Enum.any?(args, &unsafe?(strip_pin(&1), assigns, ctx, 3)),
      do: {node, [{meta[:line] || 1, "fragment"} | acc]},
      else: {node, acc}
  end

  defp like_hit(node, acc, _, _), do: {node, acc}

  defp strip_pin({:^, _, [inner]}), do: inner
  defp strip_pin(other), do: other

  # var => [rhs, ...] for simple `var = expr` matches in the scope.
  defp assignments(scope) do
    {_, acc} =
      Macro.prewalk(scope, %{}, fn
        {:=, _, [{name, _, var_ctx}, rhs]} = node, acc when is_atom(name) and is_atom(var_ctx) ->
          {node, Map.update(acc, name, [rhs], &[rhs | &1])}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp unsafe?({name, _, var_ctx}, assigns, ctx, depth) when is_atom(name) and is_atom(var_ctx) do
    sources = Map.get(assigns, name, [])
    others = Map.delete(assigns, name)

    depth > 0 and Enum.any?(sources, &unsafe?(&1, others, ctx, depth - 1))
  end

  defp unsafe?({:<<>>, _, parts}, assigns, ctx, depth) do
    segments =
      Enum.map(parts, fn
        literal when is_binary(literal) -> {:literal, literal}
        {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, _]} -> {:dynamic, expr}
        other -> {:dynamic, other}
      end)

    unsafe_segments?(segments, assigns, ctx, depth)
  end

  defp unsafe?({:<>, _, _} = concat, assigns, ctx, depth) do
    segments =
      concat
      |> flatten_concat()
      |> Enum.map(fn
        literal when is_binary(literal) -> {:literal, literal}
        other -> {:dynamic, other}
      end)

    unsafe_segments?(segments, assigns, ctx, depth)
  end

  defp unsafe?(_, _, _, _), do: false

  defp flatten_concat({:<>, _, [l, r]}), do: flatten_concat(l) ++ flatten_concat(r)
  defp flatten_concat(other), do: [other]

  defp unsafe_segments?(segments, assigns, ctx, depth) do
    wildcard? =
      Enum.any?(segments, fn
        {:literal, text} -> String.contains?(text, ["%", "_"])
        _ -> false
      end)

    wildcard? and
      Enum.any?(segments, fn {kind, expr} ->
        kind == :dynamic and untrusted?(expr, assigns, ctx, depth)
      end)
  end

  defp untrusted?({:@, _, _}, _, _, _), do: false

  defp untrusted?(literal, _, _, _)
       when is_binary(literal) or is_number(literal) or is_atom(literal),
       do: false

  # A variable is as untrusted as the expressions bound to it; unbound ones
  # (function arguments) are untrusted.
  defp untrusted?({name, _, var_ctx} = expr, assigns, ctx, depth)
       when is_atom(name) and is_atom(var_ctx) do
    case Map.get(assigns, name) do
      nil ->
        true

      rhss ->
        depth > 0 and
          Enum.any?(rhss, &untrusted?(&1, Map.delete(assigns, name), ctx, depth - 1)) and
          not escaped?(expr, ctx)
    end
  end

  defp untrusted?(expr, _, ctx, _), do: not escaped?(expr, ctx)

  defp escaped?(expr, ctx) do
    {_, found} =
      Macro.prewalk(expr, false, fn
        node, true ->
          {node, true}

        {name, _, args} = node, false when is_atom(name) and is_list(args) ->
          {node, Atom.to_string(name) in ctx.escapes}

        {{:., _, [_, name]}, _, args} = node, false
        when is_atom(name) and is_list(args) ->
          {node, Atom.to_string(name) in ctx.escapes or percent_replace?(node)}

        node, false ->
          {node, false}
      end)

    found
  end

  defp percent_replace?({{:., _, [{:__aliases__, _, [:String]}, :replace]}, _, args}),
    do: Enum.any?(args, &(is_binary(&1) and String.contains?(&1, "%")))

  defp percent_replace?(_), do: false
end
