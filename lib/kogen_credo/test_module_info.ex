defmodule KogenCredo.TestModuleInfo do
  @moduledoc """
  Reads ExUnit test modules out of an AST, for the async-safety checks.

  For every `defmodule` that directly `use`s `ExUnit.Case` (or a configured
  case template) it reports:

    * `:mode`: `:async` or `:serial`, from the literal `async:` option;
      `:unknown` when the option is not a literal boolean.
    * `:group`: the literal `group:` option, `:dynamic` when it is not a
      literal atom, `nil` when absent.
    * `:serial_tags`: atoms from `@moduletag serial: atom`; `non_literal_reason/0` stands
      for `serial: true`, `serial: nil` or any value that is not a literal atom.
    * `:accesses`: global-state touches found anywhere in the module body
      (nested `defmodule`s are scanned separately).
    * `:teardowns`: calls that destroy or stop named, app-wide state.

  ## Case templates

  Modules that `use` anything other than `ExUnit.Case` are invisible unless
  the template is declared. Declare templates as a map or keyword list from
  module name to behaviour:

      %{"MyApp.DataCase" => :inherit, "MyApp.AsyncCase" => :async, "MyApp.SerialCase" => :serial}

    * `:inherit`: the template forwards its options to `use ExUnit.Case`, so the
      `async:` and `group:` given at the `use` site apply (default serial).
    * `:async` / `:serial`: the template forces that mode regardless of options.

  An undeclared template yields no module at all (the checks stay quiet) rather
  than a guess. The declaration is not verified against the template source.

  ## Limits

  Everything is syntactic. Only literal resource names are tracked (atoms,
  strings and module attributes holding them). Calls in helper modules, macros
  or `quote` blocks are not followed. Scope is lexical: a nested `defmodule` is a module of its
  own (a nested test module has its own mode and group; a nested helper module's calls are not
  charged to the enclosing test module). Pipes are expanded before classification, so
  `"p" |> File.write!(data)` is a write to `"p"`.
  """

  alias KogenCredo.QuerySupport
  alias KogenCredo.SafetySupport

  # Stands in `serial_tags` for `serial: true`, `serial: nil` or a non-literal expression.
  @non_literal_reason :"$non_literal_reason"

  @doc "Marker found in `serial_tags` when the `serial:` value is not a literal reason atom."
  @spec non_literal_reason() :: atom()
  def non_literal_reason, do: @non_literal_reason

  defstruct [
    :name,
    :line,
    :mode,
    :group,
    :template,
    serial_tags: [],
    accesses: [],
    teardowns: [],
    created_tables: []
  ]

  @type access :: %{
          kind: atom(),
          key: String.t() | atom(),
          access: :read | :write,
          line: pos_integer(),
          call: String.t()
        }
  @type t :: %__MODULE__{}

  @doc "Normalises a template declaration (map or keyword/tuple list) to a string-keyed map."
  @spec normalize_templates(map() | list()) :: %{String.t() => :async | :serial | :inherit}
  def normalize_templates(config) do
    for {name, kind} <- Enum.to_list(config || []),
        kind in [:async, :serial, :inherit],
        into: %{},
        do: {module_name(name), kind}
  end

  defp module_name(name) do
    name
    |> to_string()
    |> String.trim_leading("Elixir.")
  end

  @doc """
  Parses test modules from `ast`. Options: `:case_templates` (see moduledoc).
  """
  @spec parse(Macro.t(), keyword()) :: [t()]
  def parse(ast, opts \\ []) do
    templates =
      opts
      |> Keyword.get(:case_templates, %{})
      |> normalize_templates()

    aliases = SafetySupport.aliases(ast)

    ast
    |> modules()
    |> Enum.flat_map(&parse_module(&1, aliases, templates))
  end

  defp parse_module({name, line, body}, aliases, templates) do
    stmts = statements(body)

    case detect_mode(stmts, aliases, templates) do
      nil -> []
      detected -> [build_info({name, line}, detected, stmts, body, aliases)]
    end
  end

  defp build_info({name, line}, {mode, group, template}, stmts, body, aliases) do
    attrs = attrs(stmts)

    scan =
      body
      |> strip_out_of_scope()
      |> QuerySupport.expand_pipes()

    {accesses, teardowns, created} = scan_calls(scan, aliases, attrs)

    %__MODULE__{
      name: name,
      line: line,
      mode: mode,
      group: group,
      template: template,
      serial_tags: serial_tags(stmts),
      accesses: accesses,
      teardowns: teardowns,
      created_tables: created
    }
  end

  @doc "Parses source text; invalid source yields `[]`."
  @spec parse_source(String.t(), keyword()) :: [t()]
  def parse_source(source, opts \\ []) do
    case Code.string_to_quoted(source, columns: false, emit_warnings: false) do
      {:ok, ast} -> parse(ast, opts)
      {:error, _} -> []
    end
  end

  # -- module discovery ------------------------------------------------------

  defp modules(ast), do: collect_modules(ast, nil)

  defp collect_modules({:defmodule, meta, [{:__aliases__, _, parts}, [do: body]]}, prefix)
       when is_list(parts) do
    name = Enum.map_join(parts, ".", &to_string/1)
    full = if prefix, do: prefix <> "." <> name, else: name
    [{full, meta[:line] || 1, body} | collect_modules(body, full)]
  end

  defp collect_modules({:__block__, _, stmts}, prefix) when is_list(stmts),
    do: Enum.flat_map(stmts, &collect_modules(&1, prefix))

  defp collect_modules(_, _), do: []

  # Calls in a nested module belong to that module (scanned on its own), and `quote` bodies are
  # code the module generates, not code it runs.
  defp strip_out_of_scope(body) do
    Macro.prewalk(body, fn
      {:defmodule, _, _} -> :ok
      {:quote, _, _} -> :ok
      node -> node
    end)
  end

  defp statements({:__block__, _, stmts}), do: stmts
  defp statements(nil), do: []
  defp statements(stmt), do: [stmt]

  # -- mode ------------------------------------------------------------------

  defp detect_mode(stmts, aliases, templates) do
    Enum.find_value(stmts, fn
      {:use, _, [{:__aliases__, _, parts} | rest]} when is_list(parts) ->
        if Enum.all?(parts, &is_atom/1) do
          name =
            parts
            |> SafetySupport.expand(aliases)
            |> Enum.join(".")

          mode_for(name, List.first(rest) || [], templates)
        end

      _ ->
        nil
    end)
  end

  defp mode_for("ExUnit.Case", opts, _), do: from_options(opts, nil)

  defp mode_for(name, opts, templates) do
    case Map.fetch(templates, name) do
      {:ok, :inherit} ->
        from_options(opts, name)

      {:ok, forced} ->
        {_, group, _} = from_options(opts, name)
        {forced, group, name}

      :error ->
        nil
    end
  end

  defp from_options(opts, template) do
    kw = if is_list(opts) and Keyword.keyword?(opts), do: opts, else: []

    mode =
      cond do
        not is_list(opts) -> :unknown
        not Keyword.keyword?(opts) -> :unknown
        true -> async_mode(Keyword.fetch(kw, :async))
      end

    group =
      case Keyword.fetch(kw, :group) do
        :error -> nil
        {:ok, group} when is_atom(group) -> group
        {:ok, _} -> :dynamic
      end

    {mode, group, template}
  end

  defp async_mode(:error), do: :serial
  defp async_mode({:ok, true}), do: :async
  defp async_mode({:ok, false}), do: :serial
  defp async_mode({:ok, _}), do: :unknown

  defp serial_tags(stmts) do
    Enum.flat_map(stmts, fn
      {:@, _, [{:moduletag, _, [arg]}]} -> tags_from(arg)
      _ -> []
    end)
  end

  defp tags_from(arg) when is_list(arg) do
    Enum.flat_map(arg, fn
      {:serial, value} when is_atom(value) and value not in [nil, true, false] -> [value]
      {:serial, _} -> [@non_literal_reason]
      _ -> []
    end)
  end

  defp tags_from(_), do: []

  # -- literals --------------------------------------------------------------

  @doc "Module attributes with a literal binary or atom value."
  @spec attrs([Macro.t()]) :: %{atom() => term()}
  def attrs(stmts) do
    for {:@, _, [{name, _, [value]}]} <- stmts,
        is_atom(name),
        is_binary(value) or (is_atom(value) and not is_nil(value)),
        into: %{},
        do: {name, value}
  end

  @doc "Resolves a node to a literal binary/atom, through attributes and `Path.join`."
  @spec literal(Macro.t(), map()) :: {:ok, String.t() | atom()} | :error
  def literal(value, _) when is_binary(value), do: {:ok, value}
  def literal(value, _) when is_atom(value) and not is_nil(value), do: {:ok, value}

  def literal({:@, _, [{name, _, nil}]}, attrs) when is_atom(name), do: Map.fetch(attrs, name)

  def literal({{:., _, [{:__aliases__, _, [:Path]}, :join]}, _, parts}, attrs)
      when is_list(parts) and parts != [] do
    parts = if match?([[_ | _]], parts), do: hd(parts), else: parts
    resolved = Enum.map(parts, &literal(&1, attrs))

    if Enum.all?(resolved, &match?({:ok, v} when is_binary(v), &1)) do
      {:ok,
       resolved
       |> Enum.map(fn {:ok, v} -> v end)
       |> Path.join()}
    else
      :error
    end
  end

  def literal(_, _), do: :error

  @doc "Like `literal/2`, but module aliases also count (expanded name as a string)."
  @spec global_name(Macro.t(), map(), SafetySupport.aliases()) :: {:ok, String.t()} | :error
  def global_name({:__aliases__, _, parts}, _, aliases) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do:
        {:ok,
         parts
         |> SafetySupport.expand(aliases)
         |> Enum.join(".")},
      else: :error
  end

  def global_name(node, attrs, _) do
    case literal(node, attrs) do
      {:ok, v} -> {:ok, to_string(v)}
      :error -> :error
    end
  end

  # -- call scanning ---------------------------------------------------------

  defp scan_calls(body, aliases, attrs) do
    {_, result} = Macro.prewalk(body, {[], [], []}, &scan_node(&1, &2, aliases, attrs))
    result
  end

  defp scan_node(node, {acc, tear, created}, aliases, attrs) do
    line = line_of(node)
    {a, t, c} = node_facts(node, call_of(node, aliases), {aliases, attrs}, line)
    {node, {acc ++ a, tear ++ t, created ++ c}}
  end

  defp node_facts(_, {mod, fun, args}, {aliases, attrs}, line) do
    {classify(mod, fun, args, attrs, line), teardown(mod, fun, args, attrs, aliases, line),
     creates(mod, fun, args, attrs)}
  end

  defp node_facts(node, nil, _, line), do: {setup_global_mock(node, line), [], []}

  defp line_of({_, meta, _}) when is_list(meta), do: meta[:line] || 1
  defp line_of(_), do: 1

  # {"Mod.Name" | ":erlang_mod", fun, args}
  defp call_of({{:., _, [{:__aliases__, _, parts}, fun]}, _, args}, aliases)
       when is_list(parts) and is_atom(fun) and is_list(args) do
    if Enum.all?(parts, &is_atom/1),
      do:
        {parts
         |> SafetySupport.expand(aliases)
         |> Enum.join("."), fun, args}
  end

  defp call_of({{:., _, [mod, fun]}, _, args}, _)
       when is_atom(mod) and is_atom(fun) and is_list(args) and mod not in [nil, true, false],
       do: {inspect(mod), fun, args}

  defp call_of({fun, _, args}, _)
       when fun in [:set_mox_global, :set_mimic_global] and is_list(args),
       do: {"", fun, args}

  defp call_of(_, _), do: nil

  defp setup_global_mock({setup, meta, [arg]}, line)
       when setup in [:setup, :setup_all] and is_list(meta) do
    names = if is_list(arg), do: arg, else: [arg]

    if Enum.any?(names, &(&1 in [:set_mox_global, :set_mimic_global])),
      do: [entry(:mock_global, :global, :write, line, "setup :set_mox_global")],
      else: []
  end

  defp setup_global_mock(_, _), do: []

  defp entry(kind, key, access, line, call),
    do: %{kind: kind, key: key, access: access, line: line, call: call}

  defp key_of(node, attrs) do
    case literal(node, attrs) do
      {:ok, v} -> to_string(v)
      :error -> :dynamic
    end
  end

  defp classify("Application", fun, [app, key | _], attrs, line)
       when fun in [:put_env, :delete_env] do
    [entry(:env, env_key(app, key, attrs), :write, line, "Application.#{fun}")]
  end

  defp classify("Application", :put_all_env, _, _, line),
    do: [entry(:env, :dynamic, :write, line, "Application.put_all_env")]

  defp classify("Application", fun, [app, key | _], attrs, line)
       when fun in [:get_env, :fetch_env, :fetch_env!],
       do: [entry(:env, env_key(app, key, attrs), :read, line, "Application.#{fun}")]

  defp classify("System", fun, [name | _], attrs, line) when fun in [:put_env, :delete_env] do
    key =
      case literal(name, attrs) do
        {:ok, v} when is_binary(v) -> "OS:" <> v
        _ -> :dynamic
      end

    [entry(:env, key, :write, line, "System.#{fun}")]
  end

  defp classify("System", :get_env, [name | _], attrs, line) do
    case literal(name, attrs) do
      {:ok, v} when is_binary(v) -> [entry(:env, "OS:" <> v, :read, line, "System.get_env")]
      _ -> []
    end
  end

  defp classify(mod, fun, _, _, line)
       when (mod in ["Mox", ""] and fun == :set_mox_global) or
              (mod in ["Mimic", ""] and fun == :set_mimic_global),
       do: [entry(:mock_global, :global, :write, line, "#{fun}")]

  defp classify(":ets", :new, [name, opts | _], attrs, line) when is_list(opts) do
    with {:ok, v} <- literal(name, attrs),
         true <- :named_table in opts do
      [entry(:ets, to_string(v), :write, line, ":ets.new")]
    else
      _ -> []
    end
  end

  defp classify(":ets", fun, [table | _], attrs, line)
       when fun in [
              :insert,
              :insert_new,
              :delete,
              :delete_object,
              :delete_all_objects,
              :update_counter,
              :update_element,
              :take
            ] do
    ets_entry(table, attrs, :write, line, fun)
  end

  defp classify(":ets", fun, [table | _], attrs, line)
       when fun in [:lookup, :lookup_element, :select, :match, :member, :tab2list, :info, :first] do
    ets_entry(table, attrs, :read, line, fun)
  end

  defp classify("File", fun, [path | _], attrs, line)
       when fun in [
              :write,
              :write!,
              :rm,
              :rm!,
              :rm_rf,
              :mkdir,
              :mkdir!,
              :mkdir_p,
              :mkdir_p!,
              :cp,
              :cp!,
              :cp_r,
              :touch,
              :touch!,
              :rename,
              :rename!,
              :rmdir,
              :rmdir!
            ] do
    file_entry(path, attrs, :write, line, fun)
  end

  defp classify("File", fun, [path | _], attrs, line)
       when fun in [:read, :read!, :exists?, :ls, :ls!, :stat, :stat!, :regular?, :dir?] do
    file_entry(path, attrs, :read, line, fun)
  end

  defp classify("File", fun, _, _, line) when fun in [:cd, :cd!],
    do: [entry(:cwd, :global, :write, line, "File.#{fun}")]

  defp classify("Logger", fun, _, _, line)
       when fun in [
              :configure,
              :put_module_level,
              :put_application_level,
              :delete_module_level,
              :delete_application_level
            ],
       do: [entry(:logger, :global, :write, line, "Logger.#{fun}")]

  defp classify(":logger", fun, _, _, line)
       when fun in [
              :set_primary_config,
              :set_handler_config,
              :set_module_level,
              :add_handler,
              :remove_handler
            ],
       do: [entry(:logger, :global, :write, line, ":logger.#{fun}")]

  defp classify(":persistent_term", fun, [key | _], attrs, line) when fun in [:put, :erase],
    do: [entry(:persistent_term, key_of(key, attrs), :write, line, ":persistent_term.#{fun}")]

  defp classify(":persistent_term", :get, [key | _], attrs, line),
    do: [entry(:persistent_term, key_of(key, attrs), :read, line, ":persistent_term.get")]

  defp classify("Phoenix.PubSub", fun, [_, topic | _], attrs, line)
       when fun in [
              :subscribe,
              :broadcast,
              :broadcast!,
              :broadcast_from,
              :broadcast_from!,
              :local_broadcast
            ] do
    case literal(topic, attrs) do
      {:ok, v} when is_binary(v) ->
        access = if fun == :subscribe, do: :read, else: :write
        [entry(:topic, v, access, line, "Phoenix.PubSub.#{fun}")]

      _ ->
        []
    end
  end

  defp classify(_, _, _, _, _), do: []

  defp env_key(app, key, attrs) do
    with {:ok, a} <- literal(app, attrs),
         {:ok, k} <- literal(key, attrs) do
      "#{a}.#{k}"
    else
      _ -> :dynamic
    end
  end

  defp ets_entry(table, attrs, access, line, fun) do
    case literal(table, attrs) do
      {:ok, v} when is_atom(v) or is_binary(v) ->
        [entry(:ets, to_string(v), access, line, ":ets.#{fun}")]

      _ ->
        []
    end
  end

  defp file_entry(path, attrs, access, line, fun) do
    case literal(path, attrs) do
      {:ok, v} when is_binary(v) -> [entry(:file, v, access, line, "File.#{fun}")]
      _ -> []
    end
  end

  defp creates(":ets", :new, [name, opts | _], attrs) when is_list(opts) do
    case literal(name, attrs) do
      {:ok, v} -> [to_string(v)]
      :error -> []
    end
  end

  defp creates(_, _, _, _), do: []

  # Teardown calls on app-wide named state. Each entry has :target (string).
  defp teardown(":ets", :delete, [table], attrs, aliases, line) do
    named_target(table, attrs, aliases, line, ":ets.delete/1")
  end

  defp teardown("Application", fun, [app | _], attrs, aliases, line)
       when fun in [:stop, :unload] do
    named_target(app, attrs, aliases, line, "Application.#{fun}")
  end

  defp teardown(mod, fun, [target | _], attrs, aliases, line)
       when mod in ["Supervisor", "DynamicSupervisor", "Task.Supervisor"] and
              fun in [:terminate_child, :delete_child, :stop] do
    named_target(target, attrs, aliases, line, "#{mod}.#{fun}")
  end

  defp teardown(mod, :stop, [target | _], attrs, aliases, line)
       when mod in ["GenServer", "Agent", "Registry", "GenStateMachine", "Phoenix.PubSub"] do
    named_target(target, attrs, aliases, line, "#{mod}.stop")
  end

  defp teardown(
         "Process",
         :exit,
         [{{:., _, [{:__aliases__, _, [:Process]}, :whereis]}, _, [name]} | _],
         attrs,
         aliases,
         line
       ) do
    named_target(name, attrs, aliases, line, "Process.exit(Process.whereis(..))")
  end

  defp teardown(_, _, _, _, _, _), do: []

  defp named_target(node, attrs, aliases, line, call) do
    case global_name(node, attrs, aliases) do
      {:ok, name} -> [%{target: name, line: line, call: call}]
      :error -> []
    end
  end
end
