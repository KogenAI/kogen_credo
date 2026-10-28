defmodule KogenCredo.Diff.Rules.ChangesetWeakened do
  @moduledoc """
  `changeset-weakened`: a changed function lost validations or gained a sensitive `cast` field.

  Reported when, comparing the function plus the same-module helpers it reaches:

    * a `validate_*` or `*_constraint` call (for example `validate_length`, `unique_constraint`)
      present at the base for a field is gone at the head, including a field dropped from the
      list of `validate_required`;
    * a field in option `:cast_sensitive_fields` (default `[:is_admin, :admin, :role, :user_id,
      :tenant_id, :account_id, :organization_id, :owner_id, :confirmed_at, :password_hash]`)
      was added to a `cast` list.

  Calls are keyed by name and literal field atoms, so changing a validator's options is not
  noticed, and a local validator call without field atoms is keyed by name only.

  ## Limits

  Validation moved to another module, fields cast through a module attribute or variable, and
  `validate_change`/custom validators that are renamed are invisible or look like a loss. The
  fact is reported, intent decides. Advisory by default; no precision has been measured.
  """

  alias KogenCredo.Diff.Ast
  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding
  alias KogenCredo.QuerySupport

  @behaviour KogenCredo.Diff.Rule

  @default_cast_sensitive [
    :is_admin,
    :admin,
    :role,
    :user_id,
    :tenant_id,
    :account_id,
    :organization_id,
    :owner_id,
    :confirmed_at,
    :password_hash
  ]

  @impl KogenCredo.Diff.Rule
  def id, do: "changeset-weakened"

  @impl KogenCredo.Diff.Rule
  def default_severity, do: :advisory

  @impl KogenCredo.Diff.Rule
  def check(%Change{base: nil}, _), do: []

  def check(%Change{} = c, opts) do
    sensitive =
      opts
      |> Keyword.get(:cast_sensitive_fields, @default_cast_sensitive)
      |> QuerySupport.names()

    {base_checks, base_cast} = facts(c, :base)
    {head_checks, head_cast} = facts(c, :head)

    lost =
      base_checks
      |> MapSet.difference(head_checks)
      |> Enum.sort()

    added =
      head_cast
      |> MapSet.difference(base_cast)
      |> Enum.filter(&QuerySupport.listed?(&1, sensitive))
      |> Enum.sort()

    problems =
      Enum.map(lost, fn {fun, field} -> "removed #{fun}(#{describe(field)})" end) ++
        Enum.map(added, &"added #{inspect(&1)} to cast")

    if problems == [] do
      []
    else
      [
        Finding.for_change(
          id(),
          c,
          "Changeset weakened: #{Enum.join(problems, "; ")}. Confirm the validation is enforced " <>
            "elsewhere, or restore it. Heuristic: validators moved to other modules look lost."
        )
      ]
    end
  end

  defp describe(:*), do: "..."
  defp describe(field), do: inspect(field)

  defp facts(c, side) do
    {clauses, module_fns, _} = Change.side(c, side)

    bodies =
      clauses
      |> Ast.reachable(module_fns, Change.self_key(c, side))
      |> Ast.bodies()

    {_, {checks, cast}} = Macro.prewalk(bodies, {MapSet.new(), MapSet.new()}, &collect_fact/2)
    {checks, cast}
  end

  defp collect_fact(node, {checks, cast} = acc) do
    case call(node) do
      {:cast, args} ->
        {node, {checks, MapSet.union(cast, MapSet.new(atom_lists(args)))}}

      {name, args} ->
        if check_name?(name),
          do: {node, {add_checks(checks, name, args), cast}},
          else: {node, acc}

      nil ->
        {node, acc}
    end
  end

  defp call({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}

  defp call({{:., _, [_, name]}, _, args}) when is_atom(name) and is_list(args),
    do: {name, args}

  defp call(_), do: nil

  defp check_name?(name) do
    s = Atom.to_string(name)
    String.starts_with?(s, "validate_") or String.ends_with?(s, "_constraint")
  end

  defp add_checks(set, name, args) do
    case args
         |> Enum.take(2)
         |> Enum.find_value(&field_atoms/1) do
      nil -> MapSet.put(set, {name, :*})
      fields -> Enum.reduce(fields, set, &MapSet.put(&2, {name, &1}))
    end
  end

  defp field_atoms(atom) when is_atom(atom) and atom not in [nil, true, false], do: [atom]

  defp field_atoms(list) when is_list(list) and list != [] do
    if Enum.all?(list, &(is_atom(&1) and &1 not in [nil, true, false])), do: list
  end

  defp field_atoms(_), do: nil

  # Atom lists among the arguments of `cast` (the permitted fields).
  defp atom_lists(args),
    do:
      args
      |> Enum.map(&field_atoms/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.concat()
      |> only_lists(args)

  defp only_lists(fields, args) do
    if Enum.any?(args, &is_list/1), do: fields, else: []
  end
end
