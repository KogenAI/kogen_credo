defmodule KogenCredo.Check.Warning.SerialReason do
  @moduledoc """
  A test module that runs serially (`async: false`, or no `async:` option at all)
  must name why with `@moduletag serial: <reason>`, where the reason is an atom
  from a configured vocabulary.

  Unlike a free-text comment, the tag is machine-readable, so a serial list can
  be audited and each reason challenged ("prove a module is serial before
  keeping it so").

  ## Params

    * `serial_vocabulary` - allowed reason atoms. An empty list accepts any atom.
      Default: `[:env, :ets, :file, :cwd, :mock_global, :logger, :persistent_term, :pubsub, :named_process, :sandbox_shared, :external]`.
    * `case_templates` - case templates to resolve, as a map of module name to
      `:inherit` (forwards `async:`), `:async` or `:serial` (forces that mode).
      See `KogenCredo.TestModuleInfo`. A `use` of an undeclared template is not
      analysed.
    * `allowed_modules` - module names exempt from the check (for a protected
      list kept in configuration).
    * `included_files` - path globs the check applies to. Default `["test/**/*_test.exs"]`.

  ## Limits

  A non-literal `async:` value is treated as unknown and skipped. The check
  verifies that a reason is declared and in vocabulary, not that it is true.
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      serial_vocabulary: [
        :env,
        :ets,
        :file,
        :cwd,
        :mock_global,
        :logger,
        :persistent_term,
        :pubsub,
        :named_process,
        :sandbox_shared,
        :external
      ],
      case_templates: %{},
      allowed_modules: [],
      included_files: ["test/**/*_test.exs"]
    ],
    explanations: [
      check: """
      A serial test module adds its whole run time to the suite's serial phase.
      Declare why it must be serial with `@moduletag serial: :reason`, using the
      project's vocabulary, so the reason can be reviewed and later removed.

      **Bad:**
      ```elixir
      use ExUnit.Case, async: false
      ```

      **Good:**
      ```elixir
      use ExUnit.Case, async: false
      @moduletag serial: :env
      ```

      Prefer `async: true, group: :resource` when only tests touch the resource.
      """,
      params: [
        serial_vocabulary: "Allowed `serial:` reason atoms; `[]` accepts any atom.",
        case_templates: "Map of case template module name => :inherit | :async | :serial.",
        allowed_modules: "Module names exempt from the check.",
        included_files: "Path globs of files to check."
      ]
    ]

  alias KogenCredo.SafetySupport
  alias KogenCredo.TestModuleInfo

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    vocabulary = Params.get(params, :serial_vocabulary, __MODULE__)

    allowed =
      params
      |> Params.get(:allowed_modules, __MODULE__)
      |> Enum.map(&to_string/1)

    templates = Params.get(params, :case_templates, __MODULE__)
    included = Params.get(params, :included_files, __MODULE__)

    if SafetySupport.path_matches?(source_file.filename, included) do
      source_file
      |> Credo.SourceFile.ast()
      |> TestModuleInfo.parse(case_templates: templates)
      |> Enum.filter(&(&1.mode == :serial and &1.name not in allowed))
      |> Enum.flat_map(&issues_for(&1, vocabulary, issue_meta))
    else
      []
    end
  end

  defp issues_for(%{serial_tags: []} = info, vocabulary, issue_meta) do
    [
      format_issue(issue_meta,
        message:
          "#{info.name} runs serially but has no `@moduletag serial: <reason>`. " <>
            "Add a reason#{vocab_hint(vocabulary)}, or make the module async (use `group:` for a shared test-owned resource).",
        trigger:
          info.name
          |> String.split(".")
          |> List.last(),
        line_no: info.line
      )
    ]
  end

  defp issues_for(info, vocabulary, issue_meta) do
    non_literal = TestModuleInfo.non_literal_reason()

    for tag <- info.serial_tags,
        tag == non_literal or (vocabulary != [] and tag not in vocabulary) do
      format_issue(issue_meta,
        message:
          if tag == non_literal do
            "#{info.name} has `@moduletag serial:` with a value that is not a literal reason atom " <>
              "(`true`, `nil` and expressions explain nothing)#{vocab_hint(vocabulary)}."
          else
            "#{info.name} uses `@moduletag serial: #{inspect(tag)}`, which is not in the serial vocabulary#{vocab_hint(vocabulary)}."
          end,
        trigger:
          info.name
          |> String.split(".")
          |> List.last(),
        line_no: info.line
      )
    end
  end

  defp vocab_hint([]), do: ""
  defp vocab_hint(vocabulary), do: " (one of #{Enum.map_join(vocabulary, ", ", &inspect/1)})"
end
