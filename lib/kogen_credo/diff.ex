defmodule KogenCredo.Diff do
  @moduledoc """
  Diff-aware AST rules: judge each changed function against its own base version.

  A lost `LIMIT`, a dropped validation or a deleted owner scope is only visible this way: the
  head alone looks like ordinary code.

  ## Pure API

  No git history is needed to use the engine:

      {:ok, changes} = KogenCredo.Diff.changes("lib/a.ex", base_source, head_source)
      findings = KogenCredo.Diff.check(changes)

  `changes/3` returns `{:error, {:invalid_source, :base | :head, message}}` when either side does
  not parse, never an empty success. `run/2` drives the same engine over a git range.

  ## Indexing

  Functions are indexed by `{module, name, arity}` for `def` and `defp`. All clauses of a function
  (including guarded ones) are grouped, nested `defmodule`s extend the module name, and a
  base counterpart is the same key, or else, within that module, the one base function of that
  name whose arity vanished when exactly one function of that name appeared in the head (an added
  or removed parameter). Any other arity change is ambiguous and the head function counts as new
  instead of being compared with the wrong base. A change of visibility alone counts as changed. A function counts as changed when its
  clauses differ with metadata stripped, so formatting-only edits are invisible. Removed
  functions are not evaluated.

  Known gaps: `defdelegate`, macro-generated functions (`unquote` heads, `quote` bodies),
  `defimpl` and `defprotocol` bodies (only `defmodule` is descended into, so a function there is
  never compared), modules whose name is not a literal alias (`defmodule unquote(name)`;
  `__MODULE__.Child` is supported), functions defined in `if`/`for` blocks, module attributes used as limits, and logic
  moved into another module. Functions with default arguments are indexed under their full
  arity only.

  ## Git runs

  `run/2` reads `--repo` (default `.`), which may be a subdirectory of the work tree.
  `:paths`/`--path` (default `lib/`) are relative to that directory and every path must match a
  file in the base or head tree, otherwise the run fails (exit 2) instead of reporting
  `0 file(s) analysed`. Umbrella projects: pass `--path apps/NAME/lib/` once per app, or run
  with `--repo apps/NAME`. A range that changes nothing under existing paths still succeeds.
  Inherited `GIT_DIR`, `GIT_WORK_TREE` and similar variables are ignored.

  ## Tiers

  Every rule defaults to `:advisory`. A prototype of `QueryLostLimit` was swept in earlier
  research; those numbers say nothing about this implementation, which has **not** been swept,
  and no other rule has any measured precision. Promote a rule with the `:severity` option (`%{"rule-id" => :error}`) or
  `--error-rules` only after sweeping it on your own history.

  ## Options (shared by all rules)

  `:repo_names` (default `[:Repo]`), `:repo_modules`, `:sensitive_fields` (query scope fields,
  default `[:user_id, :tenant_id, :account_id, :organization_id]`),
  `:cast_sensitive_fields` (fields that must not be added to `cast`), `:severity`.

  Repo, module and field options take atoms or strings (the CLI passes strings). They are
  compared by name with the analysed code, so a name that no loaded code mentions is as good as
  any other. `Change.module` is the enclosing module's name, a string such as `"MyApp.Search"`.
  """

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding
  alias KogenCredo.Diff.Report
  alias KogenCredo.Diff.Runner
  alias KogenCredo.SafetySupport

  @rules [
    KogenCredo.Diff.Rules.QueryLostLimit,
    KogenCredo.Diff.Rules.QueryLostScope,
    KogenCredo.Diff.Rules.NewRepoInLoop,
    KogenCredo.Diff.Rules.NewSilentFallback,
    KogenCredo.Diff.Rules.ChangesetWeakened,
    KogenCredo.Diff.Rules.LostTransaction,
    KogenCredo.Diff.Rules.WidenedApi
  ]

  @doc "All rule modules."
  @spec rules() :: [module()]
  def rules, do: @rules

  @doc "Looks a rule module up by its id, e.g. `\"query-lost-limit\"`."
  @spec rule_by_id(String.t()) :: {:ok, module()} | :error
  def rule_by_id(id) do
    case Enum.find(@rules, &(&1.id() == id)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  @doc "Runs the diff over a git range. Options and static limits are described in the module documentation."
  @spec run(String.t(), keyword()) :: {:ok, Report.t()} | {:error, String.t()}
  defdelegate run(range, opts \\ []), to: Runner

  @doc """
  Runs `rules` over changes and returns findings with their severity assigned.
  """
  @spec check([Change.t()], [module()], keyword()) :: [Finding.t()]
  def check(changes, rules \\ @rules, opts \\ []) do
    overrides = Keyword.get(opts, :severity, %{})

    for change <- changes, rule <- rules, finding <- rule.check(change, opts) do
      %{finding | severity: Map.get(overrides, rule.id(), rule.default_severity())}
    end
  end

  @doc """
  Parses both versions and returns the changed functions. `base_src` is `nil` for a new file.
  """
  @spec changes(String.t(), String.t() | nil, String.t()) ::
          {:ok, [Change.t()]} | {:error, {:invalid_source, :base | :head, String.t()}}
  def changes(file, base_src, head_src) do
    with {:ok, base} <- index(base_src, :base),
         {:ok, head} <- index(head_src, :head) do
      {:ok, build_changes(file, base, head)}
    end
  end

  @doc "Convenience: `changes/3` then `check/3`."
  @spec check_sources(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, [Finding.t()]} | {:error, term()}
  def check_sources(file, base_src, head_src, opts \\ []) do
    with {:ok, changes} <- changes(file, base_src, head_src) do
      {:ok, check(changes, Keyword.get(opts, :rules, @rules), opts)}
    end
  end

  defp build_changes(file, base, head) do
    head.functions
    |> Enum.flat_map(&function_change(&1, file, base, head))
    |> Enum.sort_by(&{&1.line, &1.name})
  end

  defp function_change({key, head_fn}, file, base, head) do
    {base_fn, base_arity} = counterpart(base.functions, head.functions, key)

    if base_fn == nil or changed?(base_fn, head_fn),
      do: [new_change(file, key, {base_fn, base_arity}, head_fn, {base, head})],
      else: []
  end

  defp new_change(file, {mod, name, arity}, {base_fn, base_arity}, head_fn, {base, head}) do
    %Change{
      file: file,
      module: mod,
      name: name,
      arity: arity,
      line: head_fn.line,
      base: base_fn && base_fn.clauses,
      head: head_fn.clauses,
      base_kind: base_fn && base_fn.kind,
      base_arity: base_arity,
      head_kind: head_fn.kind,
      impl: head_fn.impl,
      module_new: not Enum.any?(base.functions, fn {{m, _, _}, _} -> m == mod end),
      base_module: module_fns(base.functions, mod),
      head_module: module_fns(head.functions, mod),
      base_aliases: base.aliases,
      head_aliases: head.aliases
    }
  end

  # A visibility change alone (`defp` to `def`) is a change, even with identical clauses.
  defp changed?(base_fn, head_fn),
    do:
      base_fn.kind != head_fn.kind or
        SafetySupport.normalize(base_fn.clauses) != SafetySupport.normalize(head_fn.clauses)

  # Returns `{base_function | nil, base_arity | nil}`. The counterpart is the same module, name
  # and arity. Otherwise it is paired only when, in that module, exactly one function of that
  # name vanished from the base and exactly one appeared in the head (a parameter added or
  # removed). Any other shape is ambiguous, so the head function counts as new rather than
  # being compared with the wrong base arity.
  defp counterpart(base_fns, head_fns, {mod, name, arity} = key) do
    case Map.fetch(base_fns, key) do
      {:ok, fun} -> {fun, arity}
      :error -> arity_counterpart(base_fns, head_fns, mod, name)
    end
  end

  defp arity_counterpart(base_fns, head_fns, mod, name) do
    removed =
      for {{^mod, ^name, a}, fun} <- base_fns,
          not Map.has_key?(head_fns, {mod, name, a}),
          do: {fun, a}

    added =
      for {{^mod, ^name, a}, _} <- head_fns, not Map.has_key?(base_fns, {mod, name, a}), do: a

    case {removed, added} do
      {[{fun, base_arity}], [_]} -> {fun, base_arity}
      _ -> {nil, nil}
    end
  end

  defp module_fns(fns, mod) do
    for {{^mod, name, arity}, fun} <- fns, into: %{}, do: {{name, arity}, fun.clauses}
  end

  defp index(nil, _), do: {:ok, %{functions: %{}, aliases: %{}}}

  defp index(src, side) when is_binary(src) do
    case parse(src) do
      {:ok, ast} ->
        {collected, _} = collect(ast, [], %{}, false)
        # `collect/4` prepends clauses; restore source order once collection is complete.
        functions =
          Map.new(collected, fn {key, fun} ->
            {key, %{fun | clauses: Enum.reverse(fun.clauses)}}
          end)

        {:ok, %{functions: functions, aliases: SafetySupport.aliases(ast)}}

      {:error, {meta, message, token}} ->
        {:error, {:invalid_source, side, describe_error(meta, message, token)}}
    end
  end

  defp parse(src) do
    if String.valid?(src),
      do: Code.string_to_quoted(src, columns: true, emit_warnings: false),
      else: {:error, {[line: 1], "source is not valid UTF-8", ""}}
  rescue
    e -> {:error, {[line: 1], Exception.message(e), ""}}
  end

  defp describe_error(meta, message, token) do
    line = if is_list(meta), do: meta[:line], else: meta
    message = if is_binary(message), do: message, else: inspect(message)
    "line #{line}: #{message}#{token}"
  end

  # Returns {functions, impl_pending?}; `impl_pending?` carries an `@impl` to the next def.
  defp collect({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, mod, acc, _)
       when is_list(parts) do
    case module_path(parts, mod) do
      {:ok, path} ->
        {functions, _} = collect(body, path, acc, false)
        {functions, false}

      :error ->
        {acc, false}
    end
  end

  defp collect({:__block__, _, exprs}, mod, acc, impl),
    do: Enum.reduce(exprs, {acc, impl}, fn expr, {a, i} -> collect(expr, mod, a, i) end)

  defp collect({:@, _, [{:impl, _, [value]}]}, _, acc, impl),
    do: {acc, impl or value != false}

  defp collect({kind, meta, [head | _]} = clause, mod, acc, impl) when kind in [:def, :defp] do
    case fn_head(head) do
      {name, arity} when mod != [] ->
        key = {Ast.join_name(mod), name, arity}

        acc =
          Map.update(
            acc,
            key,
            %{line: meta[:line], clauses: [clause], kind: kind, impl: impl},
            fn fun ->
              %{
                fun
                | clauses: [clause | fun.clauses],
                  kind: if(:def in [fun.kind, kind], do: :def, else: :defp),
                  impl: fun.impl or impl
              }
            end
          )

        {acc, false}

      _ ->
        {acc, false}
    end
  end

  defp collect(_, _, acc, impl), do: {acc, impl}

  # `defmodule A.B` nests under the enclosing module; `__MODULE__.B` is the enclosing module.
  defp module_path([{:__MODULE__, _, ctx} | rest], mod) when is_atom(ctx) and mod != [],
    do: if(Enum.all?(rest, &is_atom/1), do: {:ok, mod ++ rest}, else: :error)

  defp module_path(parts, mod),
    do: if(Enum.all?(parts, &is_atom/1), do: {:ok, mod ++ parts}, else: :error)

  defp fn_head({:when, _, [head | _]}), do: fn_head(head)
  defp fn_head({name, _, _}) when name in [:unquote, :unquote_splicing], do: nil
  defp fn_head({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp fn_head({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, 0}
  defp fn_head(_), do: nil
end
