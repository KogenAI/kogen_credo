defmodule KogenCredo.Diff.Rules.QueryLostScope do
  @moduledoc """
  `query-lost-scope`: a changed function that still builds or runs a query compares a configured
  scope field (an owner or tenant id) fewer times than at the base.

  Option `:sensitive_fields` (default `[:user_id, :tenant_id, :account_id, :organization_id]`)
  lists the fields. A comparison is `x.field == ...`, `x.field in ...`, `field(x, :field) == ...`
  or a keyword pair such as `where: [user_id: ^id]` / `Repo.get_by(Post, user_id: id)`. Maps and
  structs (patterns, literals) and function heads are ignored. Counts include same-module
  helpers the function reaches, so extracting the scope into a helper is quiet.

  ## Limits

  Purely a count per field: scope enforced by another module, a policy layer or a
  `Ecto.Query.where` hidden in a variable is invisible, and replacing one comparison by a
  different one on the same field is not noticed. When the function lost repo reads altogether
  the rule stays quiet. Advisory by default; no precision has been measured.
  """

  alias KogenCredo.Diff.Ast
  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding
  alias KogenCredo.QuerySupport
  alias KogenCredo.SafetySupport

  @behaviour KogenCredo.Diff.Rule

  @default_fields [:user_id, :tenant_id, :account_id, :organization_id]
  @query_macros [:from, :where, :join, :dynamic]

  @impl KogenCredo.Diff.Rule
  def id, do: "query-lost-scope"

  @impl KogenCredo.Diff.Rule
  def default_severity, do: :advisory

  @impl KogenCredo.Diff.Rule
  def check(%Change{base: nil}, _), do: []

  def check(%Change{} = c, opts) do
    fields =
      opts
      |> Keyword.get(:sensitive_fields, @default_fields)
      |> QuerySupport.names()

    {base, b_reads} = scope(c, :base, fields, opts)
    {head, h_reads} = scope(c, :head, fields, opts)

    lost = for f <- fields, Map.get(base, f, 0) > Map.get(head, f, 0), do: f

    if lost != [] and h_reads >= b_reads and query_shaped?(c, opts),
      do: [lost_scope_finding(c, lost, base, head)],
      else: []
  end

  defp lost_scope_finding(c, lost, base, head) do
    detail =
      Enum.map_join(lost, ", ", fn f ->
        "#{QuerySupport.atom_label(f)} (#{Map.get(base, f, 0)} -> #{Map.get(head, f, 0)})"
      end)

    Finding.for_change(
      id(),
      c,
      "The query no longer compares #{detail} as often as before; a lost owner/tenant " <>
        "scope can expose other users' rows. Restore the comparison or confirm it moved " <>
        "to a scope helper in another module (not tracked)."
    )
  end

  defp scope(c, side, fields, opts) do
    {clauses, module_fns, aliases} = Change.side(c, side)
    all = Ast.reachable(clauses, module_fns, Change.self_key(c, side))

    counts =
      all
      |> Ast.bodies()
      |> Enum.reduce(%{}, fn body, acc -> Ast.reduce(body, acc, &visit(&1, &2, fields)) end)

    {counts, Ast.repo_calls(all, aliases, opts, SafetySupport.repo_reads())}
  end

  defp visit({:%{}, _, _}, acc, _), do: {:skip, acc}
  defp visit({:%, _, _}, acc, _), do: {:skip, acc}

  defp visit({op, _, [a, b]}, acc, fields) when op in [:==, :in] do
    case Enum.find_value([a, b], &field_ref(&1, fields)) do
      nil -> {:cont, acc}
      f -> {:cont, Map.update(acc, f, 1, &(&1 + 1))}
    end
  end

  defp visit({f, _}, acc, fields) when is_atom(f) do
    name = Atom.to_string(f)
    if name in fields, do: {:cont, Map.update(acc, name, 1, &(&1 + 1))}, else: {:cont, acc}
  end

  defp visit(_, acc, _), do: {:cont, acc}

  defp field_ref({{:., _, [_, f]}, _, []}, fields) when is_atom(f), do: field_name(f, fields)
  defp field_ref({:field, _, [_, f]}, fields) when is_atom(f), do: field_name(f, fields)
  defp field_ref(_, _), do: nil

  # Fields are compared by name: `--sensitive-field` values and atoms in options both work, and
  # a field the code never mentions needs no atom.
  defp field_name(f, fields) do
    name = Atom.to_string(f)
    if name in fields, do: name
  end

  defp query_shaped?(c, opts) do
    Ast.count(c.head, fn
      {name, _, args} when name in @query_macros and is_list(args) -> true
      node -> SafetySupport.repo_call(node, c.head_aliases, opts) != nil
    end) > 0
  end
end
