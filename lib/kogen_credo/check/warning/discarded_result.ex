defmodule KogenCredo.Check.Warning.DiscardedResult do
  @moduledoc """
  Flags fallible calls whose `{:ok, _} | {:error, _}` result is thrown away.

  A failed insert or update that nobody looks at is a silent data-loss bug.
  The check reports a fallible call that is

    * a statement whose value is dropped (any expression of a block except the
      last one): `Repo.insert(changeset)` followed by more code
    * explicitly discarded with `_ = ...` (or `_ignored = ...`) in the same
      position (`flag_underscore_assignment`, default true)
    * the result of the function given to `Enum.each/2` / `Stream.each/2`:
      `Enum.each(attrs, fn a -> create_post(a) end)`, `&create_post/1` or
      `&Repo.insert/1`

  ## What counts as fallible

    * non-bang `Repo` writes in `repo_functions` (`insert`, `update`, `delete`,
      `insert_or_update`); the receiver must be an actual repo (alias aware,
      see `repo_names` / `repo_modules`)
    * any local or `Module.` call whose name matches `fallible_name_patterns`
      (globs, default `create_*`, `insert_*`, `update_*`, `delete_*`), except
      bang functions, `ignored_names` and modules in `ignored_modules`

  ## Limitations

  Fallibility is decided by name, so a helper called `update_cache` that
  returns `:ok` is a false positive (list it in `ignored_names`), while a
  fallible function with another name is missed. `_ =` with a justification
  comment cannot be distinguished from one without. The check does not follow
  results through variables or return values. Tests are excluded by default.

  The default `ignored_names` cover Ecto/Plug helpers matching the patterns
  that do not return `{:ok, _} | {:error, _}` (`Plug.CSRFProtection.delete_csrf_token/0`
  returns `:ok`; the `Plug.Conn` `delete_*`/`update_resp_header` functions return the
  conn). Functions that return a count or a bare value, such as
  `delete_comment/1` wrapping `Repo.delete_all/1`, cannot be recognised from
  the call site and need an `ignored_names` entry.
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      repo_functions: [:insert, :update, :delete, :insert_or_update],
      fallible_name_patterns: ["create_*", "insert_*", "update_*", "delete_*"],
      ignored_names: [
        "update_in",
        "update_change",
        "delete_change",
        "update_counter",
        "delete_csrf_token",
        "delete_session",
        "delete_req_header",
        "delete_resp_header",
        "delete_resp_cookie",
        "update_resp_header"
      ],
      ignored_modules: [
        "Map",
        "Keyword",
        "Enum",
        "List",
        "Access",
        "Changeset",
        "Multi",
        "Kernel"
      ],
      flag_bare_statement: true,
      flag_underscore_assignment: true,
      repo_names: ["Repo"],
      repo_modules: [],
      included_paths: [],
      excluded_paths: ["test/**"]
    ],
    explanations: [
      check: """
      A fallible call whose result is dropped hides failures.

      **Bad:**
      ```elixir
      _ = Repo.update(changeset)
      Enum.each(attrs, fn a -> create_post(a) end)
      ```

      **Good:**
      ```elixir
      {:ok, _post} = Repo.update(changeset)
      Enum.each(attrs, fn a -> {:ok, _} = create_post(a) end)
      ```

      Or collect results and handle the errors. Fallibility is guessed from
      function names; tune `fallible_name_patterns` and `ignored_names`.
      """,
      params: [
        repo_functions: "Repo functions that are fallible (non-bang writes).",
        fallible_name_patterns: "Globs of function names treated as fallible.",
        ignored_names: "Function names never treated as fallible.",
        ignored_modules: "Last module segments whose functions are never fallible.",
        flag_bare_statement: "Report fallible calls used as statements (default true).",
        flag_underscore_assignment: "Report `_ = fallible()` statements (default true).",
        repo_names: "Last module segments accepted as a repo (default `[\"Repo\"]`).",
        repo_modules: "Full repo module names accepted as a repo (strings).",
        included_paths: "Globs of files to check; empty means every file.",
        excluded_paths: "Globs of files to skip (default `[\"test/**\"]`)."
      ]
    ]

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.QuerySupport
  alias KogenCredo.SafetySupport

  @doc false
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    ast = QuerySupport.expanded_ast(source_file)

    if ast && QuerySupport.in_scope?(source_file, params, __MODULE__) do
      issue_meta = IssueMeta.for(source_file, params)

      ast
      |> hits(build_ctx(ast, params))
      |> QuerySupport.uniq_hits()
      |> Enum.map(fn {line, trigger, message} ->
        format_issue(issue_meta, message: message, trigger: trigger, line_no: line)
      end)
    else
      []
    end
  end

  defp build_ctx(ast, params) do
    %{
      aliases: SafetySupport.aliases(ast),
      repo_opts: QuerySupport.repo_opts(params, __MODULE__),
      repo_funs:
        params
        |> Params.get(:repo_functions, __MODULE__)
        |> QuerySupport.names(),
      patterns:
        params
        |> Params.get(:fallible_name_patterns, __MODULE__)
        |> Enum.map(&glob/1),
      ignored_names:
        params
        |> Params.get(:ignored_names, __MODULE__)
        |> Enum.map(&to_string/1),
      ignored_modules:
        params
        |> Params.get(:ignored_modules, __MODULE__)
        |> QuerySupport.names(),
      bare?: Params.get(params, :flag_bare_statement, __MODULE__),
      underscore?: Params.get(params, :flag_underscore_assignment, __MODULE__)
    }
  end

  defp glob(pattern) do
    body =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.compile!("^" <> body <> "$")
  end

  defp hits(ast, ctx) do
    {_, acc} = Macro.prewalk(ast, [], &collect_hits(&1, &2, ctx))
    Enum.reverse(acc)
  end

  defp collect_hits({:__block__, _, [_, _ | _] = exprs} = node, acc, ctx),
    do: {node, statement_hits(Enum.drop(exprs, -1), ctx) ++ acc}

  defp collect_hits({{:., _, [{:__aliases__, _, _}, :each]}, _, [_, fun]} = node, acc, ctx) do
    case SafetySupport.remote_call(node, ctx.aliases) do
      {segments, :each, _} -> {node, each_module_hits(segments, fun, ctx) ++ acc}
      nil -> {node, acc}
    end
  end

  defp collect_hits(node, acc, _), do: {node, acc}

  defp each_module_hits(segments, fun, ctx) do
    if SafetySupport.module?(segments, Enum) or SafetySupport.module?(segments, Stream),
      do: each_hits(fun, ctx),
      else: []
  end

  defp statement_hits(statements, ctx) do
    Enum.flat_map(statements, fn
      {:=, _, [{name, _, var_ctx}, rhs]} when is_atom(name) and is_atom(var_ctx) ->
        if ctx.underscore? and Ast.prefixed?(name, "_") do
          discard(rhs, "is assigned to `_`", ctx)
        else
          []
        end

      expr ->
        if ctx.bare?, do: discard(expr, "is used as a statement and dropped", ctx), else: []
    end)
  end

  defp each_hits({:fn, _, clauses}, ctx) do
    Enum.flat_map(clauses, fn
      {:->, _, [_, body]} ->
        last = last_expression(body)

        last
        |> unwrap_underscore()
        |> discard("is the return value of Enum.each, which ignores it", ctx)

      _ ->
        []
    end)
  end

  defp each_hits({:&, meta, [{:/, _, [target, arity]}]}, ctx) when is_integer(arity) do
    case capture_name(target, ctx) do
      nil ->
        []

      name ->
        [hit(meta[:line], name, "is captured into Enum.each, which ignores its return value")]
    end
  end

  defp each_hits({:&, meta, [body]}, ctx),
    do: discard_at(body, meta[:line], "is the return value of Enum.each, which ignores it", ctx)

  defp each_hits(_, _), do: []

  defp capture_name({name, _, var_ctx}, ctx) when is_atom(name) and is_atom(var_ctx),
    do: if(name_fallible?(name, ctx), do: Atom.to_string(name))

  defp capture_name({{:., _, [receiver, name]}, _, []}, ctx) when is_atom(name) do
    cond do
      SafetySupport.repo_receiver?(receiver, ctx.aliases, ctx.repo_opts) ->
        if QuerySupport.listed?(name, ctx.repo_funs), do: "Repo.#{name}"

      match?({:__aliases__, _, _}, receiver) and not ignored_module?(receiver, ctx) ->
        if name_fallible?(name, ctx), do: "#{name}"

      true ->
        nil
    end
  end

  defp capture_name(_, _), do: nil

  defp last_expression({:__block__, _, exprs}) when exprs != [], do: List.last(exprs)
  defp last_expression(other), do: other

  defp unwrap_underscore({:=, _, [{name, _, var_ctx}, rhs]})
       when is_atom(name) and is_atom(var_ctx) do
    if Ast.prefixed?(name, "_"), do: rhs, else: nil
  end

  defp unwrap_underscore(other), do: other

  defp discard(nil, _, _), do: []

  defp discard(expr, why, ctx) do
    case fallible(expr, ctx) do
      nil -> []
      {name, line} -> [hit(line, name, why)]
    end
  end

  defp discard_at(expr, line, why, ctx) do
    case fallible(expr, ctx) do
      nil -> []
      {name, found} -> [hit(found || line, name, why)]
    end
  end

  defp hit(line, name, why) do
    {line || 1, name,
     "Result of #{name} #{why}, so a failure (`{:error, _}`) goes unnoticed. " <>
       "Match `{:ok, _}`, handle the error, or use a bang variant that raises."}
  end

  # {display_name, line} | nil
  defp fallible({{:., _, [receiver, fun]}, meta, args} = node, ctx)
       when is_atom(fun) and is_list(args) do
    cond do
      SafetySupport.repo_call(node, ctx.aliases, ctx.repo_opts) ->
        if QuerySupport.listed?(fun, ctx.repo_funs), do: {"Repo.#{fun}", meta[:line]}

      match?({:__aliases__, _, _}, receiver) and not ignored_module?(receiver, ctx) ->
        if name_fallible?(fun, ctx), do: {"#{fun}", meta[:line]}

      true ->
        nil
    end
  end

  defp fallible({name, meta, args}, ctx) when is_atom(name) and is_list(args) do
    if name_fallible?(name, ctx), do: {Atom.to_string(name), meta[:line]}
  end

  defp fallible(_, _), do: nil

  defp ignored_module?({:__aliases__, _, parts}, ctx) do
    parts
    |> SafetySupport.expand(ctx.aliases)
    |> List.last()
    |> QuerySupport.listed?(ctx.ignored_modules)
  end

  defp name_fallible?(name, ctx) do
    string = Atom.to_string(name)

    not String.ends_with?(string, "!") and string not in ctx.ignored_names and
      Enum.any?(ctx.patterns, &Regex.match?(&1, string))
  end
end
