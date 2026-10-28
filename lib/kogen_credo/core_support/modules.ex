defmodule KogenCredo.CoreSupport.Modules do
  @moduledoc """
  Module-name scoping: removes the bodies of modules that a check is configured to
  skip (for example codec modules), resolving nested `defmodule` names.
  """

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Settings

  @doc """
  Returns `ast` with the body of every `defmodule` whose full name equals or lies
  under one of `skip` emptied out, so a later walk ignores it.

  `skip` lists module references: atoms (`MyApp.Codec`) or names (`"MyApp.Codec"`). They are
  compared by name, so a module that does not exist in the running VM prunes like any other.
  """
  @spec prune(Macro.t(), [module() | Ast.module_name()]) :: Macro.t()
  def prune(ast, []), do: ast

  def prune(ast, skip) do
    prefixes = Enum.map(skip, &prefix!/1)

    {ast, _} =
      Macro.traverse(
        ast,
        [],
        fn
          {:defmodule, meta, [name | _]} = node, stack ->
            full = full_name(name, stack)
            stack = [full | stack]

            if skipped?(full, prefixes),
              do: {{:defmodule, meta, [name]}, stack},
              else: {node, stack}

          node, stack ->
            {node, stack}
        end,
        fn
          {:defmodule, _, _} = node, [_ | stack] -> {node, stack}
          node, stack -> {node, stack}
        end
      )

    ast
  end

  defp prefix!(module) do
    Settings.module_name(module) ||
      raise ArgumentError, "module prefixes must be atoms or names, got: #{inspect(module)}"
  end

  # Elixir semantics: `defmodule Inner` nested in `Outer` is `Outer.Inner`, and so is a
  # nested `defmodule Outer.Inner`'s `Outer.Outer.Inner` (no deduplication).
  defp full_name({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, [parent | _]) do
    if is_binary(parent) and Enum.all?(rest, &is_atom/1),
      do: Ast.join_name([parent | rest])
  end

  defp full_name({:__aliases__, _, parts}, stack) do
    if Enum.all?(parts, &is_atom/1) do
      case stack do
        [] -> Ast.join_name(parts)
        [nil | _] -> nil
        [parent | _] -> Ast.join_name([parent | parts])
      end
    end
  end

  defp full_name(_, _), do: nil

  defp skipped?(nil, _), do: false

  defp skipped?(full, prefixes) do
    Enum.any?(prefixes, &Ast.under_name?(full, &1))
  end
end
