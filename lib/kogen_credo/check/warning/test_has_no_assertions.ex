defmodule KogenCredo.Check.Warning.TestHasNoAssertions do
  @moduledoc """
  Flags `test` blocks with a body but no assertion of any kind. A test counts as
  asserting when it contains:

    * a call to `assert`, `refute`, `assert_*` or `refute_*`;
    * `flunk`, or a call to a name in `assertion_helpers` or named like one of
      `assertion_prefixes` (default `verify`, `expect`, `flunk`; covers Mox
      `expect/3`, `verify!/0`, `verify_on_exit!/0`). A prefix matches the exact name, the name
      followed by `!`/`?`, or the name followed by `_...`, so `expected(x)` is not an
      assertion; a prefix that itself ends in `_`, `!` or `?` is a plain string prefix. A remote call to an `assert*`/`refute*` function (`MyApp.Assertions.assert_ok(x)`)
      also counts;
    * a destructuring match whose left side is not a plain variable
      (`{:ok, user} = create()`), since a failed match raises (`count_pattern_matches`);
    * `assert_raise`-style calls (covered by the `assert_` prefix).

  Pending tests (`test "name"` without a body) are not reported.

  ## Limitations

  Name based. Helper functions with other names that assert internally are invisible:
  list them in `assertion_helpers`. A smoke test that deliberately only checks "does not
  crash" is reported; add an explicit assertion that it returned, or exclude the file.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      file_suffixes: ["_test.exs"],
      test_macros: [:test],
      assertion_helpers: [],
      assertion_prefixes: ["verify", "expect", "flunk"],
      count_pattern_matches: true
    ],
    explanations: [
      check: """
      A test without an assertion passes whenever the code does not crash. Add an assertion about the
      result or side effect that the test name promises, or delete the test.
      """,
      params: [
        file_suffixes: "Filename suffixes treated as test files.",
        test_macros: "Macros that define a test body.",
        assertion_helpers: "Extra function names that count as assertions.",
        assertion_prefixes: "Function-name prefixes that count as assertions.",
        count_pattern_matches: "Treat destructuring matches (`{:ok, x} = f()`) as assertions."
      ]
    ]

  alias KogenCredo.CoreSupport.Ast
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

      helpers =
        params
        |> Params.get(:assertion_helpers, __MODULE__)
        |> Settings.atoms!(:assertion_helpers)

      prefixes =
        params
        |> Params.get(:assertion_prefixes, __MODULE__)
        |> Settings.strings!(:assertion_prefixes)

      matches? = Params.get(params, :count_pattern_matches, __MODULE__)

      source_file
      |> SourceFile.ast()
      |> Tests.test_blocks(
        params
        |> Params.get(:test_macros, __MODULE__)
        |> Settings.atoms!(:test_macros)
      )
      |> Enum.reject(&asserts?(&1.body, helpers, prefixes, matches?))
      |> Enum.map(fn %{name: name, meta: meta} ->
        format_issue(issue_meta,
          message:
            "Test #{describe(name)} has no assertion, so it only fails if the code crashes. " <>
              "Assert the result or side effect, or delete the test.",
          trigger: "test",
          line_no: meta[:line]
        )
      end)
    else
      []
    end
  end

  defp describe(name) when is_binary(name), do: inspect(name)
  defp describe(_), do: "(dynamic name)"

  defp asserts?(body, helpers, prefixes, matches?) do
    body
    |> Ast.expand_pipes()
    |> Ast.walk(false, &assertion_step(&1, &2, helpers, prefixes, matches?))
  end

  defp assertion_step(_, true, _, _, _), do: true

  defp assertion_step({:=, _, [left, _]}, false, _, _, matches?),
    do: matches? and destructuring?(left)

  defp assertion_step({{:., _, [_, name]}, _, args}, false, _, _, _)
       when is_atom(name) and is_list(args),
       do: Tests.assertion_name?(name)

  defp assertion_step({name, _, args}, false, helpers, prefixes, _)
       when is_atom(name) and is_list(args),
       do: Tests.assertion_name?(name) or name in helpers or prefixed?(name, prefixes)

  defp assertion_step(_, false, _, _, _), do: false

  defp prefixed?(name, prefixes) do
    s = Atom.to_string(name)

    Enum.any?(prefixes, fn p ->
      s == p or String.starts_with?(s, [p <> "_", p <> "!", p <> "?"]) or
        (String.ends_with?(p, ["_", "!", "?"]) and String.starts_with?(s, p))
    end)
  end

  defp destructuring?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: false
  defp destructuring?(_), do: true
end
