defmodule KogenCredo.Check.Warning.GlobalStateInAsync do
  @moduledoc """
  An `async: true` test module without a `group:` changes node-wide state:
  application or OS env, global mocks, named ETS tables, fixed file paths, the
  working directory, Logger configuration or `:persistent_term`.

  Async modules run concurrently with every other async module, so these writes
  race with any test that reads the same state. Use `async: true, group: :name`
  when only tests touch it (and put every toucher in the group), make the
  resource test-local (`tmp_dir`, unique names), or run the module serially
  with `@moduletag serial: :reason`.

  Mode and group come from the parsed `use ExUnit.Case, async:, group:` options
  (see `KogenCredo.TestModuleInfo`), not from text search.

  ## Params

    * `case_templates` - declared case templates (`:inherit`, `:async`, `:serial`).
    * `kinds` - which kinds of state to report. Default all of
      `[:env, :mock_global, :ets, :file, :cwd, :logger, :persistent_term]`.
    * `included_files` - path globs. Default `["test/**/*_test.exs"]`.

  ## Limits

  Only calls written directly in the test module are seen; helpers in other
  modules are not followed. Only literal ETS names and file paths are tracked, so
  `tmp_dir`-derived paths are (correctly) ignored. A `group:` suppresses this
  check; use `KogenCredo.Check.Warning.SharedResourceGroup` to verify the group.
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      case_templates: %{},
      kinds: [:env, :mock_global, :ets, :file, :cwd, :logger, :persistent_term],
      included_files: ["test/**/*_test.exs"]
    ],
    explanations: [
      check: """
      Async test modules must not write node-wide state. Application env,
      `System.put_env`, global mocks, named ETS tables, fixed file paths,
      `Logger.configure` and `:persistent_term.put` leak into concurrently
      running modules.

      **Bad:**
      ```elixir
      use ExUnit.Case, async: true
      setup do: Application.put_env(:my_app, :mode, :test)
      ```

      **Good:**
      ```elixir
      use ExUnit.Case, async: true, group: :my_app_mode
      ```
      or `async: false` with `@moduletag serial: :env`.
      """,
      params: [
        case_templates: "Map of case template module name => :inherit | :async | :serial.",
        kinds: "Kinds of global state to report.",
        included_files: "Path globs of files to check."
      ]
    ]

  alias KogenCredo.SafetySupport
  alias KogenCredo.TestModuleInfo

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    templates = Params.get(params, :case_templates, __MODULE__)
    kinds = Params.get(params, :kinds, __MODULE__)
    included = Params.get(params, :included_files, __MODULE__)

    if SafetySupport.path_matches?(source_file.filename, included) do
      source_file
      |> Credo.SourceFile.ast()
      |> TestModuleInfo.parse(case_templates: templates)
      |> Enum.filter(&(&1.mode == :async and is_nil(&1.group)))
      |> Enum.flat_map(&module_issues(&1, kinds, issue_meta))
    else
      []
    end
  end

  defp module_issues(info, kinds, issue_meta) do
    for access <- info.accesses, access.access == :write, access.kind in kinds do
      format_issue(issue_meta,
        message:
          "#{info.name} is async with no group but calls #{access.call} (#{describe(access)}). " <>
            "Add `group:` for test-owned state, isolate the resource per test, or make the module serial with `@moduletag serial: ...`.",
        trigger: trigger(access.call),
        line_no: access.line
      )
    end
  end

  defp describe(%{kind: kind, key: :dynamic}), do: "#{kind}, dynamic key"
  defp describe(%{kind: kind, key: :global}), do: "#{kind}"
  defp describe(%{kind: kind, key: key}), do: "#{kind} #{inspect(to_string(key))}"

  defp trigger(call) do
    call
    |> String.split(".")
    |> List.last()
    |> String.replace(~r/[^\w!?:]+.*$/, "")
  end
end
