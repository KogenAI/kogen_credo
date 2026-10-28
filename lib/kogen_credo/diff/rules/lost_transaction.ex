defmodule KogenCredo.Diff.Rules.LostTransaction do
  @moduledoc """
  `lost-transaction`: the base wrapped its writes in `Repo.transaction` / `Repo.transact`
  (an `Ecto.Multi` is run through one of these), the head has none, and at least two repo
  writes (`insert`, `update`, `delete`, `insert_all`, ...) remain.

  The function and the same-module helpers it reaches are compared, so moving the transaction
  into a helper is quiet. The repo receiver is alias-aware.

  ## Limits

  A transaction moved to the caller or to another module, or `Ecto.Multi` steps whose
  `Repo.transaction` sits in a different function, cannot be tracked. Writes inside a
  `Multi.run` callback are counted only when they are written as repo calls. Advisory by
  default; no precision has been measured.
  """

  alias KogenCredo.Diff.Ast
  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding
  alias KogenCredo.SafetySupport

  @behaviour KogenCredo.Diff.Rule

  @min_writes 2

  @impl KogenCredo.Diff.Rule
  def id, do: "lost-transaction"

  @impl KogenCredo.Diff.Rule
  def default_severity, do: :advisory

  @impl KogenCredo.Diff.Rule
  def check(%Change{base: nil}, _), do: []

  def check(%Change{} = c, opts) do
    {b_tx, _} = counts(c, :base, opts)
    {h_tx, h_writes} = counts(c, :head, opts)

    if b_tx > 0 and h_tx == 0 and h_writes >= @min_writes do
      [
        Finding.for_change(
          id(),
          c,
          "The base ran its writes inside Repo.transaction; the head has #{h_writes} writes and " <>
            "no transaction, so a failure halfway leaves partial data. Wrap them again " <>
            "(Repo.transaction or Ecto.Multi) or confirm the caller does. Heuristic: callers " <>
            "and other modules are not followed."
        )
      ]
    else
      []
    end
  end

  defp counts(c, side, opts) do
    {clauses, module_fns, aliases} = Change.side(c, side)
    all = Ast.reachable(clauses, module_fns, Change.self_key(c, side))

    {Ast.repo_calls(all, aliases, opts, [:transaction, :transact]),
     Ast.repo_calls(all, aliases, opts, SafetySupport.repo_writes())}
  end
end
