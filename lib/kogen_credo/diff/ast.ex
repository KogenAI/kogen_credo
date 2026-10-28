defmodule KogenCredo.Diff.Ast do
  @moduledoc false
  # AST helpers shared by the diff rules.

  alias KogenCredo.QuerySupport
  alias KogenCredo.SafetySupport

  @doc """
  `{name, arity}` of every local call in the AST. Pipes are expanded first, so
  `x |> helper(y)` is `helper/2`; `&helper/1` captures and `__MODULE__.helper(..)` count.
  Remote calls (`Mod.helper(..)`) do not.
  """
  @spec calls(Macro.t()) :: [{atom(), arity()}]
  def calls(ast) do
    {_, set} =
      ast
      |> QuerySupport.expand_pipes()
      |> Macro.prewalk(MapSet.new(), &record_call/2)

    MapSet.to_list(set)
  end

  defp record_call({:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = node, acc)
       when is_atom(name) and is_atom(ctx) and is_integer(arity),
       do: {node, MapSet.put(acc, {name, arity})}

  defp record_call({{:., _, [{:__MODULE__, _, ctx}, name]}, _, args} = node, acc)
       when is_atom(ctx) and is_atom(name) and is_list(args),
       do: {node, MapSet.put(acc, {name, length(args)})}

  defp record_call({name, _, args} = node, acc) when is_atom(name) and is_list(args),
    do: {node, MapSet.put(acc, {name, length(args)})}

  defp record_call(node, acc), do: {node, acc}

  @doc """
  The clauses of one side plus the clauses of every same-module function they reach,
  transitively. `self_key` is the `{name, arity}` of the function itself. Calls are matched by
  name and arity (a call to `f/1` also reaches `f/2` when `f/2` has one default argument), so
  an unrelated function of the same name and another arity is not pulled in, while a
  lower-arity head delegating to its higher-arity sibling is followed. An extract-function
  refactor therefore does not look like a loss.
  """
  @spec reachable([Macro.t()], map(), {atom(), arity()}) :: [Macro.t()]
  def reachable(clauses, module_fns, self_key) do
    helpers =
      clauses
      |> calls()
      |> walk(module_fns, MapSet.new([self_key]), [])

    clauses ++ Enum.concat(helpers)
  end

  defp walk([], _, _, acc), do: acc

  defp walk([{name, n} | rest], fns, seen, acc) do
    new =
      for {{^name, arity} = key, clauses} <- fns,
          callable?(clauses, arity, n),
          not MapSet.member?(seen, key),
          do: {key, clauses}

    found = Enum.map(new, fn {_, clauses} -> clauses end)
    marked = Enum.reduce(new, seen, fn {key, _}, marked -> MapSet.put(marked, key) end)
    more = Enum.flat_map(found, &calls/1)
    walk(more ++ rest, fns, marked, found ++ acc)
  end

  @doc false
  @spec callable?([Macro.t()], arity(), arity()) :: boolean()
  def callable?(_, arity, arity), do: true
  def callable?(clauses, arity, n), do: n < arity and n >= arity - defaults(clauses)

  defp defaults(clauses) do
    clauses
    |> Enum.map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] -> count(head_args(head), &default?/1)
      _ -> 0
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp head_args({:when, _, [head | _]}), do: head_args(head)
  defp head_args({_, _, args}) when is_list(args), do: args
  defp head_args(_), do: []

  defp default?({:\\, _, _}), do: true
  defp default?(_), do: false

  @doc "Function bodies without the heads (and guards) of the given def clauses."
  @spec bodies([Macro.t()]) :: [Macro.t()]
  def bodies(clauses) do
    Enum.flat_map(clauses, fn
      {kind, _, [_ | rest]} when kind in [:def, :defp] -> rest
      other -> [other]
    end)
  end

  @doc """
  Reduces over the AST. `fun.(node, acc)` returns `{:cont, acc}` to descend or `{:skip, acc}`.
  """
  @spec reduce(Macro.t(), term(), (Macro.t(), term() -> {:cont | :skip, term()})) :: term()
  def reduce(ast, acc, fun) do
    case fun.(ast, acc) do
      {:skip, acc} ->
        acc

      {:cont, acc} ->
        ast
        |> children()
        |> Enum.reduce(acc, &reduce(&1, &2, fun))
    end
  end

  defp children({form, _, args}) when is_list(args), do: [form | args]
  defp children({a, b}), do: [a, b]
  defp children(list) when is_list(list), do: list
  defp children(_), do: []

  @doc "Counts nodes matching the predicate."
  @spec count(Macro.t(), (Macro.t() -> boolean())) :: non_neg_integer()
  defdelegate count(ast, pred), to: SafetySupport

  @doc "Number of repo calls (optionally restricted to function names) in the AST."
  @spec repo_calls(Macro.t(), map(), keyword(), [atom()] | :any) :: non_neg_integer()
  def repo_calls(ast, aliases, opts, funs \\ :any) do
    count(ast, fn node ->
      case SafetySupport.repo_call(node, aliases, opts) do
        {fun, _} -> funs == :any or fun in funs
        nil -> false
      end
    end)
  end

  @doc "Strips a single-expression `__block__`."
  @spec unblock(Macro.t()) :: Macro.t()
  def unblock({:__block__, _, [single]}), do: single
  def unblock(other), do: other
end
