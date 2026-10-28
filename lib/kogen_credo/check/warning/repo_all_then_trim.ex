defmodule KogenCredo.Check.Warning.RepoAllThenTrim do
  @moduledoc """
  Flags `Repo.all` results that are cut down in memory instead of in SQL.

  `Repo.all(q) |> Enum.uniq_by(&f/1) |> Enum.take(n)` loads every matching row
  and then throws most of them away. Moving the bound into the query
  (`limit`, `distinct`, `where`, `group_by`) keeps the cost proportional to
  what is used.

  ## What is detected

    * pipelines of any length, including trimming steps after other `Enum`
      steps: `Repo.all(q) |> Enum.map(&f/1) |> Enum.take(5)`
    * the nested form `Enum.take(Repo.all(q), 5)`
    * a variable bound to a `Repo.all` result and trimmed later in the same
      function: `rows = Repo.all(q); Enum.at(rows, 0)`

  Trimming functions default to `Enum.take/uniq_by/slice/filter/at` and are
  configurable with `trimmer_functions`. The receiver must be an actual repo:
  aliases are resolved, and the module's last segment must be in `repo_names`
  (default `Repo`) or its full name in `repo_modules`.

  ## Limitations

  This is syntactic. It does not know a result set is small (a bounded query
  built elsewhere is still flagged), does not follow rows across function
  boundaries, and treats a rebound variable as still holding the old result.
  `Enum.filter/2` after `Repo.all` is sometimes the only option when the
  predicate cannot be expressed in SQL; narrow it with `trimmer_functions`.
  Only files matching `included_paths` and not `excluded_paths` are checked
  (tests are excluded by default).
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      trimmer_functions: [:take, :uniq_by, :slice, :filter, :at],
      repo_names: ["Repo"],
      repo_modules: [],
      included_paths: [],
      excluded_paths: ["test/**"]
    ],
    explanations: [
      check: """
      `Repo.all/1` followed by `Enum.take/uniq_by/slice/filter/at` loads every
      matching row, then discards most of them in memory. Every call pays for
      the whole table slice.

      **Bad:**
      ```elixir
      Query |> where([q], q.user_id == ^id) |> Repo.all() |> Enum.take(10)
      ```

      **Good:**
      ```elixir
      Query |> where([q], q.user_id == ^id) |> limit(10) |> Repo.all()
      ```

      Use `group_by`/`distinct` plus `limit` instead of `Enum.uniq_by/2` plus
      `Enum.take/2`. Heuristic: the check cannot tell that a result set is small.
      """,
      params: [
        trimmer_functions: "`Enum` functions that count as in-memory trimming (atoms).",
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
      ctx = %{
        aliases: SafetySupport.aliases(ast),
        repo_opts: QuerySupport.repo_opts(params, __MODULE__),
        trimmers:
          params
          |> Params.get(:trimmer_functions, __MODULE__)
          |> QuerySupport.names()
      }

      issue_meta = IssueMeta.for(source_file, params)

      ast
      |> hits(ctx)
      |> Enum.uniq_by(& &1)
      |> Enum.map(fn {line, fun} ->
        format_issue(issue_meta,
          message:
            "Repo.all result is trimmed in memory with Enum.#{fun}; every matching row is loaded first. " <>
              "Bound the query in SQL instead (limit, distinct/group_by, where).",
          trigger: "Enum.#{fun}",
          line_no: line
        )
      end)
    else
      []
    end
  end

  defp hits(ast, ctx) do
    def_hits =
      for def_node <- QuerySupport.defs(ast),
          hit <- node_hits(def_node, Map.put(ctx, :vars, repo_vars(def_node, ctx))),
          do: hit

    # Code outside any def (module body, scripts) has no variable tracking.
    top_hits =
      ast
      |> strip_defs()
      |> node_hits(Map.put(ctx, :vars, MapSet.new()))

    def_hits ++ top_hits
  end

  defp strip_defs(ast) do
    Macro.prewalk(ast, fn
      {kind, _, [_, _]} when kind in [:def, :defp, :defmacro, :defmacrop] -> nil
      node -> node
    end)
  end

  defp node_hits(ast, ctx) do
    {_, acc} = Macro.prewalk(ast, [], &trim_hit(&1, &2, ctx))
    Enum.reverse(acc)
  end

  defp trim_hit({{:., _, [{:__aliases__, _, _}, fun]}, meta, [first | _]} = node, acc, ctx)
       when is_atom(fun) do
    with {segments, ^fun, _} <- SafetySupport.remote_call(node, ctx.aliases),
         true <- SafetySupport.module?(segments, Enum),
         true <- QuerySupport.listed?(fun, ctx.trimmers),
         true <- derived?(first, ctx) do
      {node, [{meta[:line] || 1, fun} | acc]}
    else
      _ -> {node, acc}
    end
  end

  defp trim_hit(node, acc, _), do: {node, acc}

  # Variables assigned (in this def) from an expression derived from Repo.all.
  defp repo_vars(def_node, ctx) do
    {_, vars} =
      Macro.prewalk(def_node, MapSet.new(), fn
        {:=, _, [{name, _, var_ctx}, rhs]} = node, vars when is_atom(name) and is_atom(var_ctx) ->
          if derived?(rhs, Map.put(ctx, :vars, vars)),
            do: {node, MapSet.put(vars, name)},
            else: {node, vars}

        node, vars ->
          {node, vars}
      end)

    vars
  end

  # True when the expression is (a chain of Enum calls over) a Repo.all result.
  defp derived?({name, _, var_ctx}, ctx) when is_atom(name) and is_atom(var_ctx),
    do: MapSet.member?(ctx[:vars] || MapSet.new(), name)

  defp derived?({{:., _, _}, _, [first | _]} = node, ctx) do
    case SafetySupport.repo_call(node, ctx.aliases, ctx.repo_opts) do
      {:all, _} ->
        true

      {_, _} ->
        false

      nil ->
        case SafetySupport.remote_call(node, ctx.aliases) do
          {segments, _, _} ->
            SafetySupport.module?(segments, Enum) and derived?(first, ctx)

          nil ->
            false
        end
    end
  end

  defp derived?(_, _), do: false
end
