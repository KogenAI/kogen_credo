defmodule KogenCredo.SafetySupport do
  @moduledoc """
  Shared AST helpers for the safety checks and the diff rules.

  Everything here is syntactic. Aliases are resolved from `alias` directives
  found anywhere in the parsed tree (not by scope), and a Repo receiver is
  recognised by name, never by compiling the project. That is a heuristic:
  a `Repo` that is really something else, or a repo hidden behind a variable
  or a macro, is invisible.

  ## Repo receivers

  `repo_call/3` returns `{function_name, args}` when a call node looks like
  `Repo.all(...)`. A receiver counts as a repo when its alias-expanded module
  either equals one of the configured `:repo_modules` (full names such as
  `MyApp.Repo`) or its last segment is in `:repo_names` (default `[:Repo]`).
  """

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Settings

  @type aliases :: %{optional(atom()) => [atom()]}

  @repo_reads [:all, :stream, :one, :one!, :get, :get!, :get_by, :get_by!, :exists?, :aggregate]
  @repo_writes [
    :insert,
    :insert!,
    :insert_or_update,
    :insert_or_update!,
    :update,
    :update!,
    :delete,
    :delete!,
    :insert_all,
    :update_all,
    :delete_all
  ]

  @doc "Repo functions that read rows."
  @spec repo_reads() :: [atom()]
  def repo_reads, do: @repo_reads

  @doc "Repo functions that write rows."
  @spec repo_writes() :: [atom()]
  def repo_writes, do: @repo_writes

  @doc """
  Collects `alias` directives into a map from the local name (first segment) to
  the expanded segment list. Handles `alias A.B`, `alias A.B, as: C` and
  `alias A.{B, C}`.
  """
  @spec aliases(Macro.t()) :: aliases()
  def aliases(ast) do
    {_, acc} = Macro.prewalk(ast, %{}, &collect_alias/2)
    acc
  end

  defp collect_alias({:alias, _, [{:__aliases__, _, parts}]} = node, acc) when is_list(parts),
    do: {node, put_alias(acc, List.last(parts), parts)}

  defp collect_alias({:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc)
       when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as]} -> {node, put_alias(acc, as, parts)}
      _ -> {node, acc}
    end
  end

  defp collect_alias(
         {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes}]} = node,
         acc
       ) do
    {node, Enum.reduce(suffixes, acc, &put_suffix_alias(&1, &2, prefix))}
  end

  defp collect_alias(node, acc), do: {node, acc}

  defp put_suffix_alias({:__aliases__, _, parts}, acc, prefix),
    do: put_alias(acc, List.last(parts), prefix ++ parts)

  defp put_suffix_alias(_, acc, _), do: acc

  # Keep an unresolved alias shadowing its short name, without treating it as a top-level
  # framework module such as Supervisor or Application.
  defp put_alias(acc, name, parts) when is_atom(name),
    do: Map.put(acc, name, Enum.map(parts, &opaque_segment/1))

  defp put_alias(acc, _, _), do: acc

  defp opaque_segment(part) when is_atom(part), do: part
  defp opaque_segment(_), do: :__MODULE__

  @doc "Expands the first segment of an alias through `aliases/1` output."
  @spec expand([atom()], aliases()) :: [atom()]
  def expand([first | rest] = parts, aliases) when is_atom(first) do
    case Map.fetch(aliases, first) do
      {:ok, expanded} -> expanded ++ rest
      :error -> parts
    end
  end

  def expand(parts, _), do: parts

  @doc """
  True when `receiver_ast` is a module alias that denotes a repo.

  Options: `:repo_names` (last segments, default `[:Repo]`) and `:repo_modules`
  (full module names, default `[]`). Both take atoms or strings and are compared by name, so a
  repo that is not loaded (or does not exist) is matched like any other.
  """
  @spec repo_receiver?(Macro.t(), aliases(), keyword()) :: boolean()
  def repo_receiver?({:__aliases__, _, parts}, aliases, opts) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      expanded = expand(parts, aliases)
      names = option_names(opts, :repo_names, [:Repo], &to_string/1)
      modules = option_names(opts, :repo_modules, [], &Settings.module_name/1)

      to_string(List.last(expanded)) in names or Ast.join_name(expanded) in modules
    else
      false
    end
  end

  def repo_receiver?(_, _, _), do: false

  defp option_names(opts, key, default, fun) do
    opts
    |> Keyword.get(key, default)
    |> Enum.map(fun)
  end

  @doc """
  Returns `{fun, args}` when `node` is a call on a repo receiver
  (`Repo.all(q)`), else `nil`. Pipe-stage calls come in without the piped
  first argument, so `args` may be one shorter than the real arity.
  """
  @spec repo_call(Macro.t(), aliases(), keyword()) :: {atom(), list()} | nil
  def repo_call({{:., _, [receiver, fun]}, _, args}, aliases, opts)
      when is_atom(fun) and is_list(args) do
    if repo_receiver?(receiver, aliases, opts), do: {fun, args}
  end

  def repo_call(_, _, _), do: nil

  @doc "Splits a `|>` chain into its stages, left to right."
  @spec pipeline_stages(Macro.t()) :: [Macro.t()]
  def pipeline_stages(node), do: stages(node, [])

  defp stages({:|>, _, [lhs, rhs]}, acc), do: stages(lhs, [rhs | acc])
  defp stages(other, acc), do: [other | acc]

  @doc """
  If `node` is `Mod.fun(...)`, returns `{expanded_module_segments, fun, args}`.
  """
  @spec remote_call(Macro.t(), aliases()) :: {[atom()], atom(), list()} | nil
  def remote_call({{:., _, [{:__aliases__, _, parts}, fun]}, _, args}, aliases)
      when is_list(parts) and is_atom(fun) and is_list(args) do
    if Enum.all?(parts, &is_atom/1), do: {expand(parts, aliases), fun, args}
  end

  def remote_call(_, _), do: nil

  @doc "True when the expanded module segments equal the given module (e.g. `Enum`)."
  @spec module?([atom()], module()) :: boolean()
  def module?(segments, module) when is_list(segments) do
    Enum.all?(segments, &is_atom/1) and
      Enum.map(segments, &Atom.to_string/1) == Module.split(module)
  end

  def module?(_, _), do: false

  @doc """
  Matches a source file path against glob-like patterns.

  `**` matches any characters including `/`, `*` matches anything but `/`.
  Patterns are matched against the path as a suffix, so `lib/**` also matches
  `/abs/project/lib/a.ex`. An empty pattern list matches everything.
  """
  @spec path_matches?(String.t(), [String.t()]) :: boolean()
  def path_matches?(_, []), do: true

  def path_matches?(filename, patterns) do
    Enum.any?(patterns, fn pattern -> Regex.match?(glob_regex(pattern), filename) end)
  end

  defp glob_regex(pattern) do
    body =
      pattern
      |> String.graphemes()
      |> glob_tokens([])
      |> IO.iodata_to_binary()

    Regex.compile!("(^|/)" <> body <> "$")
  end

  defp glob_tokens([], acc), do: Enum.reverse(acc)
  defp glob_tokens(["*", "*", "/" | rest], acc), do: glob_tokens(rest, ["(.*/)?" | acc])
  defp glob_tokens(["*", "*" | rest], acc), do: glob_tokens(rest, [".*" | acc])
  defp glob_tokens(["*" | rest], acc), do: glob_tokens(rest, ["[^/]*" | acc])
  defp glob_tokens(["?" | rest], acc), do: glob_tokens(rest, ["[^/]" | acc])
  defp glob_tokens([c | rest], acc), do: glob_tokens(rest, [Regex.escape(c) | acc])

  @doc "Default test-file patterns."
  @spec test_patterns() :: [String.t()]
  def test_patterns, do: ["test/**/*_test.exs"]

  @doc "Counts nodes of `ast` matching `pred`."
  @spec count(Macro.t(), (Macro.t() -> boolean())) :: non_neg_integer()
  def count(ast, pred) do
    {_, n} =
      Macro.prewalk(ast, 0, fn node, n -> {node, if(pred.(node), do: n + 1, else: n)} end)

    n
  end

  @doc "Strips metadata so two ASTs compare structurally."
  @spec normalize(Macro.t()) :: Macro.t()
  def normalize(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _ -> [] end))
end
