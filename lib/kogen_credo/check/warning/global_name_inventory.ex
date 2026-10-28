defmodule KogenCredo.Check.Warning.GlobalNameInventory do
  @moduledoc """
  Informational inventory of global names declared in library code: literal
  PubSub topics, named ETS tables, `:persistent_term` keys and literal process
  registrations (`name: __MODULE__`, `name: :atom`, `{:global, ..}`/`{:via, ..}`
  with literals).

  Global names make tests that touch them serial (a shared topic or table is
  visible to every test). The check lists them so each can be made injectable
  (a `:name` or `:topic` option with a default) or consciously accepted via
  `allowed_names`. It runs at `:low` priority and is meant to be read, not
  gated on.

  ## Params

    * `kinds` - any of `[:topic, :ets, :persistent_term, :process_name]`. Default all.
    * `allowed_names` - names (strings, as shown in the message) accepted as global.
    * `included_files` - path globs. Default `["lib/**/*.ex"]`.

  ## Limits

  A name taken from an option with a default (`name: Keyword.get(opts, :name, __MODULE__)`)
  counts as injectable and is not reported. Interpolated topics and names built
  at runtime are not reported. Names hidden in `use` macros, child-spec tuples
  (`{Mod, name: X}`) or config are invisible.
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      kinds: [:topic, :ets, :persistent_term, :process_name],
      allowed_names: [],
      included_files: ["lib/**/*.ex"]
    ],
    explanations: [
      check: """
      A global name (PubSub topic, named ETS table, registered process name)
      makes every test that touches it share state with every other test.
      Accept an option with a default so tests can pass a unique name.

      **Reported:**
      ```elixir
      Phoenix.PubSub.broadcast(MyApp.PubSub, "drops", msg)
      :ets.new(:cache, [:named_table])
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      ```
      """,
      params: [
        kinds: "Kinds of names to report.",
        allowed_names: "Names accepted as global.",
        included_files: "Path globs of files to check."
      ]
    ]

  alias KogenCredo.SafetySupport
  alias KogenCredo.TestModuleInfo

  @starters [
    "GenServer",
    "Agent",
    "Supervisor",
    "DynamicSupervisor",
    "Task.Supervisor",
    "Registry",
    "GenStateMachine"
  ]
  @module_marker "\0inspect(__MODULE__)"
  @pubsub_funs [
    :subscribe,
    :broadcast,
    :broadcast!,
    :broadcast_from,
    :broadcast_from!,
    :local_broadcast
  ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    kinds = Params.get(params, :kinds, __MODULE__)

    allowed =
      params
      |> Params.get(:allowed_names, __MODULE__)
      |> Enum.map(&to_string/1)

    included = Params.get(params, :included_files, __MODULE__)

    if SafetySupport.path_matches?(source_file.filename, included) do
      source_file
      |> found_names()
      |> Enum.filter(fn {kind, name, _, _} -> kind in kinds and name not in allowed end)
      |> Enum.map(&name_issue(issue_meta, &1))
    else
      []
    end
  end

  defp found_names(source_file) do
    ast =
      source_file
      |> Credo.SourceFile.ast()
      |> KogenCredo.QuerySupport.expand_pipes()

    aliases = SafetySupport.aliases(ast)
    stmts = top_statements(ast)

    attrs =
      stmts
      |> TestModuleInfo.attrs()
      |> Map.merge(module_attrs(stmts))

    {_, found} =
      Macro.prewalk(ast, [], fn node, acc -> {node, names(node, aliases, attrs) ++ acc} end)

    Enum.reverse(found)
  end

  defp name_issue(issue_meta, {kind, name, line, trigger}) do
    format_issue(issue_meta,
      message:
        "Global #{label(kind)} #{name}: tests touching it share state with every other test. " <>
          "Make it injectable (an option with a default) or add it to `allowed_names`.",
      trigger: trigger,
      line_no: line
    )
  end

  defp label(:topic), do: "PubSub topic"
  defp label(:ets), do: "named ETS table"
  defp label(:persistent_term), do: ":persistent_term key"
  defp label(:process_name), do: "process name"

  # Attributes are gathered from every module body, flattened.
  defp top_statements(ast) do
    {_, stmts} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{_, _, [_]}]} = node, acc -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    stmts
  end

  # `@topic inspect(__MODULE__)` is not a literal, but it is a fixed global name.
  defp module_attrs(stmts) do
    for {:@, _, [{name, _, [{:inspect, _, [{:__MODULE__, _, _}]}]}]} <- stmts,
        into: %{},
        do: {name, @module_marker}
  end

  defp names({{:., _, [receiver, fun]}, meta, args}, aliases, attrs)
       when is_atom(fun) and is_list(args) do
    line = meta[:line] || 1
    mod = module_name(receiver, aliases)
    named_call(mod, fun, args, {attrs, aliases, line})
  end

  defp names(_, _, _), do: []

  defp named_call("Phoenix.PubSub", fun, args, {attrs, _, line}) when fun in @pubsub_funs do
    args
    |> Enum.at(1)
    |> topic(attrs, line, to_string(fun))
  end

  defp named_call(":ets", :new, args, {attrs, _, line}), do: ets(args, attrs, line)

  defp named_call(":persistent_term", :put, args, {attrs, _, line}),
    do: persistent(args, attrs, line)

  defp named_call(mod, fun, args, {attrs, aliases, line})
       when mod in @starters and fun in [:start_link, :start],
       do: process_name(args, attrs, aliases, line, to_string(fun))

  defp named_call(_, _, _, _), do: []

  defp module_name({:__aliases__, _, parts}, aliases) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do:
        parts
        |> SafetySupport.expand(aliases)
        |> Enum.join(".")
  end

  defp module_name(atom, _) when is_atom(atom) and not is_nil(atom), do: inspect(atom)
  defp module_name(_, _), do: nil

  defp topic(node, attrs, line, trigger) do
    case TestModuleInfo.literal(node, attrs) do
      {:ok, @module_marker} -> [{:topic, "inspect(__MODULE__)", line, trigger}]
      {:ok, v} when is_binary(v) -> [{:topic, inspect(v), line, trigger}]
      _ -> []
    end
  end

  defp ets([name, opts | _], attrs, line) when is_list(opts) do
    with true <- :named_table in opts, {:ok, v} <- TestModuleInfo.literal(name, attrs) do
      [{:ets, inspect(v), line, "new"}]
    else
      _ -> []
    end
  end

  defp ets(_, _, _), do: []

  defp persistent([key | _], attrs, line) do
    case TestModuleInfo.literal(key, attrs) do
      {:ok, v} -> [{:persistent_term, inspect(v), line, "put"}]
      :error -> []
    end
  end

  defp persistent(_, _, _), do: []

  defp process_name(args, attrs, aliases, line, trigger) do
    args
    |> Enum.filter(&Keyword.keyword?/1)
    |> Enum.flat_map(fn kw ->
      case Keyword.fetch(kw, :name) do
        {:ok, value} -> registered(value, attrs, aliases, line, trigger)
        :error -> []
      end
    end)
  end

  defp registered({:__MODULE__, _, _}, _, _, line, trigger),
    do: [{:process_name, "__MODULE__", line, trigger}]

  defp registered({:__aliases__, _, parts}, _, aliases, line, trigger) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do: [
        {:process_name,
         parts
         |> SafetySupport.expand(aliases)
         |> Enum.join("."), line, trigger}
      ],
      else: []
  end

  defp registered({tag, name}, attrs, aliases, line, trigger) when tag in [:global] do
    registered(name, attrs, aliases, line, trigger)
  end

  defp registered({:{}, _, [tag, name | _]}, attrs, aliases, line, trigger)
       when tag in [:global, :via] do
    registered(name, attrs, aliases, line, trigger)
  end

  defp registered(value, attrs, _, line, trigger) do
    case TestModuleInfo.literal(value, attrs) do
      {:ok, v} -> [{:process_name, inspect(v), line, trigger}]
      :error -> []
    end
  end
end
