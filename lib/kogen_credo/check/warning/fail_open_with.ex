defmodule KogenCredo.Check.Warning.FailOpenWith do
  @moduledoc """
  Flags control flow that turns an unknown failure into a success-shaped result.

  Shapes reported:

    * **Catch-all `with … else`**: a catch-all clause (`_ ->`, `other ->`) whose
      result is a success-shaped constant (`nil`, `[]`, `%{}`, `""`, a number, `:ok`,
      `true`, `false`, `{:ok, _}`), so any unexpected failure becomes a normal-looking
      value. Catch-alls returning an error tuple, `:error`, another tagged atom
      (`:unavailable`), another tagged tuple (`{:noreply, socket}`), the matched
      value, a function call (`send_resp(conn, 404, ...)`, `redirect(...)`: a
      translated response) or raising pass.
    * **Error to default in `with … else` / `case`**: a clause matching
      `{:error, reason}` with a variable or wildcard reason that returns a constant
      (`nil`, `[]`, `%{}`, `""`, `0`, `:ok`, `true`, `false`, `{:ok, constant}`).
      Literal reasons (`{:error, :enoent} -> :ok`) and bare `:error` are deliberate
      and pass, and so does `{:error, _} -> false` next to a clause that returns `true`
      (a boolean predicate such as `has_code_block?`, not a laundered default).
    * **Identity `else`**: every `else` clause just returns what it matched and at
      least one is a catch-all (`other -> other`), so the `else` can be deleted
      (`flag_identity_else`). An `else` made only of narrow identity clauses
      (`{:error, reason} -> {:error, reason}`) is a deliberate closed-world assertion
      (anything else raises `WithClauseError`) and passes.

  ## Limitations

  Syntactic only. `else _ -> nil` is sometimes a deliberate "not found"; the check
  cannot know. Constants returned through a variable or function call are not seen.
  Tune with `flag_case`, `flag_identity_else` and `included_paths`.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/"],
      excluded_paths: [],
      flag_case: true,
      flag_identity_else: true
    ],
    explanations: [
      check: """
      Let `with` return the non-matching value as-is (no `else`), or match the exact error
      shapes the clauses can produce and translate them. Never invent a result for a value you
      did not expect, and never let `{:error, reason}` become `nil`, `[]` or `:ok`: the caller
      cannot tell "nothing found" from "the read failed".
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped.",
        flag_case: "Also report `{:error, _} -> constant` clauses in plain `case` expressions.",
        flag_identity_else: "Report `else` blocks that only return what they matched."
      ]
    ]

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)

      opts = %{
        case?: Params.get(params, :flag_case, __MODULE__),
        identity?: Params.get(params, :flag_identity_else, __MODULE__)
      }

      source_file
      |> SourceFile.ast()
      |> Ast.walk([], &collect(&1, &2, issue_meta, opts))
      |> Enum.reverse()
    else
      []
    end
  end

  defp collect({:with, meta, args}, acc, issue_meta, opts) when is_list(args) and args != [] do
    case List.last(args) do
      kw when is_list(kw) ->
        ok =
          kw
          |> Keyword.get(:do)
          |> do_last()

        with_issues(Keyword.get(kw, :else), ok, meta, issue_meta, opts) ++ acc

      _ ->
        acc
    end
  end

  defp collect({:case, _, [_, [do: clauses]]}, acc, issue_meta, opts) when is_list(clauses),
    do: case_issues(clauses, acc, issue_meta, opts)

  defp collect({:|>, _, [_, {:case, _, [[do: clauses]]}]}, acc, issue_meta, opts)
       when is_list(clauses),
       do: case_issues(clauses, acc, issue_meta, opts)

  defp collect(_, acc, _, _), do: acc

  defp case_issues(clauses, acc, issue_meta, %{case?: true}),
    do: error_default_issues(clauses, issue_meta) ++ acc

  defp case_issues(_, acc, _, _), do: acc

  defp do_last(nil), do: nil
  defp do_last(body), do: Ast.last_expr(body)

  defp with_issues(clauses, ok, meta, issue_meta, opts) when is_list(clauses) do
    arrows = for {:->, _, [[pat], body]} <- clauses, do: {pat, body}

    cond do
      identity_else?(arrows) ->
        identity_issues(issue_meta, meta, opts)

      Enum.any?(arrows, &fail_open_catch_all?(&1, ok)) ->
        [fail_open_issue(issue_meta, meta)]

      true ->
        error_default_issues(clauses, issue_meta)
    end
  end

  defp with_issues(_, _, _, _, _), do: []

  defp identity_else?(arrows) do
    arrows != [] and Enum.all?(arrows, &identity?/1) and Enum.any?(arrows, &catch_all_identity?/1)
  end

  defp identity_issues(issue_meta, meta, %{identity?: true}) do
    [
      issue(
        issue_meta,
        meta[:line],
        "`else` only returns what it matched; delete the `else` block",
        "with"
      )
    ]
  end

  defp identity_issues(_, _, _), do: []

  defp fail_open_issue(issue_meta, meta) do
    issue(
      issue_meta,
      meta[:line],
      "catch-all `else` clause turns any unexpected value into a non-error result (fail-open); " <>
        "match the real error shapes or drop `else`",
      "with"
    )
  end

  defp error_default_issues(clauses, issue_meta) do
    predicate? = Enum.any?(clauses, fn {:->, _, [_, body]} -> Ast.last_expr(body) == true end)

    for {:->, meta, [[pattern], body]} <- clauses,
        error_pattern?(unguard(pattern)),
        default?(Ast.last_expr(body)),
        not (predicate? and Ast.last_expr(body) == false) do
      issue(
        issue_meta,
        meta[:line],
        "an error is converted into a success-shaped default (`#{Macro.to_string(Ast.last_expr(body))}`); " <>
          "return or translate `{:error, reason}` so the caller cannot mistake a failure for an empty result",
        "->"
      )
    end
  end

  # `{:error, reason}` / `{:error, _}`: a variable or wildcard reason. Literal reasons are deliberate.
  defp error_pattern?({:error, {name, _, ctx}}) when is_atom(name) and is_atom(ctx), do: true
  defp error_pattern?({:=, _, [a, b]}), do: error_pattern?(a) or error_pattern?(b)
  defp error_pattern?(_), do: false

  defp identity?({{n, _, c}, {n, _, c2}}) when is_atom(n) and is_atom(c) and is_atom(c2), do: true
  defp identity?({{:=, _, [_, {n, _, c}]}, {n, _, c2}}) when is_atom(c) and is_atom(c2), do: true
  defp identity?({{:=, _, [{n, _, c}, _]}, {n, _, c2}}) when is_atom(c) and is_atom(c2), do: true

  defp identity?({{:error, {r, _, c}}, {:error, {r, _, c2}}}) when is_atom(c) and is_atom(c2),
    do: true

  defp identity?({p, p2}) when is_atom(p) and p == p2, do: true
  defp identity?(_), do: false

  defp fail_open_catch_all?({pat, body}, ok) do
    last = Ast.last_expr(body)

    catch_all?(pat) and not identity?({pat, last}) and success_shaped?(last) and
      not (last == false and ok == true)
  end

  defp catch_all_identity?({pat, _}), do: catch_all?(pat)

  # Only a constant that looks like a normal result is fail-open; tagged atoms/tuples and
  # function calls are explicit outcomes or translated responses this check cannot judge.
  defp success_shaped?({:ok, _}), do: true
  defp success_shaped?({:{}, _, [:ok | _]}), do: true
  defp success_shaped?(last), do: default?(last)

  defp unguard({:when, _, [pattern | _]}), do: pattern
  defp unguard(pattern), do: pattern

  defp catch_all?({n, _, c}) when is_atom(n) and is_atom(c), do: true
  defp catch_all?(_), do: false

  defp default?(b) when b in [nil, true, false, :ok, [], ""] or is_number(b), do: true
  defp default?({:%{}, _, []}), do: true
  defp default?({:ok, x}), do: default?(x)
  defp default?(_), do: false

  defp issue(issue_meta, line, msg, trigger),
    do:
      format_issue(issue_meta,
        message: "Fail-open: " <> msg <> ".",
        trigger: trigger,
        line_no: line
      )
end
