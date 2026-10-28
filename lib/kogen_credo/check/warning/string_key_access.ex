defmodule KogenCredo.Check.Warning.StringKeyAccess do
  @moduledoc """
  Flags string-keyed map use outside declared codec/boundary code: `x["k"]`,
  `Map.get/fetch/put/...(x, "k")` (also piped, and through `alias Map, as: M`),
  `Map.take/drop/split(x, ["k", ...])`, `get_in`/`put_in`/`update_in`/`pop_in(x, [..., "k", ...])`
  and `%{"k" => _}` literals and patterns.

  String keys are the wire format. Decode once in a boundary module into a struct,
  then use fields inside the core.

  ## Framework contracts that are not reported

  Some string keys are dictated by the framework, so the callback head *is* the boundary:

    * the wire argument of Phoenix callbacks `handle_event/3`, `handle_params/3`,
      `mount/3`, `on_mount/4` (only in a module that declares LiveView: `use Phoenix.LiveView`,
      `use Phoenix.LiveComponent`, `use App, :live_view|:live_component` or the matching
      `@behaviour`/`@impl Phoenix.LiveView`) and `handle_in/3`, `join/3` (only in a channel:
      `use Phoenix.Channel`, `use App, :channel`, `@behaviour Phoenix.Channel`), so a business
      `join/3` or a bare `@impl true` is still reported; of controller actions
      (`def action(conn, params)` in a module that is a controller), of
      `Oban.Worker.perform/1` (`%Oban.Job{args: ...}`) and of `Ecto.Type`
      `cast/load/dump`, plus reads from the variables those patterns bind
      (`params["q"]`, `Map.get(session, "k")`);
    * `Plug.Conn` string-keyed fields (`conn.params`, `conn.cookies`, `conn.req_cookies`,
      `conn.query_params`, `conn.body_params`, `conn.path_params`) read through a variable
      named `conn` (or one bound by a `%Plug.Conn{} = c` head), and `params:` / `cookies:`
      patterns of `%Plug.Conn{...}` or of a map matched against such a `conn`
      (`%{params: %{"k" => v}} = conn`). Other receivers (`webhook.params["k"]`,
      `%Event{params: %{"k" => v}}`) are reported;
    * Ecto JSON paths inside query macros (`dynamic([d], d.meta["status"] == ^s)`);
    * a map literal passed straight to `Jason.encode!/1`, `Jason.encode/1`,
      `Poison.encode!/1` or `URI.encode_query/1` (producing a wire document).

  Everything else (using those values after they were passed on, external API
  bodies, webhook payloads, `Oban` job args built by callers) is still reported.

  ## Allowing codec code

    * `codec_modules`: modules (and everything nested under them) that may use
      string keys, e.g. `[MyApp.Codec, MyApp.Wire]`.
    * `codec_globs`: file globs for the same purpose, e.g.
      `["lib/**/*_codec.ex", "lib/**/wire/**/*.ex"]`.

  ## Limitations

  Only literal string keys are seen. Maps built from string variables, header lists
  and `Regex.named_captures/2` results are not tracked. Modules that legitimately
  work with wire data (controllers, parsers, CLI argument handlers) should be listed
  in `codec_modules` / `codec_globs` or excluded via `excluded_paths`. The framework
  exemptions are name-based within one function (no shadowing analysis), and a LiveView
  `on_mount` hook module that only `import`s `Phoenix.LiveView` is not recognised.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/"],
      excluded_paths: [],
      codec_modules: [],
      codec_globs: []
    ],
    explanations: [
      check: """
      Decode external JSON/YAML/params once, in a codec module, into a struct, and use
      struct fields inside the core. String-keyed maps spread the wire shape through
      the code base and turn typos into silent `nil`s.
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped.",
        codec_modules: "Modules (and nested modules) allowed to use string keys.",
        codec_globs: "Filename globs allowed to use string keys."
      ]
    ]

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Modules
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings

  @map_funs [
    :get,
    :fetch,
    :fetch!,
    :has_key?,
    :put,
    :put_new,
    :put_new_lazy,
    :update,
    :update!,
    :delete,
    :pop,
    :pop_lazy,
    :get_lazy,
    :get_and_update,
    :replace,
    :replace!
  ]
  @map_list_funs [:take, :drop, :split]
  @path_funs [:get_in, :put_in, :update_in, :pop_in, :get_and_update_in]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)
    globs = Params.get(params, :codec_globs, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) and not Paths.matches_any?(filename, globs) do
      issue_meta = IssueMeta.for(source_file, params)

      codecs =
        params
        |> Params.get(:codec_modules, __MODULE__)
        |> Settings.modules!(:codec_modules)

      source_file
      |> SourceFile.ast()
      |> Modules.prune(codecs)
      |> Ast.expand_pipes()
      |> exempt_contracts()
      |> Scope.walk([], &collect_hit(&1, &2, &3, issue_meta))
      |> Enum.reverse()
    else
      []
    end
  end

  defp collect_hit(node, env, acc, issue_meta) do
    case hit(node, env.aliases) do
      {line, what} -> [issue(issue_meta, line, what) | acc]
      nil -> acc
    end
  end

  # ---- framework contracts -------------------------------------------------------------
  # String keys are neutralised (replaced by an atom) in the AST before the walk, so the
  # detector below stays the single place that decides what a hit is.

  @conn_fields [:params, :cookies, :req_cookies, :query_params, :body_params, :path_params]
  @query_macros [
    :dynamic,
    :from,
    :where,
    :or_where,
    :having,
    :or_having,
    :select,
    :select_merge,
    :order_by,
    :group_by,
    :distinct,
    :join
  ]
  @encoders [:encode!, :encode, :encode_to_iodata!, :encode_to_iodata, :encode_query]
  # callback => {module kind that declares the contract, wire argument indexes}
  @wire_callbacks %{
    {:handle_event, 3} => {:live, [1]},
    {:handle_params, 3} => {:live, [0]},
    {:mount, 3} => {:live, [0, 1]},
    {:on_mount, 4} => {:live, [1, 2]},
    {:handle_in, 3} => {:channel, [1]},
    {:join, 3} => {:channel, [1]}
  }
  @phoenix_kinds %{LiveView: :live, LiveComponent: :live, Channel: :channel}
  @web_kinds %{live_view: :live, live_component: :live, channel: :channel}
  @ecto_type_callbacks %{
    {:cast, 1} => [0],
    {:cast, 2} => [0],
    {:load, 1} => [0],
    {:dump, 1} => [0]
  }

  defp exempt_contracts(ast) do
    ast
    |> Macro.prewalk(fn
      {:defmodule, meta, [name, [do: body]]} ->
        {:defmodule, meta, [name, [do: exempt_module(body, name)]]}

      node ->
        node
    end)
    |> Macro.prewalk(&exempt_expression/1)
    |> Macro.prewalk(&exempt_conn(&1, [:conn]))
  end

  defp exempt_module(body, name) do
    kinds = module_kinds(body, name)
    map_top_level(body, &exempt_statement(&1, kinds))
  end

  defp exempt_statement(stmt, kinds) do
    case Ast.def_clause(stmt) do
      {:ok, {_, fname, args, _, _, _}} -> exempt_def(stmt, kinds, fname, args)
      :error -> stmt
    end
  end

  defp exempt_def(stmt, kinds, fname, args) do
    exempted =
      args
      |> bound_conn_names()
      |> then(&exempt_bound_conn(stmt, &1))

    indexes = wire_indexes(kinds, fname, args)
    neutralise_wire(exempted, indexes)
  end

  defp neutralise_wire(stmt, []), do: stmt
  defp neutralise_wire(stmt, indexes), do: neutralise_clause(stmt, indexes)

  defp map_top_level({:__block__, m, stmts}, fun) when is_list(stmts),
    do: {:__block__, m, Enum.map(stmts, fun)}

  defp map_top_level(stmt, fun), do: fun.(stmt)

  defp module_kinds(body, name) do
    stmts =
      body
      |> Ast.strip_modules()
      |> top_level()

    kinds = Enum.reduce(stmts, MapSet.new(), &statement_kinds/2)
    add_controller(kinds, last_segment(name))
  end

  defp statement_kinds({:use, _, [mod | rest]}, acc), do: MapSet.union(acc, use_kinds(mod, rest))

  defp statement_kinds({:@, _, [{attr, _, [mod]}]}, acc) when attr in [:behaviour, :impl],
    do: MapSet.union(acc, use_kinds(mod, []))

  defp statement_kinds(_, acc), do: acc

  defp last_segment({:__aliases__, _, parts}) do
    parts
    |> List.last()
    |> to_string()
  end

  defp last_segment(_), do: ""

  defp add_controller(kinds, last) do
    if String.ends_with?(last, "Controller"), do: MapSet.put(kinds, :controller), else: kinds
  end

  defp top_level({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp top_level(stmt), do: [stmt]

  defp use_kinds({:__aliases__, _, [:Oban | _] = parts}, _) do
    if List.last(parts) == :Worker, do: MapSet.new([:oban]), else: MapSet.new()
  end

  defp use_kinds({:__aliases__, _, [:Ecto, type]}, _) when type in [:Type, :ParameterizedType],
    do: MapSet.new([:ecto_type])

  defp use_kinds({:__aliases__, _, [:Phoenix, type]}, _) when is_map_key(@phoenix_kinds, type),
    do: MapSet.new([@phoenix_kinds[type]])

  defp use_kinds({:__aliases__, _, _}, [kind | _]) when kind in [:controller],
    do: MapSet.new([:controller])

  defp use_kinds({:__aliases__, _, _}, [kind | _]) when is_map_key(@web_kinds, kind),
    do: MapSet.new([@web_kinds[kind]])

  defp use_kinds(_, _), do: MapSet.new()

  defp wire_indexes(kinds, fname, args) do
    key = {fname, length(args)}

    cond do
      wire_callback?(kinds, key) -> elem(@wire_callbacks[key], 1)
      MapSet.member?(kinds, :ecto_type) -> Map.get(@ecto_type_callbacks, key, [])
      MapSet.member?(kinds, :oban) and key == {:perform, 1} -> [0]
      MapSet.member?(kinds, :controller) and match?([_, _], args) and conn_param?(hd(args)) -> [1]
      true -> []
    end
  end

  defp wire_callback?(kinds, key) do
    case @wire_callbacks do
      %{^key => {kind, _}} -> MapSet.member?(kinds, kind)
      _ -> false
    end
  end

  defp conn_param?({:conn, _, ctx}) when is_atom(ctx), do: true
  defp conn_param?({:=, _, [_, {:conn, _, ctx}]}) when is_atom(ctx), do: true
  defp conn_param?({:=, _, [{:conn, _, ctx}, _]}) when is_atom(ctx), do: true
  defp conn_param?({:%, _, [{:__aliases__, _, [:Plug, :Conn]}, _]}), do: true
  defp conn_param?(_), do: false

  # Replaces the wire arguments by `_`, and string keys in reads from the variables they bound.
  defp neutralise_clause({kind, meta, [head, kw]}, indexes) do
    {{fname, cm, args}, guard} = split_guard(head)
    vars = wire_vars(args, indexes)
    masked_call = {fname, cm, mask_args(args, indexes)}
    new_kw = Enum.map(kw, fn {k, v} -> {k, strip_reads(v, vars)} end)
    {kind, meta, [attach_guard(masked_call, guard), new_kw]}
  end

  defp split_guard({:when, wm, [call, guard]}), do: {call, {wm, guard}}
  defp split_guard(call), do: {call, nil}

  defp attach_guard(call, {wm, guard}), do: {:when, wm, [call, guard]}
  defp attach_guard(call, nil), do: call

  defp wire_vars(args, indexes) do
    wire_args = Enum.map(indexes, &Enum.at(args, &1))

    param_vars =
      wire_args
      |> Enum.flat_map(&Ast.param_names/1)
      |> MapSet.new()

    bound_vars = pattern_vars(wire_args)
    MapSet.union(param_vars, bound_vars)
  end

  defp mask_args(args, indexes) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, i} -> if i in indexes, do: {:_, [], nil}, else: arg end)
  end

  # Every variable bound anywhere inside a wire pattern (`%{"a" => %{"b" => b}} = params`).
  defp pattern_vars(patterns) do
    patterns
    |> Enum.flat_map(fn pat ->
      Ast.walk(pat, [], fn
        {name, _, ctx}, acc when is_atom(name) and is_atom(ctx) and name != :_ -> [name | acc]
        _, acc -> acc
      end)
    end)
    |> MapSet.new()
  end

  defp strip_reads(body, vars), do: Macro.prewalk(body, &strip_read(&1, vars))

  defp strip_read({{:., _, _} = dot, m, [{name, _, ctx} = first | rest]}, vars)
       when is_atom(name) and is_atom(ctx),
       do: {dot, m, [first | bound_keys(rest, name, vars)]}

  defp strip_read({f, m, [{name, _, ctx} = first | rest]}, vars)
       when f in @path_funs and is_atom(name) and is_atom(ctx),
       do: {f, m, [first | bound_keys(rest, name, vars)]}

  defp strip_read(node, _), do: node

  defp bound_keys(rest, name, vars) do
    if MapSet.member?(vars, name), do: neutralise_keys(rest), else: rest
  end

  defp neutralise_keys(args), do: Enum.map(args, &neutralise_arg/1)

  defp neutralise_arg(key) when is_binary(key), do: :wire_key
  defp neutralise_arg(list) when is_list(list), do: Enum.map(list, &neutralise_item/1)
  defp neutralise_arg(other), do: other

  defp neutralise_item(key) when is_binary(key), do: :wire_key
  defp neutralise_item(other), do: other

  defp exempt_expression({name, m, args}) when name in @query_macros and is_list(args),
    do: {name, m, Enum.map(args, &neutralise_json_paths/1)}

  defp exempt_expression({{:., _, [{:__aliases__, _, [mod]}, f]} = dot, m, [{:%{}, _, _} | rest]})
       when mod in [:Jason, :Poison, :URI] and f in @encoders,
       do: {dot, m, [:encoded | rest]}

  defp exempt_expression({:%, m, [{:__aliases__, _, [:Oban, :Job]} = struct, {:%{}, mm, kvs}]}),
    do: {:%, m, [struct, {:%{}, mm, Enum.map(kvs, &neutralise_args/1)}]}

  defp exempt_expression(node), do: node

  # `conn.params["k"]` / `Map.get(conn.cookies, "k")` where the receiver is a known connection,
  # and `params:` / `cookies:` maps in `%Plug.Conn{}` patterns or matched against a connection.
  defp exempt_conn(
         {{:., _, [Access, :get]} = dot, m, [{{:., _, [recv, field]}, _, []} = base, k]},
         names
       )
       when field in @conn_fields and is_binary(k) do
    if conn_var?(recv, names), do: {dot, m, [base, :wire_key]}, else: {dot, m, [base, k]}
  end

  defp exempt_conn(
         {{:., _, [_, f]} = dot, m, [{{:., _, [recv, field]}, _, []} = base | rest]} = node,
         names
       )
       when f in @map_funs and field in @conn_fields do
    if conn_var?(recv, names), do: {dot, m, [base | neutralise_keys(rest)]}, else: node
  end

  defp exempt_conn(
         {:%, m, [{:__aliases__, _, [:Plug, :Conn]} = struct, {:%{}, mm, kvs}]},
         _
       ),
       do: {:%, m, [struct, {:%{}, mm, Enum.map(kvs, &empty_conn_field/1)}]}

  defp exempt_conn({:=, m, [left, right]} = node, names) do
    cond do
      conn_var?(right, names) -> {:=, m, [empty_conn_maps(left), right]}
      conn_var?(left, names) -> {:=, m, [left, empty_conn_maps(right)]}
      true -> node
    end
  end

  defp exempt_conn(node, _), do: node

  defp conn_var?({name, _, ctx}, names) when is_atom(name) and is_atom(ctx), do: name in names
  defp conn_var?(_, _), do: false

  defp empty_conn_maps(pattern) do
    Macro.prewalk(pattern, fn
      {:%{}, m, kvs} when is_list(kvs) -> {:%{}, m, Enum.map(kvs, &empty_conn_field/1)}
      node -> node
    end)
  end

  defp empty_conn_field({key, {:%{}, im, _}}) when key in @conn_fields, do: {key, {:%{}, im, []}}
  defp empty_conn_field(other), do: other

  # Extra connection variables of one clause: `%Plug.Conn{} = c` / `c = %Plug.Conn{}` in the head.
  defp bound_conn_names(args) do
    for arg <- args,
        {:=, _, [l, r]} <- [arg],
        {var, _, ctx} <- [plug_conn_binding(l, r)],
        is_atom(ctx),
        do: var
  end

  defp plug_conn_binding({:%, _, [{:__aliases__, _, [:Plug, :Conn]}, _]}, {_, _, _} = var),
    do: var

  defp plug_conn_binding({_, _, _} = var, {:%, _, [{:__aliases__, _, [:Plug, :Conn]}, _]}),
    do: var

  defp plug_conn_binding(_, _), do: nil

  defp exempt_bound_conn(stmt, []), do: stmt
  defp exempt_bound_conn(stmt, names), do: Macro.prewalk(stmt, &exempt_conn(&1, names))

  defp neutralise_args({:args, {:%{}, im, _}}), do: {:args, {:%{}, im, []}}
  defp neutralise_args(other), do: other

  # `schema.field["key"]` inside an Ecto query macro is a JSON path, not a map access.
  defp neutralise_json_paths(ast) do
    Macro.prewalk(ast, fn
      {{:., _, [Access, :get]} = dot, m, [{{:., _, [_, _]}, _, []} = base, k]}
      when is_binary(k) ->
        {dot, m, [base, :json_path]}

      node ->
        node
    end)
  end

  defp hit({{:., _, [Access, :get]}, m, [_, k]}, _) when is_binary(k),
    do: {m[:line], "x[\"#{k}\"]"}

  defp hit({{:., _, [mod, g]}, m, [_, k | _]}, aliases)
       when g in @map_funs and is_binary(k) do
    if Aliases.resolve(mod, aliases) in ["Map", "Access"], do: {m[:line], "Map.#{g}(x, \"#{k}\")"}
  end

  defp hit({{:., _, [mod, g]}, m, [_, keys | _]}, aliases)
       when g in @map_list_funs and is_list(keys) do
    with true <- Aliases.resolve(mod, aliases) == "Map",
         k when is_binary(k) <- Enum.find(keys, &is_binary/1) do
      {m[:line], "Map.#{g}(x, [\"#{k}\", ...])"}
    else
      _ -> nil
    end
  end

  defp hit({f, m, [_, path | _]}, _) when f in @path_funs and is_list(path) do
    case Enum.find(path, &is_binary/1) do
      nil -> nil
      k -> {m[:line], "#{f}(x, [..., \"#{k}\", ...])"}
    end
  end

  defp hit({:%{}, m, [_ | _] = kvs}, _) do
    case Enum.find(kvs, &match?({k, _} when is_binary(k), &1)) do
      {k, _} -> {m[:line], "%{\"#{k}\" => ...}"}
      nil -> nil
    end
  end

  defp hit(_, _), do: nil

  defp issue(issue_meta, line, what) do
    format_issue(issue_meta,
      message:
        "String-keyed map outside a codec (#{what}). Decode into a struct in a codec module " <>
          "(configure `codec_modules`/`codec_globs`) and use fields.",
      trigger: "\"",
      line_no: line
    )
  end
end
