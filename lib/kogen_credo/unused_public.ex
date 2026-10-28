defmodule KogenCredo.UnusedPublic do
  @moduledoc """
  Advisory finder for public functions that nothing else in the project calls.

  It answers "which `def`s have no caller?" from the **expanded code in compiled
  BEAM debug info**, not from source text, so aliases, imports and `use`-injected
  code are already resolved. The pure core works on `{module, beam_binary}` pairs;
  `Mix.Tasks.Kogen.UnusedPublic` feeds it the project's compiled modules.

  ## Findings

    * `:no_callers`: nothing in the analysed modules calls, captures or
      references the function.
    * `:only_local`: only other functions of the same module call it, so it may
      belong in a `defp`.

  ## What is excluded

    * behaviour callbacks: functions marked `@impl`, and any function that is a
      callback of a declared `@behaviour` (loaded through `behaviour_info/1`);
    * `__name__` functions, `module_info`, `child_spec/1`, `main/1`;
    * macros (`defmacro`): a macro call is expanded away, so it leaves no call to find;
    * modules matching `:entrypoint_modules` (default: controllers, routers,
      channels, sockets, `Mix.Tasks.*`) and any `Module.fun/arity` listed in
      `:entrypoint_functions`;
    * modules matching `:ignore_modules`.

  Functions with default arguments are treated as one group: the generated
  lower-arity heads are not reported and calls between them do not count.

  ## What this does NOT prove

  This is a heuristic over the modules you give it, not whole-program proof.
  A function can still be live when:

    * it is called by name at runtime (`apply/3` with computed values,
      `String.to_existing_atom`, Oban/telemetry/config MFAs stored in a database
      or non-literal data); literal `apply(Mod, :fun, [..])` calls, `{Mod, :fun, [..]}`
      tuples and `&Mod.fun/n` captures **are** counted;
    * it is part of a library's public API for other projects (do not run this on
      a library, or list its public modules in `:ignore_modules`);
    * it is called only from tests, other umbrella apps you did not include,
      templates compiled elsewhere, or code in `priv/`;
    * a framework dispatches to it (LiveView events, controller actions outside
      the default patterns): add the module to `:entrypoint_modules`.

  Conversely a function can look used because a same-named call exists in a dead
  function; the analysis is one level deep and does not compute reachability from
  entry points.
  """

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Settings

  @type mfa_key :: {module(), atom(), arity()}
  @type finding :: %{
          module: module(),
          name: atom(),
          arity: arity(),
          line: pos_integer() | nil,
          file: String.t() | nil,
          kind: :no_callers | :only_local
        }
  @type module_info :: %{
          module: module(),
          file: String.t() | nil,
          behaviours: [module()],
          defs: [
            %{
              name: atom(),
              arity: arity(),
              line: pos_integer() | nil,
              impl: boolean(),
              defaults: non_neg_integer()
            }
          ],
          calls: [{caller :: {atom(), arity}, callee :: mfa_key() | {:dynamic, mfa_key()}}]
        }

  @default_entrypoint_modules [
    ~r/Controller$/,
    ~r/Router$/,
    ~r/Channel$/,
    ~r/Socket$/,
    ~r/^Mix\.Tasks\./
  ]
  @always_excluded [:module_info, :child_spec, :main, :behaviour_info]

  @doc """
  Reads module infos from `{module, beam_binary}` pairs.

  Returns `{infos, skipped}` where `skipped` lists `{module, reason}` for beams
  without debug info (compiled with `debug_info: false`) or unreadable chunks.
  Those modules are neither analysed nor counted as callers, which can create
  false findings; callers should surface `skipped` to the user.
  """
  @spec collect([{module(), binary() | charlist()}]) :: {[module_info()], [{module(), term()}]}
  def collect(beams) do
    {infos, skipped} = Enum.reduce(beams, {[], []}, &read_beam/2)
    {Enum.reverse(infos), Enum.reverse(skipped)}
  end

  defp read_beam({module, beam}, {infos, skipped}) do
    case read(module, beam) do
      {:ok, info} -> {[info | infos], skipped}
      {:error, reason} -> {infos, [{module, reason} | skipped]}
    end
  end

  defp read(module, beam) do
    with {:ok, contents} <- beam_contents(beam),
         {:ok, {^module, chunks}} <- :beam_lib.chunks(contents, [:debug_info, :attributes]),
         {:debug_info_v1, backend, data} when data != :none <- chunks[:debug_info],
         {:ok, %{definitions: definitions} = info} <-
           backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, module_info(module, info, chunks[:attributes] || [], definitions)}
    else
      failure -> {:error, read_failure(failure, beam)}
    end
  end

  defp beam_contents(contents) when is_binary(contents), do: {:ok, contents}

  defp beam_contents(path) when is_list(path) do
    case :file.read_file(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:file_error, path, reason}}
    end
  end

  defp read_failure({:error, :beam_lib, {:not_a_beam_file, _}}, path) when is_list(path),
    do: {:not_a_beam_file, path}

  defp read_failure(failure, _), do: read_failure(failure)

  defp read_failure({:debug_info_v1, _, :none}), do: :no_debug_info
  defp read_failure({:error, :beam_lib, {:missing_chunk, _, _}}), do: :no_debug_info
  defp read_failure({:error, :missing}), do: :no_debug_info
  defp read_failure({:error, :beam_lib, reason}), do: reason
  defp read_failure({:error, reason}), do: reason
  defp read_failure(other), do: {:unexpected, other}

  defp module_info(module, info, attrs, definitions) do
    impls = for {fa, _, _, _, _, _, impl} <- Map.get(info, :impls, []), impl != false, do: fa

    %{
      module: module,
      file: info[:file] && to_string(info[:file]),
      behaviours:
        attrs
        |> Keyword.get_values(:behaviour)
        |> List.flatten(),
      defs:
        for(
          {{name, arity}, :def, meta, _} <- definitions,
          do: def_info(name, arity, meta, impls)
        ),
      calls: Enum.flat_map(definitions, &definition_calls(module, &1))
    }
  end

  defp def_info(name, arity, meta, impls) do
    %{
      name: name,
      arity: arity,
      line: Keyword.get(meta, :line),
      impl: {name, arity} in impls,
      defaults: Keyword.get(meta, :defaults, 0)
    }
  end

  defp definition_calls(module, {{name, arity}, _, _, clauses}) do
    caller = {name, arity}

    clauses
    |> Enum.flat_map(fn {_, args, guards, body} ->
      references(module, [args, guards, body])
    end)
    |> Enum.map(&{caller, &1})
  end

  # Every function the expanded code references, as {module, name, arity}.
  defp references(module, ast) do
    {_, refs} = Macro.prewalk(ast, [], &reference(&1, &2, module))
    refs
  end

  # &Mod.fun/n  (remote capture): arity is the capture's, not the inner call's.
  defp reference({:&, _, [{:/, _, [{{:., _, [mod, fun]}, _, []}, arity]}]}, acc, _)
       when is_atom(mod) and is_atom(fun) and is_integer(arity),
       do: {:ok, [{mod, fun, arity} | acc]}

  # &fun/n  (local capture)
  defp reference({:&, _, [{:/, _, [{fun, _, ctx}, arity]}]}, acc, module)
       when is_atom(fun) and is_atom(ctx) and is_integer(arity),
       do: {:ok, [{module, fun, arity} | acc]}

  # {Mod, :fun, [args]} literal MFA tuples (handlers, config, `use GenServer`'s child_spec).
  # They dispatch dynamically, so they count as external even when Mod is the current module.
  defp reference({:{}, _, [mod, fun, args]} = node, acc, _)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: {node, [{:dynamic, {mod, fun, length(args)}} | acc]}

  defp reference({{:., _, [mod, fun]}, _, args} = node, acc, _)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: {node, mfa_args(args, [{mod, fun, length(args)} | acc])}

  defp reference({fun, _, args} = node, acc, module) when is_atom(fun) and is_list(args),
    do: {node, mfa_args(args, [{module, fun, length(args)} | acc])}

  defp reference(node, acc, _), do: {node, acc}

  # apply(Mod, :fun, [..]) and friends: three consecutive literal arguments.
  defp mfa_args([mod, fun, args | rest], acc)
       when is_atom(mod) and is_atom(fun) and is_list(args) and mod not in [nil, true, false] do
    mfa_args([fun, args | rest], [{:dynamic, {mod, fun, length(args)}} | acc])
  end

  defp mfa_args([_ | rest], acc), do: mfa_args(rest, acc)
  defp mfa_args([], acc), do: acc

  @doc """
  Finds public functions without callers.

  Options:

    * `:entrypoint_modules` - list of `Regex` or module-name strings (exact
      match on `inspect(module)`); default controllers, routers, channels,
      sockets and `Mix.Tasks.*`
    * `:entrypoint_functions` - list of `"Mod.fun/arity"` strings or `{mod, fun, arity}`
    * `:ignore_modules` - same shape as `:entrypoint_modules`, default `[]`

  Returns findings sorted by file and line.
  """
  @spec analyze([module_info()], keyword()) :: [finding()]
  def analyze(infos, opts \\ []) do
    skipped_modules =
      Keyword.get(opts, :entrypoint_modules, @default_entrypoint_modules) ++
        Keyword.get(opts, :ignore_modules, [])

    external = external_callers(infos)
    entry_functions = entry_functions(opts)

    infos
    |> Enum.reject(&module_matches?(&1.module, skipped_modules))
    |> Enum.flat_map(&module_findings(&1, external, entry_functions))
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.name})
  end

  defp entry_functions(opts) do
    opts
    |> Keyword.get(:entrypoint_functions, [])
    |> Enum.map(&parse_mfa/1)
  end

  defp module_findings(info, calls, entry_functions) do
    callbacks = callbacks(info)
    groups = default_groups(info.defs)

    for %{name: name, arity: arity} = definition <- info.defs,
        public_candidate?(info, definition, callbacks, entry_functions),
        group = group_of(groups, definition),
        highest?(group, definition),
        kind = usage(info.module, name, group, calls),
        kind != :used do
      %{
        module: info.module,
        name: name,
        arity: arity,
        line: definition.line,
        file: info.file,
        kind: kind
      }
    end
  end

  defp public_candidate?(
         info,
         %{name: name, arity: arity, impl: impl},
         callbacks,
         entry_functions
       ) do
    not impl and not MapSet.member?(callbacks, {name, arity}) and
      name not in @always_excluded and
      not Ast.prefixed?(name, "__") and
      {Ast.atom_name(info.module), Atom.to_string(name), arity} not in entry_functions
  end

  # Groups a function with its default-argument heads: `f(a, b \\ 1)` defines f/1 and f/2.
  defp default_groups(defs) do
    for %{name: name, arity: arity, defaults: defaults} <- defs, defaults > 0 do
      {name, (arity - defaults)..arity}
    end
  end

  defp group_of(groups, %{name: name, arity: arity}) do
    Enum.find_value(groups, [arity], fn
      {^name, range} -> if arity in range, do: Enum.to_list(range)
      _ -> nil
    end)
  end

  defp highest?(group, %{arity: arity}), do: arity == Enum.max(group)

  # callee => set of callers: {:external, module} or {:local, {name, arity}}
  defp external_callers(infos) do
    for info <- infos, {caller, callee} <- info.calls, reduce: %{} do
      acc ->
        {mfa, origin} = origin(info.module, caller, callee)
        Map.update(acc, mfa, MapSet.new([origin]), &MapSet.put(&1, origin))
    end
  end

  # `apply/3` and MFA tuples are dynamic dispatch: public even when aimed at the current module.
  defp origin(module, _, {:dynamic, mfa}), do: {mfa, {:external, module}}
  defp origin(module, caller, {module, _, _} = mfa), do: {mfa, {:local, caller}}
  defp origin(module, _, mfa), do: {mfa, {:external, module}}

  defp usage(module, name, group, calls) do
    origins =
      for arity <- group,
          origin <- Map.get(calls, {module, name, arity}, []),
          not own_group?(origin, name, group),
          do: origin

    cond do
      Enum.any?(origins, &match?({:external, _}, &1)) -> :used
      origins != [] -> :only_local
      true -> :no_callers
    end
  end

  defp own_group?({:local, {name, arity}}, name, group), do: arity in group
  defp own_group?(_, _, _), do: false

  defp callbacks(info) do
    info.behaviours
    |> Enum.flat_map(fn behaviour ->
      if Code.ensure_loaded?(behaviour) and function_exported?(behaviour, :behaviour_info, 1) do
        behaviour.behaviour_info(:callbacks)
      else
        []
      end
    end)
    |> MapSet.new()
  end

  defp module_matches?(module, patterns) do
    name = inspect(module)

    Enum.any?(patterns, fn
      %Regex{} = regex -> Regex.match?(regex, name)
      string when is_binary(string) -> string == name
    end)
  end

  # Entry functions are kept as `{module name, function name, arity}` and compared by name with
  # the functions of the analysed beams: a configured function no beam defines needs no atom and
  # matches nothing.
  defp parse_mfa({m, f, a}), do: {Settings.module_name(m), to_string(f), a}

  defp parse_mfa(string) when is_binary(string) do
    with [mod, rest] <- String.split(string, ~r/\.(?=[^.]+\/\d+$)/, parts: 2),
         [fun, arity] <- String.split(rest, "/"),
         {arity, ""} <- Integer.parse(arity) do
      {Settings.module_name(mod), fun, arity}
    else
      _ -> raise ArgumentError, "expected \"Mod.fun/arity\", got: #{inspect(string)}"
    end
  end

  @doc "Renders findings as lines `file:line Mod.fun/arity (kind)`."
  @spec format([finding()]) :: [String.t()]
  def format(findings) do
    for f <- findings do
      location = "#{f.file || "?"}:#{f.line || 0}"
      "#{location} #{inspect(f.module)}.#{f.name}/#{f.arity} #{describe(f.kind)}"
    end
  end

  defp describe(:no_callers), do: "has no callers in the analysed modules"
  defp describe(:only_local), do: "is only called inside its own module (candidate for defp)"
end
