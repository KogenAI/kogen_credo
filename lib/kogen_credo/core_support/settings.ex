defmodule KogenCredo.CoreSupport.Settings do
  @moduledoc """
  Strict parameter validation for checks.

  A mistyped threshold (`"400"`), a bare string where a path list is expected or a
  module given as a string must stop the run with an `ArgumentError`; silently
  treating it as "nothing configured" would look like a green run.
  """

  alias KogenCredo.CoreSupport.Ast

  @doc "Fetches `key` and requires an integer `>= min`."
  @spec integer!(term(), atom(), integer()) :: integer()
  def integer!(value, key, min \\ 0) do
    if is_integer(value) and value >= min,
      do: value,
      else: raise_bad(key, value, "an integer >= #{min}")
  end

  @doc "Requires a list of atoms (modules or names)."
  @spec atoms!(term(), atom()) :: [atom()]
  def atoms!(value, key) do
    if is_list(value) and Enum.all?(value, &(is_atom(&1) and &1 != nil)),
      do: value,
      else: raise_bad(key, value, "a list of atoms")
  end

  @doc """
  Requires a list of module atoms (`MyApp.Codec`, `:ets`) and returns their names.

  Configuration names modules with atoms, and a string is still rejected (a mistyped list must
  not look like "nothing configured"). The atoms are only read: they come from the config, never
  from the analysed code, and the result is compared by name (see `t:Ast.module_name/0`).
  """
  @spec modules!(term(), atom()) :: [Ast.module_name()]
  def modules!(value, key) do
    if is_list(value) and Enum.all?(value, &(is_atom(&1) and &1 != nil)),
      do: Enum.map(value, &Ast.atom_name/1),
      else: raise_bad(key, value, "a list of atoms")
  end

  @doc """
  The name of one module reference given as an atom (`MyApp.Codec`, `:ets`) or as a string
  (`"MyApp.Codec"`, `"Elixir.MyApp.Codec"`, `":ets"`), or `nil` when it is neither. For helpers
  that take either form; check parameters go through `modules!/2`.
  """
  @spec module_name(term()) :: Ast.module_name() | nil
  def module_name(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Ast.atom_name(atom)

  def module_name("Elixir." <> name) when name != "", do: name
  def module_name(name) when is_binary(name) and name != "", do: name
  def module_name(_), do: nil

  @doc "Requires a list of binaries."
  @spec strings!(term(), atom()) :: [String.t()]
  def strings!(value, key) do
    if is_list(value) and Enum.all?(value, &is_binary/1),
      do: value,
      else: raise_bad(key, value, "a list of strings")
  end

  @doc "Requires a keyword list or map with only the allowed keys."
  @spec known_keys!(term(), [atom()], String.t()) :: term()
  def known_keys!(entry, allowed, what) do
    keys =
      cond do
        is_map(entry) ->
          Map.keys(entry)

        Keyword.keyword?(entry) ->
          Keyword.keys(entry)

        true ->
          raise ArgumentError, "#{what} must be a keyword list or map, got: #{inspect(entry)}"
      end

    case keys -- allowed do
      [] ->
        entry

      unknown ->
        raise ArgumentError,
              "#{what} has unknown keys #{inspect(unknown)} (allowed: #{inspect(allowed)}), got: #{inspect(entry)}"
    end
  end

  @spec raise_bad(atom(), term(), String.t()) :: no_return()
  def raise_bad(key, value, expected),
    do: raise(ArgumentError, "#{inspect(key)} must be #{expected}, got: #{inspect(value)}")
end
