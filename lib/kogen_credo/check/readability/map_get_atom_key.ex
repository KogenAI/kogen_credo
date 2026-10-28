defmodule KogenCredo.Check.Readability.MapGetAtomKey do
  @moduledoc """
  Flags optional-key lookups with a literal atom key on internal maps:
  `Map.get(x, :key)`, `Map.get(x, :key, default)` and `x[:key]`.

  An atom key means the shape is ours: make it a struct with defaults, or match the
  required key (`%{key: value} = x`). `Map.get` turns a missing key into a silent
  `nil` or default.

  Receivers whose name suggests an options keyword list or a framework container
  (`opts`, `options`, `kw`, `keyword`, `overrides`, `assigns`, `attrs`, `params`,
  `config`, `metadata`, `errors` (a changeset's keyword list), `private` (`conn.private`);
  see `ignored_receivers`) are skipped, as are receivers that are not a variable or field
  access (calls, literals), and variables bound in the same function from
  `Application.fetch_env!/get_env/fetch_env/compile_env/get_all_env` (application
  configuration is a keyword list by convention). `Map.get/3` can be silenced
  with `flag_with_default: false`.

  ## Limitations

  The check has no type information: it cannot tell a struct from a bare map, nor an
  external map (decoded JSON with atom keys) from an internal one. Treat hits as
  prompts to introduce a struct, not as bugs.
  """

  use Credo.Check,
    category: :readability,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/"],
      excluded_paths: [],
      flag_with_default: true,
      ignored_receivers: [
        :opts,
        :options,
        :kw,
        :keyword,
        :overrides,
        :assigns,
        :attrs,
        :params,
        :config,
        :metadata,
        :errors,
        :private
      ]
    ],
    explanations: [
      check: """
      Define the shape once (`defstruct` with defaults) and use `x.key`, or pattern-match the required key.
      `Map.get(x, :key)` on a map you control hides missing keys and typos.
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped.",
        flag_with_default: "Also report `Map.get(x, :key, default)`.",
        ignored_receivers: "Variable or field names that are never reported as receivers."
      ]
    ]

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)
      with_default? = Params.get(params, :flag_with_default, __MODULE__)

      ignored =
        params
        |> Params.get(:ignored_receivers, __MODULE__)
        |> Settings.atoms!(:ignored_receivers)

      source_file
      |> SourceFile.ast()
      |> Ast.expand_pipes()
      |> neutralise_config_receivers()
      |> Scope.walk([], &collect_issue(&1, &2, &3, with_default?, ignored, issue_meta))
      |> Enum.reverse()
    else
      []
    end
  end

  defp collect_issue(node, env, issues, with_default?, ignored, issue_meta) do
    case hit(node, with_default?, ignored, env.aliases) do
      {line, how} -> [issue(issue_meta, line, how) | issues]
      nil -> issues
    end
  end

  @env_funs [:fetch_env!, :get_env, :fetch_env, :compile_env, :compile_env!, :get_all_env]

  # Variables bound from `Application.*env` in a function are configuration keyword lists:
  # their atom-key lookups are replaced by a non-atom key before the walk.
  defp neutralise_config_receivers(ast) do
    Macro.prewalk(ast, &neutralise_clause/1)
  end

  defp neutralise_clause(node) do
    with {:ok, {_, _, _, _, body, _}} when body != nil <- Ast.def_clause(node),
         [_ | _] = vars <- config_vars(body) do
      Macro.prewalk(node, &neutralise(&1, vars))
    else
      _ -> node
    end
  end

  defp config_vars(body) do
    Ast.walk(body, [], fn
      {:=, _, [{name, _, ctx}, rhs]}, acc when is_atom(name) and is_atom(ctx) ->
        if application_env?(rhs), do: [name | acc], else: acc

      _, acc ->
        acc
    end)
  end

  defp application_env?({{:., _, [{:__aliases__, _, [:Application]}, f]}, _, _}),
    do: f in @env_funs

  defp application_env?(_), do: false

  defp neutralise({{:., _, [Access, :get]} = dot, m, [{name, _, ctx} = recv, key]} = node, vars)
       when is_atom(name) and is_atom(ctx) and is_atom(key) do
    if name in vars, do: {dot, m, [recv, "config"]}, else: node
  end

  defp neutralise(
         {{:., _, [_, :get]} = dot, m, [{name, _, ctx} = recv, key | rest]} = node,
         vars
       )
       when is_atom(name) and is_atom(ctx) and is_atom(key) do
    if name in vars, do: {dot, m, [recv, "config" | rest]}, else: node
  end

  defp neutralise(node, _), do: node

  defp hit({{:., _, [Access, :get]}, meta, [recv, key]}, _, ignored, _)
       when is_atom(key) and not is_nil(key) and not is_boolean(key) do
    if receiver?(recv, ignored), do: {meta[:line], "x[#{inspect(key)}]"}
  end

  defp hit(
         {{:., _, [mod, :get]}, meta, [recv, key | rest]},
         with_default?,
         ignored,
         aliases
       )
       when is_atom(key) and not is_nil(key) and not is_boolean(key) do
    cond do
      Aliases.resolve(mod, aliases) != "Map" -> nil
      not receiver?(recv, ignored) -> nil
      rest == [] -> {meta[:line], "Map.get(x, #{inspect(key)})"}
      with_default? -> {meta[:line], "Map.get(x, #{inspect(key)}, default)"}
      true -> nil
    end
  end

  defp hit(_, _, _, _), do: nil

  defp receiver?({name, _, ctx}, ignored) when is_atom(name) and is_atom(ctx),
    do: name not in ignored and not private?(name)

  defp receiver?({{:., _, [_, field]}, _, []}, ignored) when is_atom(field),
    do: field not in ignored

  defp receiver?(_, _), do: false

  defp private?(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("__")
  end

  defp issue(issue_meta, line, how) do
    format_issue(issue_meta,
      message:
        "Optional atom-key lookup `#{how}` on an internal map: use a struct field (with a default) or match the key.",
      trigger: "get",
      line_no: line
    )
  end
end
