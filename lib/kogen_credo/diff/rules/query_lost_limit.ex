defmodule KogenCredo.Diff.Rules.QueryLostLimit do
  @moduledoc """
  `query-lost-limit`: a changed function that builds or runs an Ecto query bounded it in SQL at
  the base (`limit`, `from ... limit:`, `first`/`last`, a `*paginat*` call) and no longer does
  at the head.

  Bounds and repo reads are counted in the function plus every same-module function it reaches
  (transitively, by name), so moving the `limit` into a helper is quiet. A bound that left
  together with its whole query (fewer repo reads) is not a hit. The repo receiver is
  alias-aware (`:repo_names`, `:repo_modules`). Multi-clause and guarded functions are judged as
  a whole.

  Evidence in the message: Enum stages after `Repo.all` (`take`, `uniq_by`, `slice`, ...), the
  usual in-memory replacement.

  ## Limits

  A bound moved into another module's query builder is a false hit; a query built in one
  function and run unbounded in its caller is only caught when the builder itself lost the
  bound; limits held in module attributes or macros are invisible. Bounds are counted over the
  whole function plus its helpers, so a bound lost from one query can be masked by a bound added
  to another query of the same function. Advisory by default; this implementation has not been
  swept on any history, and no precision is claimed.
  """

  alias KogenCredo.Diff.Ast
  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding
  alias KogenCredo.SafetySupport

  @behaviour KogenCredo.Diff.Rule

  @query_macros [:from, :where, :order_by, :select, :join, :group_by, :distinct, :preload]
  @truncators [:take, :slice, :uniq_by, :uniq, :at, :filter, :reject, :find, :dedup_by]

  @impl KogenCredo.Diff.Rule
  def id, do: "query-lost-limit"

  @impl KogenCredo.Diff.Rule
  def default_severity, do: :advisory

  @impl KogenCredo.Diff.Rule
  def check(%Change{base: nil}, _), do: []

  def check(%Change{} = c, opts) do
    {b_bounds, b_reads} = metrics(c, :base, opts)
    {h_bounds, h_reads} = metrics(c, :head, opts)
    lost = b_bounds - h_bounds - max(b_reads - h_reads, 0)

    if lost > 0 and query_shaped?(c, opts) do
      [
        Finding.for_change(
          id(),
          c,
          message(b_bounds, h_bounds, truncation(c.head, c.head_aliases, opts))
        )
      ]
    else
      []
    end
  end

  defp message(base, head, truncation) do
    tail =
      case truncation do
        [] ->
          "Rows are no longer bounded in SQL."

        funs ->
          "Repo.all is now followed by #{Enum.map_join(funs, ", ", &"Enum.#{&1}")}: " <>
            "every matching row is loaded, then cut in memory."
      end

    "The base bounded this query #{base}x (limit/first/paginate), the head #{head}x. " <>
      tail <>
      " Keep the bound in the query (e.g. group_by or distinct plus limit). " <>
      "Heuristic: bounds moved into another module are not seen."
  end

  defp metrics(c, side, opts) do
    {clauses, module_fns, aliases} = Change.side(c, side)
    all = Ast.reachable(clauses, module_fns, Change.self_key(c, side))
    # Bounds are counted in bodies: a function *named* `paginate_x` is not a bound.
    bodies = Ast.bodies(all)

    {Ast.count(bodies, &bound?/1),
     Ast.count(all, fn node ->
       match?(
         {fun, _} when fun in [:all, :stream, :one, :one!],
         SafetySupport.repo_call(node, aliases, opts)
       )
     end)}
  end

  defp query_shaped?(c, opts) do
    Ast.count(c.head, fn node ->
      match?(
        {fun, _} when fun in [:all, :stream],
        SafetySupport.repo_call(node, c.head_aliases, opts)
      ) or
        query_macro?(node)
    end) > 0
  end

  defp bound?({:limit, _, args}) when is_list(args) and length(args) in 1..3, do: true
  defp bound?({:first, _, args}) when is_list(args) and length(args) in 0..2, do: true
  defp bound?({:last, _, args}) when is_list(args) and length(args) in 0..2, do: true

  defp bound?({:from, _, [_, kw]}) when is_list(kw),
    do: Enum.any?(kw, &match?({:limit, _}, &1))

  defp bound?({{:., _, [{:__aliases__, _, parts}, fun]}, _, _})
       when fun in [:limit, :first, :last],
       do: List.last(parts) == :Query

  defp bound?({{:., _, [_, fun]}, _, _}) when is_atom(fun), do: paginate?(fun)
  defp bound?({fun, _, args}) when is_atom(fun) and is_list(args), do: paginate?(fun)
  defp bound?(_), do: false

  defp paginate?(fun) do
    fun
    |> Atom.to_string()
    |> String.contains?("paginat")
  end

  defp query_macro?({name, _, args}) when name in @query_macros and is_list(args), do: true

  defp query_macro?({{:., _, [{:__aliases__, _, parts}, name]}, _, _}) when name in @query_macros,
    do: List.last(parts) == :Query

  defp query_macro?(_), do: false

  # Enum stages after a Repo.all/stream, in a pipeline or as `Enum.take(Repo.all(q), n)`.
  defp truncation(ast, aliases, opts) do
    {_, funs} = Macro.prewalk(ast, [], &collect_truncation(&1, &2, aliases, opts))
    Enum.uniq(funs)
  end

  defp collect_truncation({:|>, _, _} = pipe, acc, aliases, opts) do
    stages = SafetySupport.pipeline_stages(pipe)

    case Enum.find_index(stages, &fetch_in?(&1, aliases, opts)) do
      nil ->
        {pipe, acc}

      i ->
        after_fetch =
          stages
          |> Enum.drop(i + 1)
          |> Enum.flat_map(&truncator(&1, aliases))

        {pipe, acc ++ after_fetch}
    end
  end

  defp collect_truncation({{:., _, _}, _, [first | _]} = call, acc, aliases, opts) do
    if fetch_in?(first, aliases, opts),
      do: {call, acc ++ truncator(call, aliases)},
      else: {call, acc}
  end

  defp collect_truncation(node, acc, _, _), do: {node, acc}

  defp fetch_in?(ast, aliases, opts) do
    Ast.count(ast, fn node ->
      match?({fun, _} when fun in [:all, :stream], SafetySupport.repo_call(node, aliases, opts))
    end) > 0
  end

  defp truncator(stage, aliases) do
    case SafetySupport.remote_call(stage, aliases) do
      {[:Enum], fun, _} when fun in @truncators -> [fun]
      _ -> []
    end
  end
end
