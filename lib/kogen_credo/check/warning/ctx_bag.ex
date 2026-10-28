defmodule KogenCredo.Check.Warning.CtxBag do
  @moduledoc """
  Flags "context bags": one parameter threaded through many functions of a module
  that carries many unrelated fields (root, clock, runner, env, ...).

  Two triggers, one issue per parameter name and module:

    * **Named bag**: a parameter whose name is in `banned_names` (default `ctx`,
      `context`) appears in at least `min_named_clauses` function clauses.
    * **Structural bag**: a parameter name appears in at least `min_clauses`
      function clauses, is passed on to another call in at least
      `min_passed_ratio` of them, the file reads at least `min_fields` distinct
      fields from it (`x.f`, `x[:f]`, `Map.get(x, :f)`, `%{f: _} = x`), and at least
      `min_ambient` of them are `ambient_fields` (`root`, `env`, `now`, `runner`, ...)
      or are called as functions (`x.f.(...)`).

  A parameter matched as `%Struct{}` anywhere in the file is a typed record and is
  exempt from the structural trigger. Names in `allowed_names` are never reported.

  ## Limitations

  Purely syntactic. Parameters are grouped by name within one `defmodule` (inner
  modules are counted separately), and field reads through helper functions are not
  seen. A call that only reads from the parameter (`Map.get(ctx, :root)`, `get_in/2`)
  does not count as passing it on. Phoenix-style
  `context` arguments need `allowed_names`. The check is deliberately `:low`
  priority: treat it as a prompt to look, not as proof of a design flaw.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      banned_names: [:ctx, :context],
      allowed_names: [:conn, :socket],
      min_named_clauses: 3,
      min_clauses: 4,
      min_passed_ratio: 0.5,
      min_fields: 8,
      min_ambient: 2,
      ambient_fields:
        ~w(root cwd dir env tmp_dir tmp now clock time runner proc cmd git io shell config opts options
           log log_path logger harness provider http client repo timeout deadline registry store cache
           runtime deps services)a,
      included_paths: ["lib/"],
      excluded_paths: []
    ],
    explanations: [
      check: """
      Pass the values a function needs (`root`, `now`, a `%Project{}`), not a bag of
      services. A bag hides what a function depends on and lets every function reach
      every capability. Effects that tests replace belong behind a behaviour chosen at
      compile time.

      Triggers: a parameter named like a bag (`banned_names`) used in several clauses,
      or a parameter that is threaded through most clauses while the file reads many
      distinct (and service-like) fields from it. Struct-typed parameters are exempt.
      """,
      params: [
        banned_names: "Parameter names reported when used in `min_named_clauses` clauses.",
        allowed_names: "Parameter names never reported.",
        min_named_clauses: "Clauses a banned name must appear in.",
        min_clauses: "Clauses a parameter must appear in for the structural trigger.",
        min_passed_ratio: "Share of those clauses that pass the parameter to another call.",
        min_fields: "Distinct fields/keys read from the parameter.",
        min_ambient: "How many read fields must be ambient/service-like or called as functions.",
        ambient_fields: "Field names that look like injected services or ambient state.",
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped."
      ]
    ]

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Settings

  @access_mods [:Map, :Keyword]
  @access_funs [
    :get,
    :fetch,
    :fetch!,
    :get_lazy,
    :has_key?,
    :pop,
    :update,
    :update!,
    :put,
    :put_new
  ]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.ast()
      |> module_bodies()
      |> Enum.flat_map(fn body ->
        body
        |> collect()
        |> evaluate(params, issue_meta)
      end)
      |> Enum.sort_by(&{&1.line_no, &1.trigger})
    else
      []
    end
  end

  # One body per `defmodule` with inner modules removed; a module-less file is one group.
  defp module_bodies(ast) do
    case Ast.modules(ast) do
      [] -> [ast]
      modules -> for {_, _, body} <- modules, do: Ast.strip_modules(body)
    end
  end

  defp collect(ast), do: Ast.walk(ast, [], &collect_clause/2)

  defp collect_clause(node, acc) do
    case Ast.def_clause(node) do
      {:ok, {_, fname, args, _, body, meta}} -> clause_infos(fname, args, body, meta) ++ acc
      :error -> acc
    end
  end

  defp clause_infos(fname, args, body, meta) do
    names = Enum.flat_map(args, &Ast.param_names/1)
    head_fields = Enum.flat_map(args, &head_fields/1)
    typed = Enum.flat_map(args, &typed_names/1)

    Enum.map(names, fn n ->
      %{
        name: n,
        fun: fname,
        line: meta[:line],
        passed?: passed?(body, n),
        typed?: n in typed,
        called: called(body, n),
        fields: MapSet.union(reads(body, n), MapSet.new(for {^n, f} <- head_fields, do: f))
      }
    end)
  end

  defp evaluate(clauses, params, issue_meta) do
    cfg = settings(params)

    clauses
    |> Enum.group_by(& &1.name)
    |> Enum.reject(fn {n, _} -> n in cfg.allowed end)
    |> Enum.flat_map(&group_issues(&1, cfg, issue_meta))
  end

  defp settings(params) do
    banned =
      params
      |> Params.get(:banned_names, __MODULE__)
      |> Settings.atoms!(:banned_names)

    allowed =
      params
      |> Params.get(:allowed_names, __MODULE__)
      |> Settings.atoms!(:allowed_names)

    min_named =
      params
      |> Params.get(:min_named_clauses, __MODULE__)
      |> Settings.integer!(:min_named_clauses, 1)

    min_clauses =
      params
      |> Params.get(:min_clauses, __MODULE__)
      |> Settings.integer!(:min_clauses, 1)

    ratio = ratio!(params)

    min_fields =
      params
      |> Params.get(:min_fields, __MODULE__)
      |> Settings.integer!(:min_fields)

    min_ambient =
      params
      |> Params.get(:min_ambient, __MODULE__)
      |> Settings.integer!(:min_ambient)

    ambient =
      params
      |> Params.get(:ambient_fields, __MODULE__)
      |> Settings.atoms!(:ambient_fields)

    %{
      banned: banned,
      allowed: allowed,
      min_named: min_named,
      min_clauses: min_clauses,
      ratio: ratio,
      min_fields: min_fields,
      min_ambient: min_ambient,
      ambient: ambient
    }
  end

  defp ratio!(params) do
    ratio = Params.get(params, :min_passed_ratio, __MODULE__)

    unless is_number(ratio) and ratio >= 0 and ratio <= 1,
      do: Settings.raise_bad(:min_passed_ratio, ratio, "a number between 0 and 1")

    ratio
  end

  defp group_issues({n, clauses}, cfg, issue_meta) do
    sorted = Enum.sort_by(clauses, & &1.line)
    fields = union_all(sorted, & &1.fields)
    passed = Enum.count(sorted, & &1.passed?)

    ambient_reads = ambient_reads(sorted, fields, cfg)
    structural? = structural?(sorted, passed, fields, ambient_reads, cfg)

    cond do
      n in cfg.banned and length(sorted) >= cfg.min_named ->
        [issue(issue_meta, n, sorted, passed, fields, "`#{n}` is a bag-style parameter name")]

      structural? ->
        [issue(issue_meta, n, sorted, passed, fields, "`#{n}` is threaded like a context bag")]

      true ->
        []
    end
  end

  defp ambient_reads(clauses, fields, cfg) do
    fields
    |> Enum.filter(&(&1 in cfg.ambient))
    |> MapSet.new()
    |> MapSet.union(union_all(clauses, & &1.called))
  end

  defp union_all(clauses, getter) do
    clauses
    |> Enum.map(getter)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp structural?(clauses, passed, fields, ambient_reads, cfg) do
    total = length(clauses)

    not Enum.any?(clauses, & &1.typed?) and total >= cfg.min_clauses and
      passed / total >= cfg.ratio and
      MapSet.size(fields) >= cfg.min_fields and MapSet.size(ambient_reads) >= cfg.min_ambient
  end

  defp issue(issue_meta, name, clauses, passed, fields, why) do
    sample =
      fields
      |> Enum.take(6)
      |> Enum.map_join(", ", &inspect/1)

    format_issue(issue_meta,
      message:
        "#{why}: #{length(clauses)} clauses take it, #{passed} pass it on, " <>
          "#{MapSet.size(fields)} fields read (#{sample}). " <>
          "Pass the specific values each function needs and put effects behind a behaviour.",
      trigger: Atom.to_string(name),
      line_no: hd(clauses).line
    )
  end

  # Read-only accessors do not hand the bag on to anybody.
  @read_mods [:Map, :Keyword, :Access]
  @read_funs [:get, :fetch, :fetch!, :get_lazy, :has_key?, :take, :keys, :values, :to_list]
  @read_kernel [:get_in, :is_map_key, :map_size, :is_map, :is_nil, :is_struct, :is_list]

  defp passed?(body, n), do: Ast.walk(body, false, &passed_step(&1, &2, n))

  defp passed_step(_, true, _), do: true
  defp passed_step({:|>, _, [{n, _, c}, _]}, _, n) when is_atom(c), do: true

  defp passed_step({{:., _, [{:__aliases__, _, [mod]}, f]}, _, args}, _, _)
       when mod in @read_mods and f in @read_funs and is_list(args),
       do: false

  defp passed_step({{:., _, [Access, f]}, _, args}, _, _)
       when f in @read_funs and is_list(args),
       do: false

  defp passed_step({{:., _, [_, f]}, _, args}, _, n)
       when is_atom(f) and is_list(args) and args != [],
       do: has_var?(args, n)

  defp passed_step({f, _, args}, _, _) when f in @read_kernel and is_list(args), do: false

  defp passed_step({f, _, args}, _, n) when is_atom(f) and is_list(args),
    do: not operator?(f) and has_var?(args, n)

  defp passed_step(_, acc, _), do: acc

  defp has_var?(args, n), do: Enum.any?(args, &match?({^n, _, c} when is_atom(c), &1))

  @operators [
    :.,
    :|>,
    :=,
    :==,
    :!=,
    :===,
    :!==,
    :&&,
    :||,
    :and,
    :or,
    :not,
    :!,
    :<>,
    :++,
    :--,
    :+,
    :-,
    :*,
    :/,
    :in,
    :{},
    :%{},
    :%,
    :<<>>,
    :__block__,
    :->,
    :when,
    :|,
    :"::",
    :^,
    :@,
    :case,
    :cond,
    :if,
    :unless,
    :with,
    :for,
    :try,
    :receive,
    :>,
    :<,
    :>=,
    :<=,
    :is_nil,
    :is_map,
    :is_list,
    :is_binary,
    :is_atom,
    :match?
  ]

  defp operator?(f), do: f in @operators

  defp reads(body, n), do: Ast.walk(body, MapSet.new(), &read_step(&1, &2, n))

  defp read_step({{:., _, [{n, _, c}, f]}, m, []}, s, n) when is_atom(c) and is_atom(f),
    do: if(m[:no_parens], do: MapSet.put(s, f), else: s)

  defp read_step({{:., _, [Access, :get]}, _, [{n, _, c}, k]}, s, n)
       when is_atom(c) and is_atom(k),
       do: MapSet.put(s, k)

  defp read_step({{:., _, [{:__aliases__, _, [mod]}, g]}, _, [{n, _, c}, k | _]}, s, n)
       when mod in @access_mods and g in @access_funs and is_atom(c) and is_atom(k),
       do: MapSet.put(s, k)

  defp read_step({:=, _, [{:%{}, _, kvs}, {n, _, c}]}, s, n) when is_atom(c) and is_list(kvs),
    do: Enum.reduce(kvs, s, &put_key/2)

  defp read_step(_, s, _), do: s

  defp put_key({k, _}, s) when is_atom(k), do: MapSet.put(s, k)
  defp put_key(_, s), do: s

  defp typed_names({:=, _, [l, r]}) do
    if struct_pattern?(l) or struct_pattern?(r),
      do: Ast.param_names(l) ++ Ast.param_names(r),
      else: []
  end

  defp typed_names(_), do: []

  defp struct_pattern?({:%, _, [_, _]}), do: true
  defp struct_pattern?(_), do: false

  defp called(body, n), do: Ast.walk(body, MapSet.new(), &called_step(&1, &2, n))

  defp called_step({{:., _, [{{:., _, [{n, _, c}, f]}, _, []}]}, _, _}, s, n)
       when is_atom(c) and is_atom(f),
       do: MapSet.put(s, f)

  defp called_step(_, s, _), do: s

  defp head_fields({:=, _, [l, r]}) do
    names = Ast.param_names(l) ++ Ast.param_names(r)
    keys = map_keys(l) ++ map_keys(r)
    for n <- names, k <- keys, do: {n, k}
  end

  defp head_fields(_), do: []

  defp map_keys({:%{}, _, kvs}) when is_list(kvs), do: for({k, _} when is_atom(k) <- kvs, do: k)

  defp map_keys({:%, _, [_, {:%{}, _, kvs}]}) when is_list(kvs),
    do: for({k, _} when is_atom(k) <- kvs, do: k)

  defp map_keys(_), do: []
end
