defmodule KogenCredo.Check.Warning.WeakAssertion do
  @moduledoc """
  Flags assertions that prove too little, when a test has nothing stronger:

    * type-only predicates: `assert is_map(x)`, `is_list`, `is_binary`, … (`weak_predicates`);
    * non-nil checks: `assert x != nil`, `assert not is_nil(x)`, `refute is_nil(x)`, `refute x == nil`;
    * non-empty checks: `assert length(x) > 0` (also `>= 1`), `assert x != []`, `assert x != %{}`,
      `assert Enum.count(x) > 0`, `refute Enum.empty?(x)`;
    * `assert_receive _` / `assert_received _` with a bare wildcard pattern.

  By default (`only_when_all_weak: true`) a weak assertion is reported only if *every*
  assertion in the test is weak; a test that also asserts a concrete value is not
  noisy. Set it to `false` to report every weak assertion. A call to a function named in
  `assertion_helpers` (a custom helper that asserts internally) counts as a strong
  assertion in the test.

  ## Limitations

  Name-based: `assert is_map(x)` may be exactly the contract under test; the check
  cannot know. Assertions inside helper functions and `setup` are not seen, and
  custom `assert_*` helpers count as strong (unless named in `weak_helpers`).
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      file_suffixes: ["_test.exs"],
      test_macros: [:test],
      only_when_all_weak: true,
      weak_predicates: [
        :is_map,
        :is_list,
        :is_binary,
        :is_atom,
        :is_integer,
        :is_float,
        :is_number,
        :is_tuple,
        :is_boolean,
        :is_function,
        :is_struct,
        :is_pid,
        :is_reference
      ],
      weak_helpers: [],
      assertion_helpers: []
    ],
    explanations: [
      check: """
      `assert is_map(result)` or `assert result != nil` passes for almost any bug. Assert the exact
      value or a pattern that pins the interesting fields: `assert %{status: :ok, id: ^id} = result`.
      """,
      params: [
        file_suffixes: "Filename suffixes treated as test files.",
        test_macros: "Macros that define a test body.",
        only_when_all_weak: "Report only when every assertion in the test is weak.",
        weak_predicates: "Type predicates considered weak.",
        weak_helpers: "Names of custom assertion helpers considered weak.",
        assertion_helpers:
          "Names of custom helpers that assert strongly; a test calling one is not weak."
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
      cfg = settings(params)

      source_file
      |> SourceFile.ast()
      |> Tests.test_blocks(test_macros(params))
      |> Enum.flat_map(&weak_hits(&1, cfg))
      |> Enum.map(&weak_issue(issue_meta, &1))
    else
      []
    end
  end

  defp test_macros(params) do
    params
    |> Params.get(:test_macros, __MODULE__)
    |> Settings.atoms!(:test_macros)
  end

  defp settings(params) do
    all_weak? = Params.get(params, :only_when_all_weak, __MODULE__)

    preds =
      params
      |> Params.get(:weak_predicates, __MODULE__)
      |> Settings.atoms!(:weak_predicates)

    helpers =
      params
      |> Params.get(:weak_helpers, __MODULE__)
      |> Settings.atoms!(:weak_helpers)

    strong_helpers =
      params
      |> Params.get(:assertion_helpers, __MODULE__)
      |> Settings.atoms!(:assertion_helpers)

    %{all_weak?: all_weak?, preds: preds, helpers: helpers, strong_helpers: strong_helpers}
  end

  defp weak_hits(%{body: body}, cfg) do
    classified =
      for {name, _, meta} = a <- Tests.assertions(body),
          do: {classify(a, cfg.preds, cfg.helpers), name, meta}

    weak = for {{:weak, why}, _, meta} <- classified, do: {meta[:line], why}

    if weak != [] and reportable?(classified, body, cfg), do: weak, else: []
  end

  defp reportable?(classified, body, cfg) do
    not cfg.all_weak? or
      (Enum.all?(classified, &match?({{:weak, _}, _, _}, &1)) and
         not calls_any?(body, cfg.strong_helpers))
  end

  defp weak_issue(issue_meta, {line, why}) do
    format_issue(issue_meta,
      message:
        "Weak assertion: #{why}. Assert the expected value or a pattern that pins its content.",
      trigger: "assert",
      line_no: line
    )
  end

  defp calls_any?(_, []), do: false

  defp calls_any?(body, names) do
    Ast.walk(body, false, fn
      _, true -> true
      {name, _, args}, false when is_atom(name) and is_list(args) -> name in names
      _, false -> false
    end)
  end

  defp classify({name, [expr | _], _}, preds, _) when name in [:assert, :refute] do
    weak_expr(name, expr, preds) || :strong
  end

  defp classify({name, [{:_, _, ctx} | _], _}, _, _)
       when name in [:assert_receive, :assert_received] and is_atom(ctx),
       do: {:weak, "`#{name} _` matches any message"}

  defp classify({name, _, _}, _, helpers),
    do: if(name in helpers, do: {:weak, "`#{name}` is configured as weak"}, else: :strong)

  defp weak_expr(:assert, {op, _, [_, nil]}, _) when op in [:!=, :!==],
    do: {:weak, "only checks the value is not nil"}

  defp weak_expr(:assert, {op, _, [nil, _]}, _) when op in [:!=, :!==],
    do: {:weak, "only checks the value is not nil"}

  defp weak_expr(:assert, {op, _, [_, []]}, _) when op in [:!=, :!==],
    do: {:weak, "only checks the value is not empty"}

  defp weak_expr(:assert, {op, _, [{:is_nil, _, [_]}]}, _) when op in [:not, :!],
    do: {:weak, "only checks the value is not nil"}

  defp weak_expr(:assert, {pred, _, [_]}, preds) when is_atom(pred) do
    if pred in preds, do: {:weak, "`#{pred}/1` only checks the type"}
  end

  defp weak_expr(:assert, {op, _, [_, {:%{}, _, []}]}, _) when op in [:!=, :!==],
    do: {:weak, "only checks the value is not empty"}

  defp weak_expr(:assert, {:>, _, [{len, _, [_]}, 0]}, _)
       when len in [:length, :map_size, :tuple_size],
       do: {:weak, "only checks the size is positive"}

  defp weak_expr(:assert, {:>=, _, [{len, _, [_]}, 1]}, _)
       when len in [:length, :map_size, :tuple_size],
       do: {:weak, "only checks the size is positive"}

  defp weak_expr(:refute, {{:., _, [{:__aliases__, _, [:Enum]}, :empty?]}, _, [_]}, _),
    do: {:weak, "only checks the collection is not empty"}

  defp weak_expr(
         :assert,
         {:>, _, [{{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [_]}, 0]},
         _
       ),
       do: {:weak, "only checks the count is positive"}

  defp weak_expr(:refute, {:is_nil, _, [_]}, _), do: {:weak, "only checks the value is not nil"}
  defp weak_expr(:refute, {:==, _, [_, nil]}, _), do: {:weak, "only checks the value is not nil"}
  defp weak_expr(:refute, {:==, _, [nil, _]}, _), do: {:weak, "only checks the value is not nil"}
  defp weak_expr(:refute, {:==, _, [_, []]}, _), do: {:weak, "only checks the value is not empty"}
  defp weak_expr(_, _, _), do: nil
end
