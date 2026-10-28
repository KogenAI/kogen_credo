defmodule KogenCredo.Check.Warning.LimitWithoutStableOrder do
  @moduledoc """
  Flags Ecto queries that `limit` rows without a total (tie-free) `order_by`.

  Without a unique tiebreaker, rows with equal sort values come back in an
  unspecified order, so pages repeat or skip rows and cursors drift. A query
  is reported when it is limited and either has no `order_by` at all, or has
  an `order_by` none of whose fields is in `unique_fields` (default `:id`).

  ## What is detected

    * `limit/2` anywhere in an `Ecto.Query` chain (piped or nested), and
      `limit:` inside `from/2`
    * `order_by/2,3` in the same chain and `order_by:` inside `from/2`

  The query base must be visible: a module alias (`User`), a string table or
  `from(u in User)`. A chain whose base is a variable (`query |> limit(5)`)
  is skipped, because the ordering may be added elsewhere.

  ## Limitations

  Syntactic and advisory. Dynamic orders (`order_by(q, ^dynamic)`), variables
  and anything the check cannot read are skipped, never reported. It does not
  know your schema: a unique non-`id` column must be listed in
  `unique_fields`, and a composite unique key is not understood. `limit 1`
  literals are skipped by default (`ignore_limit_one`). Tests are excluded by
  default.
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      unique_fields: [:id],
      ignore_limit_one: true,
      included_paths: [],
      excluded_paths: ["test/**"]
    ],
    explanations: [
      check: """
      `limit` without a total `order_by` returns an arbitrary subset when sort
      values tie, so pagination repeats and skips rows.

      **Bad:**
      ```elixir
      from(p in Post, order_by: [desc: p.inserted_at], limit: 20)
      ```

      **Good:**
      ```elixir
      from(p in Post, order_by: [desc: p.inserted_at, desc: p.id], limit: 20)
      ```
      """,
      params: [
        unique_fields:
          "Field names that are unique per row; one of them in `order_by` makes the order total.",
        ignore_limit_one: "Skip literal `limit(1)` / `limit: 1` (default true).",
        included_paths: "Globs of files to check; empty means every file.",
        excluded_paths: "Globs of files to skip (default `[\"test/**\"]`)."
      ]
    ]

  alias KogenCredo.QuerySupport
  alias KogenCredo.SafetySupport

  @ops [
    :where,
    :or_where,
    :order_by,
    :select,
    :select_merge,
    :join,
    :left_join,
    :right_join,
    :inner_join,
    :preload,
    :group_by,
    :having,
    :or_having,
    :distinct,
    :offset,
    :lock,
    :limit,
    :windows
  ]

  @doc false
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    ast = QuerySupport.expanded_ast(source_file)

    if ast && QuerySupport.in_scope?(source_file, params, __MODULE__) do
      ctx = %{
        aliases: SafetySupport.aliases(ast),
        unique:
          params
          |> Params.get(:unique_fields, __MODULE__)
          |> QuerySupport.names(),
        ignore_one: Params.get(params, :ignore_limit_one, __MODULE__)
      }

      issue_meta = IssueMeta.for(source_file, params)

      ast
      |> hits(ctx)
      |> Enum.map(fn {line, message} ->
        format_issue(issue_meta, message: message, trigger: "limit", line_no: line)
      end)
    else
      []
    end
  end

  defp hits(ast, ctx) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case chain(node, ctx) do
          {[], {:from, _, _}} = c -> inspect_chain(c, ctx, acc)
          {[], _} -> {node, acc}
          c -> inspect_chain(c, ctx, acc)
        end
      end)

    Enum.reverse(acc)
  end

  defp inspect_chain({ops, base} = chain, ctx, acc) do
    acc =
      case evaluate(chain, ctx) do
        nil -> acc
        hit -> [hit | acc]
      end

    extras = Enum.flat_map(ops, fn {_, _, rest} -> rest end)
    {{:__block__, [], extras ++ base_extras(base)}, acc}
  end

  defp base_extras({:from, _, _}), do: []
  defp base_extras({:__aliases__, _, _}), do: []
  defp base_extras(other), do: [other]

  # Walks down the first argument of query operations. Returns {ops, base}
  # with ops outermost first.
  defp chain(node, ctx) do
    {innermost_first, base} = descend(node, ctx, [])
    {Enum.reverse(innermost_first), base}
  end

  # `ops` accumulates innermost-first; `chain/2` reverses it once at the end.
  defp descend({op, meta, [first | rest]}, ctx, ops) when op in @ops and is_atom(op) do
    descend(first, ctx, [{op, meta[:line] || 1, rest} | ops])
  end

  defp descend({{:., _, [_, op]}, meta, [first | rest]} = node, ctx, ops) when op in @ops do
    case SafetySupport.remote_call(node, ctx.aliases) do
      {[:Ecto, :Query], ^op, _} -> descend(first, ctx, [{op, meta[:line] || 1, rest} | ops])
      _ -> {ops, node}
    end
  end

  defp descend(base, _, ops), do: {ops, base}

  defp evaluate({ops, base}, ctx) do
    {from_kw, from_line} = from_keywords(base)

    with [{line, amount} | _] <- all_limits(ops, from_kw, from_line),
         false <- ctx.ignore_one and literal_one?(amount),
         true <- known_base?(base),
         {:ok, fields} <- order_fields(ops, from_kw) do
      judge(line, fields, ctx)
    else
      _ -> nil
    end
  end

  defp all_limits(ops, from_kw, from_line) do
    limits = for {:limit, line, [amount]} <- ops, do: {line, amount}
    from_limit = if Keyword.has_key?(from_kw, :limit), do: [{from_line, from_kw[:limit]}]
    limits ++ List.wrap(from_limit)
  end

  defp judge(line, [], _) do
    {line,
     "limit without any order_by: which rows are returned is unspecified. " <>
       "Add an order_by that ends in a unique column (e.g. `asc: id`)."}
  end

  defp judge(line, fields, ctx) do
    if Enum.any?(fields, &QuerySupport.listed?(&1, ctx.unique)) do
      nil
    else
      {line,
       "limit with order_by #{Enum.map_join(Enum.uniq(fields), ", ", &inspect/1)} but no unique tiebreaker " <>
         "(#{Enum.map_join(ctx.unique, ", ", &QuerySupport.atom_label/1)}): rows with equal values come back in unstable order. " <>
         "Append a unique column to the order_by."}
    end
  end

  defp literal_one?(1), do: true
  defp literal_one?({:^, _, [1]}), do: true
  defp literal_one?(_), do: false

  defp from_keywords({:from, meta, args}) when is_list(args) do
    kw =
      case List.last(args) do
        list when is_list(list) -> if Keyword.keyword?(list), do: list, else: []
        _ -> []
      end

    {kw, meta[:line] || 1}
  end

  defp from_keywords(_), do: {[], 1}

  defp known_base?({:__aliases__, _, _}), do: true
  defp known_base?(base) when is_binary(base), do: true

  defp known_base?({:from, _, [{:in, _, [_, source]} | _]}),
    do: known_base?(source)

  defp known_base?(_), do: false

  # {:ok, fields} | :unknown. Fields are atoms; :unknown when anything is dynamic.
  defp order_fields(ops, from_kw) do
    exprs =
      for({:order_by, _, rest} <- ops, do: List.last(rest)) ++
        List.wrap(Keyword.get(from_kw, :order_by) && [from_kw[:order_by]])

    exprs
    |> Enum.map(&expr_fields/1)
    |> Enum.reduce_while({:ok, []}, fn
      :unknown, _ -> {:halt, :unknown}
      fields, {:ok, acc} -> {:cont, {:ok, acc ++ fields}}
    end)
  end

  defp expr_fields(list) when is_list(list) do
    fields = Enum.map(list, &entry_field/1)
    if :unknown in fields, do: :unknown, else: fields
  end

  defp expr_fields(other) do
    case entry_field(other) do
      :unknown -> :unknown
      field -> [field]
    end
  end

  defp entry_field({dir, expr}) when is_atom(dir), do: field_name(expr)
  defp entry_field(expr), do: field_name(expr)

  defp field_name({{:., _, [_, field]}, _, []}) when is_atom(field), do: field
  defp field_name({:field, _, [_, field]}) when is_atom(field), do: field
  defp field_name(field) when is_atom(field) and not is_nil(field), do: field
  defp field_name(_), do: :unknown
end
