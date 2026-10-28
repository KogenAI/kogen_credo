defmodule KogenCredo.Diff.Rules.NewRepoInLoop do
  @moduledoc """
  `new-repo-in-loop`: the head has more repo calls executed once per element than the base
  (a likely new N+1).

  Loops recognised: `Enum.*` / `Stream.*` iteration functions and `Task.async_stream` with an
  `fn` or capture argument, and `for` (body, filters and every generator after the first).
  Inside a loop body a repo call counts directly (`Repo.get/2`, `Repo.preload/2`, ...,
  including `&Repo.get(User, &1)` captures); a call to a same-module function counts when that
  function (transitively) reaches a repo call, which covers `&helper/1` and `helper(x)`. Writes
  count only with the option `include_writes: true`.

  The count is of call sites (by position), so a call site that merely moves is quiet. New
  functions are compared with zero.

  ## Limits

  Helpers in other modules, `Enum.map(ids, &Mod.fun/1)` with a remote function that queries,
  and recursion are invisible. A bounded list (six items) is flagged just the same; the rule is
  a prompt to check for a batch query or preload. Advisory by default.
  """

  alias KogenCredo.Diff.Ast
  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding
  alias KogenCredo.QuerySupport
  alias KogenCredo.SafetySupport

  @behaviour KogenCredo.Diff.Rule

  @enum_funs ~w(map each flat_map reduce reduce_while filter reject map_reduce find find_value
                any? all? count map_join group_by sort_by uniq_by min_by max_by sum_by
                with_index zip_with take_while drop_while chunk_by frequencies_by)a
  @read_extra [:preload, :reload, :reload!]

  @impl KogenCredo.Diff.Rule
  def id, do: "new-repo-in-loop"

  @impl KogenCredo.Diff.Rule
  def default_severity, do: :advisory

  @impl KogenCredo.Diff.Rule
  def check(%Change{} = c, opts) do
    base = if c.base, do: sites(c, :base, opts), else: MapSet.new()
    head = sites(c, :head, opts)

    if MapSet.size(head) > MapSet.size(base) do
      [
        Finding.for_change(
          id(),
          c,
          "#{MapSet.size(head)} repo call site(s) run once per element in a loop (base: " <>
            "#{MapSet.size(base)}). Each iteration is a query; batch with a single " <>
            "`where id in ^ids`, `Repo.preload` or a join. Heuristic: only same-module helpers " <>
            "are followed."
        )
      ]
    else
      []
    end
  end

  defp sites(c, side, opts) do
    {clauses, module_fns, aliases} = Change.side(c, side)
    funs = repo_funs(opts)

    expanded =
      clauses
      |> Ast.bodies()
      |> QuerySupport.expand_pipes()

    {_, set} =
      Macro.prewalk(
        expanded,
        MapSet.new(),
        fn node, acc ->
          bodies = loop_bodies(node, aliases)

          acc =
            Enum.reduce(bodies, acc, fn body, acc ->
              MapSet.union(acc, repo_sites(body, module_fns, aliases, opts, funs))
            end)

          {node, acc}
        end
      )

    set
  end

  defp repo_funs(opts) do
    base = SafetySupport.repo_reads() ++ @read_extra

    if Keyword.get(opts, :include_writes, false),
      do: base ++ SafetySupport.repo_writes(),
      else: base
  end

  # Nodes executed once per element for a loop node, else [].
  defp loop_bodies({:for, _, args}, _) when is_list(args) do
    {opts, rest} = Enum.split_with(args, &is_list/1)

    body = for kw <- opts, {:do, b} <- kw, do: b
    {gens, filters} = Enum.split_with(rest, &match?({:<-, _, _}, &1))

    later_gens =
      case gens do
        [_ | later] -> later
        [] -> []
      end

    body ++ filters ++ later_gens
  end

  defp loop_bodies(node, aliases) do
    case SafetySupport.remote_call(node, aliases) do
      {[mod], fun, args} when mod in [:Enum, :Stream] and fun in @enum_funs ->
        Enum.filter(args, &lambda?/1)

      {[:Task], :async_stream, args} ->
        Enum.filter(args, &lambda?/1)

      _ ->
        []
    end
  end

  defp lambda?({:fn, _, _}), do: true
  defp lambda?({:&, _, _}), do: true
  defp lambda?(_), do: false

  defp repo_sites(body, module_fns, aliases, opts, funs) do
    {_, set} =
      Macro.prewalk(body, MapSet.new(), fn node, acc ->
        {node, add_site(node, acc, module_fns, aliases, opts, funs)}
      end)

    set
  end

  defp add_site({:/, _, [{name, _, ctx}, arity]} = node, acc, module_fns, aliases, opts, funs)
       when is_atom(name) and is_atom(ctx) and is_integer(arity) do
    if helper_reaches_repo?(name, arity, module_fns, aliases, opts, funs),
      do: MapSet.put(acc, site(node)),
      else: acc
  end

  defp add_site({name, _, args} = node, acc, module_fns, aliases, opts, funs)
       when is_atom(name) and is_list(args) do
    if helper_reaches_repo?(name, length(args), module_fns, aliases, opts, funs),
      do: MapSet.put(acc, site(node)),
      else: acc
  end

  defp add_site(node, acc, _, aliases, opts, funs),
    do: if(repo_fun?(node, aliases, opts, funs), do: MapSet.put(acc, site(node)), else: acc)

  defp repo_fun?(node, aliases, opts, funs) do
    case SafetySupport.repo_call(node, aliases, opts) do
      {fun, _} -> fun in funs
      nil -> false
    end
  end

  defp helper_reaches_repo?(name, arity, module_fns, aliases, opts, funs) do
    keys = for {{^name, a} = key, h} <- module_fns, Ast.callable?(h, a, arity), do: key

    Enum.any?(keys, fn key ->
      all = Ast.reachable(Map.fetch!(module_fns, key), module_fns, key)
      Ast.count(all, &repo_fun?(&1, aliases, opts, funs)) > 0
    end)
  end

  defp site({form, meta, args}), do: {form_key(form), meta[:line], meta[:column], length_of(args)}
  defp form_key(form) when is_atom(form), do: form
  defp form_key(_), do: :call
  defp length_of(args) when is_list(args), do: length(args)
  defp length_of(_), do: 0
end
