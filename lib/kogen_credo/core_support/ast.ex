defmodule KogenCredo.CoreSupport.Ast do
  @moduledoc """
  AST helpers shared by the KogenCredo checks.

  Everything here is syntactic: no compilation, no type information.
  """

  @doc "True for a plain variable node that is not underscore-prefixed or a `__MODULE__`-style form."
  @spec var?(Macro.t()) :: boolean()
  def var?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: not prefixed?(name, "_")

  def var?(_), do: false

  @doc "True for any variable node, including `_` and `_name`."
  @spec any_var?(Macro.t()) :: boolean()
  def any_var?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: not prefixed?(name, "__")

  def any_var?(_), do: false

  @doc "True when the atom's text starts with `prefix` (e.g. `_ignored` with `\"_\"`)."
  @spec prefixed?(atom(), String.t()) :: boolean()
  def prefixed?(name, prefix) when is_atom(name) do
    text = Atom.to_string(name)
    String.starts_with?(text, prefix)
  end

  @doc "Depth-first accumulate over every node."
  @spec walk(Macro.t(), acc, (Macro.t(), acc -> acc)) :: acc when acc: term()
  def walk(ast, acc, fun) do
    ast
    |> Macro.prewalk(acc, fn node, a -> {node, fun.(node, a)} end)
    |> elem(1)
  end

  @doc "Rewrites `a |> f(b)` into `f(a, b)` everywhere so arities and argument positions are real."
  @spec expand_pipes(Macro.t()) :: Macro.t()
  def expand_pipes(ast), do: Macro.prewalk(ast, &expand_pipe/1)

  defp expand_pipe({:|>, _, [left, {{:., _, _} = dot, meta, args}]}) when is_list(args),
    do: {dot, meta, [left | args]}

  defp expand_pipe({:|>, _, [left, {name, meta, args}]}) when is_atom(name) and is_list(args),
    do: {name, meta, [left | args]}

  defp expand_pipe(node), do: node

  @doc "Parses a `def`/`defp` clause into `{:ok, {kind, name, args, guard, body, meta}}` or `:error`."
  @spec def_clause(Macro.t()) :: {:ok, tuple()} | :error
  def def_clause({kind, meta, [head, kw]}) when kind in [:def, :defp] and is_list(kw) do
    {call, guard} =
      case head do
        {:when, _, [call, guard]} -> {call, guard}
        call -> {call, nil}
      end

    case call do
      {name, _, args} when is_atom(name) ->
        {:ok,
         {kind, name, if(is_list(args), do: args, else: []), guard, Keyword.get(kw, :do), meta}}

      _ ->
        :error
    end
  end

  def def_clause(_), do: :error

  @doc "Variable names bound at the top of a parameter pattern (`x`, `x = %{}`, `x \\\\ 1`)."
  @spec param_names(Macro.t()) :: [atom()]
  def param_names({:=, _, [l, r]}), do: param_names(l) ++ param_names(r)
  def param_names({:\\, _, [v, _]}), do: param_names(v)

  def param_names({name, _, ctx} = v) when is_atom(name) and is_atom(ctx),
    do: if(var?(v), do: [name], else: [])

  def param_names(_), do: []

  @doc "Shape of code: variables renamed by first appearance, metadata dropped, pipes expanded."
  @spec normalize(Macro.t()) :: Macro.t()
  def normalize(ast) do
    {normalized, _} =
      ast
      |> expand_pipes()
      |> Macro.prewalk(%{}, &normalize_node/2)

    normalized
  end

  defp normalize_node({name, _, ctx}, vars) when is_atom(name) and is_atom(ctx) do
    if prefixed?(name, "__"), do: {{name, [], nil}, vars}, else: rename_var(name, vars)
  end

  defp normalize_node({a, _, b}, vars), do: {{a, [], b}, vars}
  defp normalize_node(other, vars), do: {other, vars}

  defp rename_var(name, vars) do
    {index, numbered} =
      case vars do
        %{^name => i} -> {i, vars}
        _ -> {map_size(vars), Map.put(vars, name, map_size(vars))}
      end

    {{:v, [index: index], nil}, numbered}
  end

  @doc "Node count."
  @spec size(Macro.t()) :: non_neg_integer()
  def size(ast), do: walk(ast, 0, fn _, n -> n + 1 end)

  @doc "Last expression of a block."
  @spec last_expr(Macro.t()) :: Macro.t()
  def last_expr({:__block__, _, [_ | _] = xs}), do: List.last(xs)
  def last_expr(other), do: other

  @doc "Flattens a literal or interpolated string into the text of its literal parts, or nil."
  @spec string_text(Macro.t()) :: String.t() | nil
  def string_text(s) when is_binary(s), do: s

  def string_text({:<<>>, _, parts}) when is_list(parts) do
    parts
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  def string_text(_), do: nil

  # Modules are identified by name, never by atom. Names come from the analysed source and from
  # configuration, so they may belong to modules that are not loaded (or do not exist);
  # turning arbitrary names into atoms is unbounded and is not needed to compare them. An
  # Elixir module is its dotted name without the `Elixir.` prefix (`"Enum"`, `"MyApp.Repo"`);
  # an Erlang module keeps its colon (`":rand"`), which is what `inspect/1` prints for both.
  @typedoc """
  Dotted module name without `Elixir.` (`MyApp.Repo` is the string `MyApp.Repo`); Erlang
  modules keep a colon (`:ets` is the string `:ets`).
  """
  @type module_name :: String.t()

  @doc """
  Joins alias segments (`[:MyApp, :Billing]`, or a resolved prefix name followed by more
  segments) into a module name (`"MyApp.Billing"`). A leading `Elixir` segment is dropped.
  """
  @spec join_name([atom() | String.t()]) :: module_name()
  def join_name(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> drop_elixir_prefix()
    |> Enum.join(".")
  end

  defp drop_elixir_prefix(["Elixir" | [_ | _] = rest]), do: rest
  defp drop_elixir_prefix(parts), do: parts

  @doc """
  The name of an existing module atom: `Enum` is `"Enum"`, `:rand` is `":rand"`. Only for atoms
  that already exist (literals in this package's source, configuration, compiled metadata).
  """
  @spec atom_name(atom()) :: module_name()
  def atom_name(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> name -> name
      name -> ":" <> name
    end
  end

  @doc "True when `name` is `prefix` or lies under it (`A.B.C` is under `A.B`, `A.BC` is not)."
  @spec under_name?(module_name(), module_name()) :: boolean()
  def under_name?(name, prefix), do: name == prefix or String.starts_with?(name, prefix <> ".")

  @doc """
  Renders a list of module names the way `inspect/1` renders the same list of module atoms
  (`[MyApp.Shared, MyApp.Ports]`), including its truncation of very long lists.
  """
  @spec inspect_names([module_name()]) :: String.t()
  def inspect_names(names) do
    doc = Inspect.Algebra.container_doc("[", names, "]", %Inspect.Opts{}, fn name, _ -> name end)

    doc
    |> Inspect.Algebra.group()
    |> Inspect.Algebra.format(:infinity)
    |> IO.iodata_to_binary()
  end

  @doc "Module name from a literal alias node or an atom, else nil. Aliases are not expanded."
  @spec module_name(Macro.t()) :: module_name() | nil
  def module_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: join_name(parts), else: nil
  end

  def module_name(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: atom_name(atom)

  def module_name(_), do: nil

  @doc "Every `defmodule` as `{name_ast, meta, body}` (nested modules included)."
  @spec modules(Macro.t()) :: [{Macro.t(), keyword(), Macro.t()}]
  def modules(ast) do
    ast
    |> walk([], fn
      {:defmodule, meta, [name, [do: body]]}, acc -> [{name, meta, body} | acc]
      _, acc -> acc
    end)
    |> Enum.reverse()
  end

  @doc "Removes nested `defmodule` nodes so per-module counts exclude inner modules."
  @spec strip_modules(Macro.t()) :: Macro.t()
  def strip_modules(body) do
    Macro.prewalk(body, fn
      {:defmodule, meta, _} -> {:__block__, meta, []}
      node -> node
    end)
  end
end
