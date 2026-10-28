defmodule KogenCredo.Check.Warning.SharedResourceGroup do
  @moduledoc """
  Async test modules that touch the same literal global resource must share one
  `group:` (or be serial). Otherwise they run concurrently and race.

  A "resource" is a literal application env key (`Application.put_env(:app, :key, ..)`),
  OS env var, named ETS table, fixed file path, PubSub topic or
  `:persistent_term` key. A module "touches" it by reading or writing it with a
  literal name in its own body. A resource is reported when at least one async
  module writes it, at least two async modules touch it, and those modules do
  not all share the same literal `group:`. Serial modules never race with async
  ones (they run afterwards), so they are ignored.

  This is a cross-file check. It implements Credo's all-source-files protocol
  (`run_on_all_source_files/3`), so a real `mix credo` run compares modules
  across files. `analyze/2` is the same logic as a pure function over source
  files for tests and tooling.

  ## Params

    * `case_templates` - declared case templates (see `KogenCredo.TestModuleInfo`).
    * `kinds` - resource kinds compared. Default `[:env, :ets, :file, :topic, :persistent_term]`.
    * `included_files` - path globs. Default `["test/**/*_test.exs"]`.

  ## Limits

  Only literal names are compared; `:dynamic` keys are ignored. Code under test
  that reads the key from elsewhere is invisible, so a module reading a key that
  no test module names can still race. A matching group does not prove the
  resource is only touched by tests (see `GlobalStateInAsync`).
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    run_on_all: true,
    param_defaults: [
      case_templates: %{},
      kinds: [:env, :ets, :file, :topic, :persistent_term],
      included_files: ["test/**/*_test.exs"]
    ],
    explanations: [
      check: """
      Async modules that touch the same global resource (env key, named ETS
      table, fixed path, PubSub topic) must be in the same `group:` so they run
      one after another.

      **Bad:** two `async: true` modules both call `Application.put_env(:app, :mode, ..)`.

      **Good:** both use `use ExUnit.Case, async: true, group: :app_mode`.
      """,
      params: [
        case_templates: "Map of case template module name => :inherit | :async | :serial.",
        kinds: "Resource kinds compared across modules.",
        included_files: "Path globs of files to check."
      ]
    ]

  alias Credo.Execution.ExecutionIssues
  alias KogenCredo.SafetySupport
  alias KogenCredo.TestModuleInfo

  @doc false
  @spec run_on_all_source_files(Credo.Execution.t(), [Credo.SourceFile.t()], keyword()) :: :ok
  def run_on_all_source_files(exec, source_files, params) do
    by_name = Map.new(source_files, &{&1.filename, &1})

    for finding <- analyze(source_files, params) do
      source_file = Map.fetch!(by_name, finding.filename)
      issue_meta = IssueMeta.for(source_file, params)

      issue =
        format_issue(issue_meta,
          message: finding.message,
          trigger: finding.trigger,
          line_no: finding.line
        )

      ExecutionIssues.append(exec, source_file, issue)
    end

    :ok
  end

  @doc """
  Pure analysis. Returns `[%{filename, line, trigger, message, resource, module}]`.

  `params` takes the same keys as the check (`:case_templates`, `:kinds`,
  `:included_files`); missing keys use the defaults.
  """
  @spec analyze([Credo.SourceFile.t()], keyword()) :: [map()]
  def analyze(source_files, params \\ []) do
    kinds = Params.get(params, :kinds, __MODULE__)

    source_files
    |> async_modules(params)
    |> resources(kinds)
    |> Enum.flat_map(&findings/1)
    |> Enum.uniq_by(&{&1.filename, &1.module, &1.resource})
    |> Enum.sort_by(&{&1.filename, &1.line})
  end

  defp async_modules(source_files, params) do
    templates = Params.get(params, :case_templates, __MODULE__)
    included = Params.get(params, :included_files, __MODULE__)

    for sf <- source_files,
        SafetySupport.path_matches?(sf.filename, included),
        ast <- [Credo.SourceFile.ast(sf)],
        info <- TestModuleInfo.parse(ast, case_templates: templates),
        info.mode == :async do
      {sf.filename, info}
    end
  end

  # %{{kind, key} => [{filename, info, [access]}]}
  defp resources(modules, kinds) do
    Enum.reduce(modules, %{}, fn {filename, info}, acc ->
      info.accesses
      |> Enum.filter(&(&1.kind in kinds and is_binary(&1.key)))
      |> Enum.group_by(&{&1.kind, &1.key})
      |> Enum.reduce(acc, &add_toucher(&1, &2, filename, info))
    end)
  end

  defp add_toucher({resource, accesses}, acc, filename, info),
    do:
      Map.update(acc, resource, [{filename, info, accesses}], &[{filename, info, accesses} | &1])

  defp findings({{kind, key}, touchers}) do
    if shared_without_group?(touchers) do
      for {filename, info, accesses} <- touchers do
        finding(filename, info, accesses, {kind, key}, touchers)
      end
    else
      []
    end
  end

  defp shared_without_group?(touchers) do
    groups =
      touchers
      |> Enum.map(fn {_, info, _} -> info.group end)
      |> Enum.uniq()

    writer? = Enum.any?(touchers, fn {_, _, acc} -> Enum.any?(acc, &(&1.access == :write)) end)
    shared_group? = match?([group] when group != nil, groups)

    length(touchers) >= 2 and writer? and not shared_group?
  end

  defp finding(filename, info, accesses, {kind, key}, touchers) do
    first = Enum.min_by(accesses, & &1.line)
    others = for {_, o, _} <- touchers, o.name != info.name, do: o.name

    %{
      filename: filename,
      line: first.line,
      trigger:
        first.call
        |> String.split(".")
        |> List.last(),
      module: info.name,
      resource: {kind, key},
      message:
        "#{info.name} and #{Enum.join(Enum.sort(others), ", ")} are async and share #{kind} #{inspect(key)} " <>
          "(#{first.call}) without a common `group:`. Put every module touching it in one group " <>
          "(`use ExUnit.Case, async: true, group: :name`) or make them serial."
    }
  end
end
