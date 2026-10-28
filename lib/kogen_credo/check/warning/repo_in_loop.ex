defmodule KogenCredo.Check.Warning.RepoInLoop do
  @moduledoc """
  Flags Repo calls that run once per element of a collection (N+1 queries).

  ## What is detected

    * `Enum.*` / `Stream.*` iteration functions (`map`, `each`, `flat_map`,
      `reduce`, `filter`, ... configurable with `loop_functions`) whose function
      argument contains a Repo call, directly or through local helpers
    * `for` comprehensions whose filters, later generators or body call the Repo
    * function captures: `&Repo.get(User, &1)`, `&Repo.get/2`, `&helper/1` and
      `&__MODULE__.helper/1` where the helper (transitively, up to `max_depth`
      local hops, default 3) reaches a Repo call

  The first generator of a `for` and the collection argument of `Enum` calls
  are not part of the loop. Only the outermost loop of a nest is reported.

  ## Limitations

  Syntactic and advisory. Helpers are matched by name and arity inside the
  same file; calls into other modules, `apply/3`, behaviours and anonymous
  functions held in variables are not followed. Calls through
  `Task.async_stream` and friends are not loop functions. A loop over a small,
  bounded list (say six elements) is perfectly fine and will still be
  reported, as will intentional batch writes. Only files matching
  `included_paths` and not `excluded_paths` are checked (tests excluded by
  default).
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      loop_functions: [
        :map,
        :each,
        :flat_map,
        :reduce,
        :reduce_while,
        :map_reduce,
        :filter,
        :reject,
        :find,
        :any?,
        :all?,
        :sort_by,
        :group_by,
        :min_by,
        :max_by
      ],
      repo_functions: [
        :all,
        :stream,
        :one,
        :one!,
        :get,
        :get!,
        :get_by,
        :get_by!,
        :exists?,
        :aggregate,
        :preload,
        :reload,
        :reload!,
        :insert,
        :insert!,
        :update,
        :update!,
        :delete,
        :delete!,
        :insert_or_update,
        :insert_or_update!
      ],
      max_depth: 3,
      repo_names: ["Repo"],
      repo_modules: [],
      included_paths: [],
      excluded_paths: ["test/**"]
    ],
    explanations: [
      check: """
      A Repo call inside an iteration runs one query per element (N+1).

      **Bad:**
      ```elixir
      Enum.map(posts, fn post -> Repo.get(User, post.user_id) end)
      ```

      **Good:**
      ```elixir
      users = from(u in User, where: u.id in ^Enum.map(posts, & &1.user_id)) |> Repo.all()
      ```

      Preload associations, fetch with `where ... in ^ids` and join in memory,
      or use `Repo.insert_all`/`update_all` for batch writes. Heuristic: loops
      over small bounded collections are often fine.
      """,
      params: [
        loop_functions: "`Enum`/`Stream` function names treated as per-element loops.",
        repo_functions: "Repo function names that count as a query.",
        max_depth: "How many local helper calls deep a Repo call is searched (default 3).",
        repo_names: "Last module segments accepted as a repo (default `[\"Repo\"]`).",
        repo_modules: "Full repo module names accepted as a repo (strings).",
        included_paths: "Globs of files to check; empty means every file.",
        excluded_paths: "Globs of files to skip (default `[\"test/**\"]`)."
      ]
    ]

  alias KogenCredo.QuerySupport
  alias KogenCredo.SafetySupport

  @doc false
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    ast = QuerySupport.expanded_ast(source_file)

    if ast && QuerySupport.in_scope?(source_file, params, __MODULE__) do
      scopes = QuerySupport.module_scopes(ast)
      ctx = build_ctx(ast, scopes, params)
      issue_meta = IssueMeta.for(source_file, params)

      scopes
      |> Enum.flat_map(fn {mod, body} -> loop_hits(body, %{ctx | mod: mod}) end)
      |> QuerySupport.uniq_hits()
      |> Enum.map(fn {line, trigger, message} ->
        format_issue(issue_meta, message: message, trigger: trigger, line_no: line)
      end)
    else
      []
    end
  end

  defp build_ctx(ast, scopes, params) do
    %{
      aliases: SafetySupport.aliases(ast),
      fns: function_index(scopes),
      mod: nil,
      modules: for({mod, _} <- scopes, mod != nil, do: mod),
      repo_opts: QuerySupport.repo_opts(params, __MODULE__),
      loops:
        params
        |> Params.get(:loop_functions, __MODULE__)
        |> QuerySupport.names(),
      repo_funs:
        params
        |> Params.get(:repo_functions, __MODULE__)
        |> QuerySupport.names(),
      max_depth: Params.get(params, :max_depth, __MODULE__)
    }
  end

  # Functions are keyed by {module, name, arity}: a helper is only ever resolved inside the
  # module it belongs to, or through an explicit `Alias.fun` / `__MODULE__.fun` call.
  defp function_index(scopes) do
    entries =
      for {mod, body} <- scopes,
          def_node <- QuerySupport.defs(body),
          {_, _, [head, fun_body]} = def_node,
          {name, arity} <- QuerySupport.head_keys(head),
          do: {{mod, name, arity}, fun_body}

    Enum.group_by(entries, fn {key, _} -> key end, fn {_, fun_body} -> fun_body end)
  end

  defp loop_hits(ast, ctx) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case loop_hit(node, ctx) do
          {line, trigger, message, collection} -> {collection, [{line, trigger, message} | acc]}
          nil -> {node, acc}
        end
      end)

    acc
    |> Enum.reverse()
    |> QuerySupport.uniq_hits()
  end

  # Enum.map(coll, fun) and friends (pipes are already expanded).
  defp loop_hit(
         {{:., _, [{:__aliases__, _, _}, fun]}, meta, [collection, _ | _] = args} = node,
         ctx
       )
       when is_atom(fun) do
    case loop_repo(node, fun, args, ctx) do
      {mod, found} -> loop_result(mod, fun, meta[:line] || 1, collection, found)
      nil -> nil
    end
  end

  defp loop_hit({:for, meta, [first | rest]}, ctx) when rest != [] do
    case find_repo(rest, ctx, ctx.max_depth, MapSet.new()) do
      {repo_fun, via} ->
        {meta[:line] || 1, "for", message("for", repo_fun, via), generator_source(first)}

      nil ->
        nil
    end
  end

  defp loop_hit(_, _), do: nil

  defp generator_source({:<-, _, [_, enumerable]}), do: enumerable
  defp generator_source(other), do: other

  defp loop_repo(node, fun, args, ctx) do
    with {segments, ^fun, _} <- SafetySupport.remote_call(node, ctx.aliases),
         mod when mod in [Enum, Stream] <- loop_module(segments),
         true <- QuerySupport.listed?(fun, ctx.loops),
         found when found != nil <- fun_repo(List.last(args), ctx) do
      {mod, found}
    else
      _ -> nil
    end
  end

  defp loop_result(mod, fun, line, collection, {repo_fun, via}) do
    trigger = "#{inspect(mod)}.#{fun}"
    {line, trigger, message(trigger, repo_fun, via), collection}
  end

  defp loop_module(segments) do
    cond do
      SafetySupport.module?(segments, Enum) -> Enum
      SafetySupport.module?(segments, Stream) -> Stream
      true -> nil
    end
  end

  defp message(trigger, repo_fun, nil) do
    "Repo.#{repo_fun} runs once per element inside #{trigger} (N+1 queries). " <>
      "Fetch in one query (where ... in ^ids, preload, join) or batch the write; ignore only if the list is small and bounded."
  end

  defp message(trigger, repo_fun, via) do
    "Local helper #{via} reaches Repo.#{repo_fun} and runs once per element inside #{trigger} (N+1 queries). " <>
      "Fetch in one query (where ... in ^ids, preload, join) or batch the write; ignore only if the list is small and bounded."
  end

  # The function argument of a loop call.
  defp fun_repo({:fn, _, _} = fun, ctx), do: find_repo(fun, ctx, ctx.max_depth, MapSet.new())

  defp fun_repo({:&, _, [{:/, _, [target, arity]}]}, ctx) when is_integer(arity) do
    capture_target(target, arity, ctx)
  end

  defp fun_repo({:&, _, [body]}, ctx), do: find_repo(body, ctx, ctx.max_depth, MapSet.new())
  defp fun_repo(_, _), do: nil

  # &helper/1, &Repo.get/2, &__MODULE__.helper/1, &Sibling.helper/1
  defp capture_target({name, _, var_ctx}, arity, ctx) when is_atom(name) and is_atom(var_ctx),
    do: via_local({ctx.mod, name, arity}, ctx, ctx.max_depth, MapSet.new())

  defp capture_target({{:., _, [receiver, name]}, _, []}, arity, ctx) when is_atom(name) do
    cond do
      SafetySupport.repo_receiver?(receiver, ctx.aliases, ctx.repo_opts) ->
        if QuerySupport.listed?(name, ctx.repo_funs), do: {name, nil}

      mod = resolve_module(receiver, ctx) ->
        via_local({mod, name, arity}, ctx, ctx.max_depth, MapSet.new())

      true ->
        nil
    end
  end

  defp capture_target(_, _, _), do: nil

  defp via_local({_, name, _} = key, ctx, depth, visited) do
    case Map.fetch(ctx.fns, key) do
      {:ok, bodies} ->
        case find_repo(bodies, in_module(ctx, key), depth, MapSet.put(visited, key)) do
          {repo_fun, _} -> {repo_fun, name}
          nil -> nil
        end

      :error ->
        nil
    end
  end

  defp in_module(ctx, {mod, _, _}), do: %{ctx | mod: mod}

  # The file-local module a receiver denotes: `__MODULE__`, or an alias naming a `defmodule` of
  # this file (also relative to the enclosing module, as Elixir aliases nested modules).
  defp resolve_module({:__MODULE__, _, _}, ctx), do: ctx.mod

  defp resolve_module({:__aliases__, _, parts}, ctx) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      Enum.find(
        [SafetySupport.expand(parts, ctx.aliases), (ctx.mod || []) ++ parts],
        fn candidate ->
          candidate in ctx.modules
        end
      )
    end
  end

  defp resolve_module(_, _), do: nil

  # Finds the first Repo call in `ast`, following local helpers `depth` hops.
  # Returns {repo_function, helper_name | nil} or nil.
  defp find_repo(ast, ctx, depth, visited) do
    {_, {found, calls}} =
      Macro.prewalk(ast, {nil, []}, fn
        node, {nil, calls} ->
          case direct_repo(node, ctx) do
            nil -> {node, {nil, local_key(node, ctx, calls)}}
            fun -> {node, {{fun, nil}, calls}}
          end

        node, acc ->
          {node, acc}
      end)

    found || follow(Enum.reverse(calls), ctx, depth, visited)
  end

  defp follow(_, _, 0, _), do: nil

  defp follow(calls, ctx, depth, visited) do
    calls
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(visited, &1))
    |> Enum.find_value(&follow_call(&1, ctx, depth, visited))
  end

  defp follow_call({_, name, _} = key, ctx, depth, visited) do
    with {:ok, bodies} <- Map.fetch(ctx.fns, key),
         {fun, _} <- find_repo(bodies, in_module(ctx, key), depth - 1, MapSet.put(visited, key)) do
      {fun, name}
    else
      _ -> nil
    end
  end

  defp direct_repo(node, ctx) do
    case SafetySupport.repo_call(node, ctx.aliases, ctx.repo_opts) do
      {fun, _} -> if QuerySupport.listed?(fun, ctx.repo_funs), do: fun
      nil -> nil
    end
  end

  defp local_key({name, _, args}, ctx, calls) when is_atom(name) and is_list(args) do
    key = {ctx.mod, name, length(args)}
    if Map.has_key?(ctx.fns, key), do: [key | calls], else: calls
  end

  defp local_key({{:., _, [receiver, name]}, _, args}, ctx, calls)
       when is_atom(name) and is_list(args) do
    with mod when mod != nil <- resolve_module(receiver, ctx),
         key = {mod, name, length(args)},
         true <- Map.has_key?(ctx.fns, key) do
      [key | calls]
    else
      _ -> calls
    end
  end

  defp local_key(_, _, calls), do: calls
end
