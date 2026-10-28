defmodule KogenCredo.CoreSupport.Aliases do
  @moduledoc """
  File-level alias resolution.

  `build/1` collects every `alias` in a file (including `as:` and multi-alias
  forms), ignoring lexical scope: an alias declared in one function is treated as
  visible in the whole file. Checks that need real scoping (an alias declared in one
  function or module must not leak into another) use
  `KogenCredo.CoreSupport.Scope.walk/3`, which hands each node the `aliases` map in
  force there; `resolve/2` works with either.
  """

  alias KogenCredo.CoreSupport.Ast

  @typedoc "Short alias name => module name; `:__MODULE__` carries the enclosing module's name."
  @type t :: %{atom() => Ast.module_name()}

  @doc "Collects `alias` declarations of a file as a map from short name to module name."
  @spec build(Macro.t()) :: t()
  def build(ast), do: Ast.walk(ast, %{}, &alias_step/2)

  defp alias_step({:alias, _, [{:__aliases__, _, parts}, opts]}, acc) when is_list(opts) do
    case {Ast.module_name({:__aliases__, [], parts}), opts[:as]} do
      {nil, _} -> acc
      {mod, {:__aliases__, _, [short]}} -> Map.put(acc, short, mod)
      {_, _} -> acc
    end
  end

  defp alias_step({:alias, _, [{:__aliases__, _, parts}]}, acc), do: put_module(acc, parts, parts)

  defp alias_step({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}, acc),
    do: Enum.reduce(children, acc, &child_alias(&1, &2, base))

  defp alias_step(_, acc), do: acc

  defp child_alias({:__aliases__, _, rest}, acc, base), do: put_module(acc, base ++ rest, rest)
  defp child_alias(_, acc, _), do: acc

  defp put_module(acc, parts, key_parts) do
    case Ast.module_name({:__aliases__, [], parts}) do
      nil -> acc
      mod -> Map.put(acc, List.last(key_parts), mod)
    end
  end

  @doc """
  Resolves a module node using the file aliases.

  Returns the fully-qualified module name (`"MyApp.Repo"`) for `{:__aliases__, ...}` nodes
  (first segment expanded through `aliases`) and the colon form (`":rand"`) for Erlang modules;
  `nil` for anything dynamic. No atom is created, so modules that are not loaded (or do not
  exist) resolve like any other. `__MODULE__` resolves when the map carries the enclosing
  module under the `:__MODULE__` key (as `Scope.walk/3` provides).
  """
  @spec resolve(Macro.t(), t()) :: Ast.module_name() | nil
  def resolve({:__aliases__, _, [{:__MODULE__, _, ctx} | rest]}, aliases) when is_atom(ctx) do
    with %{__MODULE__: current} <- aliases, true <- Enum.all?(rest, &is_atom/1) do
      Ast.join_name([current | rest])
    else
      _ -> nil
    end
  end

  def resolve({:__MODULE__, _, ctx}, aliases) when is_atom(ctx), do: Map.get(aliases, :__MODULE__)

  def resolve({:__aliases__, _, [first | rest]}, aliases) when is_atom(first) do
    if Enum.all?(rest, &is_atom/1) do
      case aliases do
        %{^first => name} -> Ast.join_name([name | rest])
        _ -> Ast.join_name([first | rest])
      end
    end
  end

  def resolve(atom, _) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: Ast.atom_name(atom)

  def resolve(_, _), do: nil

  @doc "Locally defined function names with arities, used to avoid mistaking local functions for imports."
  @spec local_functions(Macro.t()) :: MapSet.t({atom(), non_neg_integer()})
  def local_functions(ast), do: Ast.walk(ast, MapSet.new(), &local_step/2)

  defp local_step({kind, _, [head | _]}, acc) when kind in [:def, :defp, :defmacro, :defmacrop],
    do: put_local(acc, head)

  defp local_step(_, acc), do: acc

  defp put_local(acc, {:when, _, [{name, _, args} | _]}) when is_atom(name),
    do: MapSet.put(acc, {name, arity(args)})

  defp put_local(acc, {name, _, args}) when is_atom(name),
    do: MapSet.put(acc, {name, arity(args)})

  defp put_local(acc, _), do: acc

  defp arity(args) when is_list(args), do: length(args)
  defp arity(_), do: 0
end
