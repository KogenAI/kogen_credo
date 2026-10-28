defmodule KogenCredo.Check.Warning.TestModuleShape do
  @moduledoc """
  Keeps test modules async and small. For files ending in `file_suffixes`
  (default `_test.exs`):

    * every `use <Something>Case` must pass `async: true`, unless the file matches an
      entry of `serial_allowed` (exact path, trailing path suffix or glob). The list
      belongs in protected configuration, so adding a serial module is a deliberate act;
    * a test module may define at most `max_tests` test runs. A literal
      `parameterize:` list multiplies the count.

  ## Limitations

  Only `use` calls whose module name ends with `case_suffix` are recognised and the
  `async:` value must be the literal `true`. Tests defined by macros, `for` comprehensions
  or `property` are not counted. Serial-by-necessity suites belong in `serial_allowed`,
  not in a code comment.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      file_suffixes: ["_test.exs"],
      max_tests: 30,
      serial_allowed: [],
      case_suffix: "Case",
      require_async: true
    ],
    explanations: [
      check: """
      Async test modules run concurrently and fail fast on hidden global state; large test
      modules hide unrelated behaviour. Use `async: true`, inject dependencies instead of
      mutating globals, and split modules by behaviour. Serial modules need an explicit,
      reviewed `serial_allowed` entry.
      """,
      params: [
        file_suffixes: "Filename suffixes treated as test files.",
        max_tests: "Maximum test runs per module (tests x literal parameterize entries).",
        serial_allowed: "Files (path, suffix or glob) allowed to be non-async.",
        case_suffix: "Module-name suffix identifying a test case template (`Case`).",
        require_async: "Set to false to only check the size cap."
      ]
    ]

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Settings
  alias KogenCredo.CoreSupport.Tests

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    suffixes =
      params
      |> Params.get(:file_suffixes, __MODULE__)
      |> Settings.strings!(:file_suffixes)

    if Tests.test_file?(filename, suffixes) do
      issue_meta = IssueMeta.for(source_file, params)
      limits = limits(filename, params)

      source_file
      |> SourceFile.ast()
      |> Ast.modules()
      |> Enum.flat_map(&module_issues(&1, limits, issue_meta))
    else
      []
    end
  end

  defp limits(filename, params) do
    suffix =
      params
      |> Params.get(:case_suffix, __MODULE__)
      |> validate_suffix()

    max =
      params
      |> Params.get(:max_tests, __MODULE__)
      |> Settings.integer!(:max_tests, 1)

    %{
      serial_ok: Paths.matches_any?(filename, Params.get(params, :serial_allowed, __MODULE__)),
      suffix: suffix,
      max: max,
      require_async: Params.get(params, :require_async, __MODULE__)
    }
  end

  defp module_issues({_, meta, body}, limits, issue_meta) do
    info =
      body
      |> Ast.strip_modules()
      |> collect(limits.suffix)

    async =
      if limits.require_async and not limits.serial_ok,
        do: async_issues(info, issue_meta),
        else: []

    async ++ size_issues(info, meta, issue_meta, limits.max)
  end

  defp validate_suffix(s) when is_binary(s) and s != "", do: s
  defp validate_suffix(s), do: Settings.raise_bad(:case_suffix, s, "a non-empty string")

  defp collect(body, suffix),
    do: Ast.walk(body, %{uses: [], tests: 0, params: 1}, &count(&1, &2, suffix))

  defp count({:use, meta, [{:__aliases__, _, parts} | rest]}, acc, suffix) do
    if case_module?(parts, suffix), do: add_use(acc, meta, rest), else: acc
  end

  defp count({:test, _, [name | _]}, acc, _) when is_binary(name) or is_tuple(name),
    do: %{acc | tests: acc.tests + 1}

  defp count(_, acc, _), do: acc

  defp add_use(acc, meta, rest) do
    opts = if match?([[_ | _]], rest), do: hd(rest), else: []
    n = if is_list(opts[:parameterize]), do: max(length(opts[:parameterize]), 1), else: 1
    %{acc | uses: [{meta[:line], opts[:async]} | acc.uses], params: max(acc.params, n)}
  end

  defp case_module?(parts, suffix) do
    Enum.all?(parts, &is_atom/1) and
      parts
      |> List.last()
      |> Atom.to_string()
      |> String.ends_with?(suffix)
  end

  defp async_issues(info, issue_meta) do
    for {line, async} <- info.uses, async != true do
      format_issue(issue_meta,
        message:
          "Test module is not `async: true`. Inject dependencies (root, env, clock) instead of mutating globals; " <>
            "a genuinely serial module needs a reviewed entry in `serial_allowed`.",
        line_no: line,
        trigger: "use"
      )
    end
  end

  defp size_issues(info, meta, issue_meta, max) do
    runs = info.tests * info.params

    if runs > max do
      [
        format_issue(issue_meta,
          message:
            "Test module defines #{runs} test runs (#{info.tests} tests x #{info.params} params; max #{max}). " <>
              "Split by behaviour, or drop parameters that most tests ignore.",
          line_no: meta[:line] || 1,
          trigger: "defmodule"
        )
      ]
    else
      []
    end
  end
end
