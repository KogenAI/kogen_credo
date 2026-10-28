defmodule KogenCredo.Diff.Change do
  @moduledoc """
  One changed function: its base clauses (`nil` when the function is new) and its head clauses.

  `base_module` and `head_module` map `{name, arity}` to the clauses of every function of the
  enclosing module, so rules can follow local helper calls. `base_aliases` and `head_aliases` are
  the alias maps of each file (see `KogenCredo.SafetySupport.aliases/1`). `base_kind` and
  `head_kind` are `:def` or `:defp`. `module_new` is true when the module has no function at all
  in the base (a new module or a new file). `impl` is true when the function is preceded by
  `@impl` in the head. `module` is the enclosing module's *name* (`"MyApp.Search"`, see
  `t:KogenCredo.CoreSupport.Ast.module_name/0`); no module atom is created for the analysed code.
  """

  @enforce_keys [:file, :module, :name, :arity, :line, :head, :head_module]
  defstruct [
    :file,
    :module,
    :name,
    :arity,
    :line,
    :base,
    :head,
    :base_module,
    :head_module,
    :base_kind,
    :head_kind,
    :base_arity,
    base_aliases: %{},
    head_aliases: %{},
    module_new: false,
    impl: false
  ]

  @type t :: %__MODULE__{}

  @doc "Display name such as `MyApp.Search.history/2`."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{} = c), do: "#{c.module}.#{c.name}/#{c.arity}"

  @doc """
  `{name, arity}` of the function on one side. The base arity differs from the head arity when
  a parameter was added or removed.
  """
  @spec self_key(t(), :base | :head) :: {atom(), arity()}
  def self_key(%__MODULE__{} = c, :base), do: {c.name, c.base_arity || c.arity}
  def self_key(%__MODULE__{} = c, :head), do: {c.name, c.arity}

  @doc "Clauses, module function map and aliases of one side (`:base` or `:head`)."
  @spec side(t(), :base | :head) :: {[Macro.t()], map(), map()}
  def side(%__MODULE__{} = c, :base), do: {c.base || [], c.base_module || %{}, c.base_aliases}
  def side(%__MODULE__{} = c, :head), do: {c.head, c.head_module || %{}, c.head_aliases}
end
