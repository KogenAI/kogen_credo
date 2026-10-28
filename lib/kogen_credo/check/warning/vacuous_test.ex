defmodule KogenCredo.Check.Warning.VacuousTest do
  @moduledoc """
  Flags assertions inside `test` blocks that cannot fail:

    * constant expressions that evaluate truthy for `assert` (or falsy for `refute`):
      `assert true`, `assert 1 == 1`, `refute false`, `assert "a" <> "b" == "ab"`.
      Only literals and pure operators are evaluated; anything with a variable or
      function call is never evaluated;
    * an expression compared with itself when it is a variable, field access or
      literal: `assert x == x` (also `===`, `>=`, `<=`), `refute x != x` (also `!==`, `<`, `>`);
    * `assert expr or true` / `expr || true` / `true or expr`;
    * match assertions whose pattern matches anything: `assert _ = f()`, `assert x = f()`.
      ExUnit still fails these when the value is `nil` or `false`, so they only prove
      truthiness; use a pattern that pins the shape. `assert token = f()` is **not**
      reported when `token` is used later in the same test: that is the common
      "assert present, and keep it" idiom, and the binding is the point;
    * `assert match?(_, f())` / `match?(var, f())`, which can never fail.

  This is an original implementation using synthetic examples; it shares a purpose
  with, but no source code from, other test-quality Credo packages.

  ## Limitations

  Syntactic. A variable counts as used when its name appears again anywhere in the
  same test body (shadowing is not tracked). Set `allow_binding_match: true` to skip
  every `assert var = expr`.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      file_suffixes: ["_test.exs"],
      test_macros: [:test],
      allow_binding_match: false
    ],
    explanations: [
      check: """
      An assertion that cannot fail proves nothing and gives false confidence. Assert on the value
      the code under test produced: `assert result == expected`, or a pattern that can fail.
      """,
      params: [
        file_suffixes: "Filename suffixes treated as test files.",
        test_macros: "Macros that define a test body.",
        allow_binding_match: "Do not report `assert var = expr` (a match that always succeeds)."
      ]
    ]

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Settings
  alias KogenCredo.CoreSupport.Tests

  @pure_ops [
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :and,
    :or,
    :not,
    :!,
    :&&,
    :||,
    :+,
    :-,
    :*,
    :<>,
    :in,
    :__block__
  ]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    suffixes =
      params
      |> Params.get(:file_suffixes, __MODULE__)
      |> Settings.strings!(:file_suffixes)

    if Tests.test_file?(filename, suffixes) do
      issue_meta = IssueMeta.for(source_file, params)
      allow_binding = Params.get(params, :allow_binding_match, __MODULE__)

      source_file
      |> SourceFile.ast()
      |> Tests.test_blocks(
        params
        |> Params.get(:test_macros, __MODULE__)
        |> Settings.atoms!(:test_macros)
      )
      |> Enum.flat_map(fn %{body: body} ->
        body
        |> Tests.assertions()
        |> Enum.flat_map(&vacuous(&1, allow_binding, body))
      end)
      |> Enum.map(fn {line, why} ->
        format_issue(issue_meta,
          message:
            "Vacuous assertion: #{why}. Assert on the actual result of the code under test.",
          trigger: "assert",
          line_no: line
        )
      end)
    else
      []
    end
  end

  defp vacuous({kind, [expr | _], meta}, allow_binding, body) when kind in [:assert, :refute] do
    case reason(kind, expr, allow_binding, body) do
      nil -> []
      why -> [{meta[:line], why}]
    end
  end

  defp vacuous(_, _, _), do: []

  defp reason(kind, expr, allow_binding, body) do
    text = Macro.to_string(expr)

    cond do
      constant_truth(expr) == (kind == :assert) and constant?(expr) ->
        "`#{text}` is constant"

      self_compare?(kind, expr) ->
        "`#{text}` compares a value with itself"

      kind == :assert ->
        assert_reason(text, expr, allow_binding, body)

      true ->
        nil
    end
  end

  defp assert_reason(text, expr, allow_binding, body) do
    cond do
      or_true?(expr) ->
        "`#{text}` is always true because of `or true`"

      not allow_binding and binds_anything?(expr) and not binding_used?(expr, body) ->
        "`#{text}` binds any value, so it only proves the value is truthy"

      match_anything?(expr) ->
        "`#{text}` matches any value"

      true ->
        nil
    end
  end

  # --- constant evaluation (literals and pure operators only) ---

  defp constant?(expr),
    do: Ast.walk(expr, true, fn node, ok -> ok and pure_node?(node) end) and not var_only?(expr)

  defp var_only?(expr), do: Ast.any_var?(expr)

  defp pure_node?({op, _, args}) when op in @pure_ops and is_list(args), do: true
  defp pure_node?({:__block__, _, _}), do: true
  defp pure_node?({_, _, _}), do: false
  defp pure_node?({a, b}), do: pure_node?(a) and pure_node?(b)
  defp pure_node?(lit) when is_atom(lit) or is_number(lit) or is_binary(lit), do: true
  defp pure_node?(list) when is_list(list), do: true
  defp pure_node?(_), do: false

  defp constant_truth(expr) do
    if constant?(expr) do
      try do
        {value, _} = Code.eval_quoted(expr)
        value not in [nil, false]
      rescue
        _ -> :unknown
      end
    else
      :unknown
    end
  end

  defp self_compare?(:assert, {op, _, [a, b]}) when op in [:==, :===, :>=, :<=],
    do: pure_operand?(a) and strip(a) == strip(b)

  defp self_compare?(:refute, {op, _, [a, b]}) when op in [:!=, :!==, :<, :>],
    do: pure_operand?(a) and strip(a) == strip(b)

  defp self_compare?(_, _), do: false

  defp pure_operand?({name, _, ctx}) when is_atom(name) and is_atom(ctx),
    do: Ast.var?({name, [], ctx})

  defp pure_operand?({{:., _, [inner, f]}, _, []}) when is_atom(f), do: pure_operand?(inner)
  defp pure_operand?(lit) when is_atom(lit) or is_number(lit) or is_binary(lit), do: true
  defp pure_operand?(_), do: false

  defp strip(ast),
    do:
      Macro.prewalk(ast, fn
        {a, _, c} -> {a, [], c}
        o -> o
      end)

  defp or_true?({op, _, [_, true]}) when op in [:or, :||], do: true
  defp or_true?({op, _, [true, _]}) when op in [:or, :||], do: true
  defp or_true?(_), do: false

  defp binds_anything?({:=, _, [pattern, _]}), do: wildcard_pattern?(pattern)
  defp binds_anything?(_), do: false

  # `assert var = expr` where `var` is read again later in the test keeps the value on purpose.
  defp binding_used?({:=, _, [{name, _, ctx}, _]}, body) when is_atom(name) and is_atom(ctx) do
    not Ast.prefixed?(name, "_") and
      Ast.walk(body, 0, fn
        {^name, _, c}, n when is_atom(c) -> n + 1
        _, n -> n
      end) > 1
  end

  defp binding_used?(_, _), do: false

  defp match_anything?({:match?, _, [pattern, _]}), do: wildcard_pattern?(pattern)
  defp match_anything?(_), do: false

  defp wildcard_pattern?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp wildcard_pattern?(_), do: false
end
