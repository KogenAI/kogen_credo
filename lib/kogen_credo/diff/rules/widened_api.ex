defmodule KogenCredo.Diff.Rules.WidenedApi do
  @moduledoc """
  `widened-api`: a function became public (`defp` to `def`), or a new public function appeared
  in a module that already existed.

  Skipped: functions preceded by `@impl` (callbacks), and everything in a module that has no
  function at the base (a new module or file is a new API, not a widening). Whether a new `def`
  has a caller is not checked here; pair it with `mix kogen.unused_public`.

  ## Limits

  Callbacks implemented without `@impl`, public functions required by a framework convention
  (`changeset/2`, `child_spec/1`, controller actions) and macro-defined functions are flagged or
  invisible accordingly. Always advisory in practice: widening is a fact, harm is a judgement.
  """

  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding

  @behaviour KogenCredo.Diff.Rule

  @impl KogenCredo.Diff.Rule
  def id, do: "widened-api"

  @impl KogenCredo.Diff.Rule
  def default_severity, do: :advisory

  @impl KogenCredo.Diff.Rule
  def check(%Change{module_new: true}, _), do: []
  def check(%Change{impl: true}, _), do: []

  def check(%Change{base: nil, head_kind: :def} = c, _),
    do: [
      Finding.for_change(
        id(),
        c,
        "New public function in an existing module. Make it `defp` unless another module calls it."
      )
    ]

  def check(%Change{base_kind: :defp, head_kind: :def} = c, _),
    do: [
      Finding.for_change(
        id(),
        c,
        "Function widened from `defp` to `def`. Keep it private unless another module needs it."
      )
    ]

  def check(_, _), do: []
end
