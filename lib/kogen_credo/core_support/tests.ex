defmodule KogenCredo.CoreSupport.Tests do
  @moduledoc """
  ExUnit-source helpers shared by the test-quality checks.

  A *test block* is a `test "name" do ... end` call; an *assertion* is a call to
  `assert`, `refute`, `assert_*` or `refute_*`. This is purely name-based.
  """

  alias KogenCredo.CoreSupport.Ast

  @doc "True when the filename ends with one of the suffixes (default test file suffix is `_test.exs`)."
  @spec test_file?(String.t(), [String.t()]) :: boolean()
  def test_file?(filename, suffixes), do: Enum.any?(suffixes, &String.ends_with?(filename, &1))

  @doc "All `test` blocks with a body, as `%{name: ast, meta: keyword, body: ast}`."
  @spec test_blocks(Macro.t(), [atom()]) :: [map()]
  def test_blocks(ast, macros \\ [:test]) do
    ast
    |> Ast.walk([], &collect_test(&1, &2, macros))
    |> Enum.reverse()
  end

  defp collect_test({macro, meta, [name | rest]}, acc, macros)
       when is_atom(macro) and is_list(rest) and rest != [] do
    with true <- macro in macros,
         body when body != nil <- do_body(List.last(rest)) do
      [%{name: name, meta: meta, body: body} | acc]
    else
      _ -> acc
    end
  end

  defp collect_test(_, acc, _), do: acc

  defp do_body(kw) when is_list(kw), do: Keyword.get(kw, :do)
  defp do_body(_), do: nil

  @doc "Assertion calls in the AST as `{name, args, meta}`."
  @spec assertions(Macro.t()) :: [{atom(), [Macro.t()], keyword()}]
  def assertions(ast) do
    ast
    |> Ast.expand_pipes()
    |> Ast.walk([], fn
      {name, meta, args}, acc when is_atom(name) and is_list(args) ->
        if assertion_name?(name), do: [{name, args, meta} | acc], else: acc

      _, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  @doc "Name-based assertion test."
  @spec assertion_name?(atom()) :: boolean()
  def assertion_name?(name) do
    s = Atom.to_string(name)

    s in ["assert", "refute"] or String.starts_with?(s, "assert_") or
      String.starts_with?(s, "refute_")
  end

  @doc "Unwraps a trailing `{:__block__, _, [expr]}`."
  @spec unwrap(Macro.t()) :: Macro.t()
  def unwrap({:__block__, _, [one]}), do: one
  def unwrap(other), do: other
end
