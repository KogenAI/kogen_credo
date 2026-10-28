defmodule KogenCredo.Diff.Rules.NewSilentFallback do
  @moduledoc """
  `new-silent-fallback`: the head has more silent catch-all handlers than the base.

  A silent fallback is, with no logging or re-raise:

    * a clause of `case`, `with ... else`, `receive`, `try ... else/catch` whose pattern is a
      catch-all (`_`, `_reason`, a variable the body does not use, or `{:error, <catch-all>}`)
      and whose body is only a literal `:ok`, `nil`, `[]`, `%{}`, `""`, `false`, `{:ok, nil}`,
      `{:ok, []}` or `{:ok, %{}}`;
    * a `rescue` clause that binds nothing it uses and returns such a literal;
    * an added function clause whose parameters are all `_` and whose body is such a literal,
      in a function with more than one clause.

  A single-clause `def f(_), do: nil` and `fn _ -> :ok end` are not counted. New functions are
  compared with zero. Bodies with any other expression (a `Logger` call, `raise`, ...) are not
  silent.

  ## Limits

  Purely syntactic: a documented, intended `_ -> nil` is flagged the same. Fallbacks that return
  a non-literal default are not seen. Advisory by default; no precision has been measured.
  """

  alias KogenCredo.Diff.Ast
  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding

  @behaviour KogenCredo.Diff.Rule

  @impl KogenCredo.Diff.Rule
  def id, do: "new-silent-fallback"

  @impl KogenCredo.Diff.Rule
  def default_severity, do: :advisory

  @impl KogenCredo.Diff.Rule
  def check(%Change{} = c, _) do
    base = if c.base, do: silent_count(c.base), else: 0
    head = silent_count(c.head)

    if head > base do
      [
        Finding.for_change(
          id(),
          c,
          "#{head - base} new catch-all clause(s) return a literal (:ok/nil/[]/...) without " <>
            "logging or re-raising, so an unexpected result disappears silently. Match the " <>
            "expected shapes only, or log/raise in the fallback."
        )
      ]
    else
      []
    end
  end

  defp silent_count(clauses) do
    {_, n} =
      Macro.prewalk(clauses, 0, fn
        {key, arrows} = node, n when key in [:do, :else, :rescue, :catch] and is_list(arrows) ->
          {node, n + Enum.count(arrows, &silent_arrow?(&1, key))}

        node, n ->
          {node, n}
      end)

    n + function_level(clauses)
  end

  defp silent_arrow?({:->, _, [patterns, body]}, key) when is_list(patterns) and patterns != [] do
    Enum.all?(patterns, &catch_all?(&1, body, key)) and silent_body?(body)
  end

  defp silent_arrow?(_, _), do: false

  defp catch_all?({:when, _, _}, _, _), do: false
  defp catch_all?({:error, pattern}, body, _), do: bare_var?(pattern, body)
  defp catch_all?({:{}, _, [:error, pattern]}, body, _), do: bare_var?(pattern, body)
  defp catch_all?(pattern, body, _), do: bare_var?(pattern, body)

  defp bare_var?({name, _, ctx}, body) when is_atom(name) and is_atom(ctx) do
    underscored?(name) or not uses_var?(body, name)
  end

  defp bare_var?(_, _), do: false

  defp underscored?(name) do
    text = Atom.to_string(name)
    String.starts_with?(text, "_")
  end

  defp uses_var?(body, name),
    do: Ast.count(body, &match?({^name, _, ctx} when is_atom(ctx), &1)) > 0

  defp silent_body?(body) do
    case Ast.unblock(body) do
      lit when lit in [:ok, nil, [], "", false] -> true
      {:%{}, _, []} -> true
      {:ok, inner} -> inner in [nil, []] or match?({:%{}, _, []}, inner)
      _ -> false
    end
  end

  defp function_level(clauses) when length(clauses) < 2, do: 0

  defp function_level(clauses) do
    Enum.count(clauses, fn
      {kind, _, [{name, _, [_ | _] = params}, [do: body]]}
      when kind in [:def, :defp] and is_atom(name) ->
        Enum.all?(params, &wildcard?/1) and silent_body?(body)

      _ ->
        false
    end)
  end

  defp wildcard?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    name
    |> Atom.to_string()
    |> String.starts_with?("_")
  end

  defp wildcard?(_), do: false
end
