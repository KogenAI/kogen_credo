defmodule KogenCredo.QuerySupport do
  @moduledoc """
  Private plumbing shared by the Repo/query warning checks.

  It only wraps what every check repeats: file-path scoping from the
  `:included_paths` / `:excluded_paths` params, the parsed AST, Repo receiver
  options from `:repo_names` / `:repo_modules`, and pipe expansion.

  Pipe expansion rewrites `a |> f(b)` to `f(a, b)` everywhere, so detectors
  only have to reason about the nested-call form. It is purely syntactic.
  """

  alias Credo.Check.Params

  @doc "True when the file passes the `:included_paths` / `:excluded_paths` globs."
  @spec in_scope?(Credo.SourceFile.t(), keyword(), module()) :: boolean()
  def in_scope?(source_file, params, check) do
    filename = source_file.filename || ""
    included = Params.get(params, :included_paths, check)
    excluded = Params.get(params, :excluded_paths, check)

    KogenCredo.SafetySupport.path_matches?(filename, included) and
      (excluded == [] or not KogenCredo.SafetySupport.path_matches?(filename, excluded))
  end

  @doc "Parsed AST with pipes expanded, or `nil` when the file did not parse."
  @spec expanded_ast(Credo.SourceFile.t()) :: Macro.t() | nil
  def expanded_ast(source_file) do
    case Credo.Code.ast(source_file) do
      {:ok, ast} -> expand_pipes(ast)
      _ -> nil
    end
  end

  @doc "Rewrites `a |> f(b)` into `f(a, b)` throughout the tree."
  @spec expand_pipes(Macro.t()) :: Macro.t()
  def expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [lhs, {callee, meta, args}]} when is_list(args) -> {callee, meta, [lhs | args]}
      node -> node
    end)
  end

  @doc "Options for `KogenCredo.SafetySupport.repo_receiver?/3` from check params."
  @spec repo_opts(keyword(), module()) :: keyword()
  def repo_opts(params, check) do
    [
      repo_names:
        params
        |> Params.get(:repo_names, check)
        |> names(),
      repo_modules:
        params
        |> Params.get(:repo_modules, check)
        |> Enum.map(&to_string/1)
    ]
  end

  @doc """
  Config values as names. Function, field and repo names may be given as atoms or strings in
  `.credo.exs`; they are compared with the atoms of the analysed code by name (see `listed?/2`),
  so nothing is converted to an atom and a name that the code never mentions simply never
  matches.
  """
  @spec names([atom() | String.t()]) :: [String.t()]
  def names(list), do: Enum.map(list, &to_name/1)

  defp to_name(value) when is_atom(value), do: Atom.to_string(value)
  defp to_name(value) when is_binary(value), do: value

  @doc """
  The way `inspect/1` shows the atom with this name (`"user_id"` is `":user_id"`), without
  creating the atom.
  """
  @spec atom_label(String.t()) :: String.t()
  def atom_label(name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_@]*[?!]?\z/, name),
      do: ":" <> name,
      else: ":" <> inspect(name)
  end

  @doc "True when the atom from the analysed code is one of the configured `names/1`."
  @spec listed?(term(), [String.t()]) :: boolean()
  def listed?(atom, names) when is_atom(atom), do: Atom.to_string(atom) in names
  def listed?(_, _), do: false

  @doc "Every `def`/`defp`/`defmacro`/`defmacrop` clause in the tree."
  @spec defs(Macro.t()) :: [Macro.t()]
  def defs(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _, [_, _]} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  @doc """
  Splits a file into lexical module scopes: `[{module_segments | nil, body}]`.

  Each `defmodule` with a literal alias name becomes its own scope (nested names are the
  concatenation of the enclosing names), and its body has nested `defmodule`s cut out, so a
  function is only ever seen next to the functions of its own module. The first scope, with
  `nil`, is the code outside any module. A `defmodule` whose name is not a literal alias stays
  inline in the enclosing scope.
  """
  @spec module_scopes(Macro.t()) :: [{[atom()] | nil, Macro.t()}]
  def module_scopes(ast), do: scopes(ast, nil)

  defp scopes(ast, outer) do
    {stripped, found} = Macro.prewalk(ast, [], &take_module/2)
    nested = Enum.reverse(found)

    [{outer, stripped}] ++
      Enum.flat_map(nested, fn {parts, body} -> scopes(body, (outer || []) ++ parts) end)
  end

  defp take_module({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, acc)
       when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, [{parts, body} | acc]}, else: {nil, acc}
  end

  defp take_module(node, acc), do: {node, acc}

  @doc """
  Every `{name, arity}` a function head defines. A head with default arguments
  (`def f(a, b \\\\ 1)`) also defines the lower arities.
  """
  @spec head_keys(Macro.t()) :: [{atom(), arity()}]
  def head_keys({:when, _, [head | _]}), do: head_keys(head)

  def head_keys({name, _, args}) when is_atom(name) and is_list(args) do
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    for arity <- (length(args) - defaults)..length(args)//1, do: {name, arity}
  end

  def head_keys({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: [{name, 0}]
  def head_keys(_), do: []

  @doc "Removes duplicate `{line, trigger}` entries, keeping order."
  @spec uniq_hits([{pos_integer(), String.t(), String.t()}]) :: [
          {pos_integer(), String.t(), String.t()}
        ]
  def uniq_hits(hits), do: Enum.uniq_by(hits, fn {line, trigger, _} -> {line, trigger} end)
end
