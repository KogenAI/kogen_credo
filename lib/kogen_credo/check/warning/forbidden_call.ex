defmodule KogenCredo.Check.Warning.ForbiddenCall do
  @moduledoc """
  A configurable policy engine for banned calls. Nothing is banned by default:
  you supply `rules` and/or `presets`.

  Each rule is a keyword list or map:

      [
        calls: [{System, :put_env}, {File, :cd!, 1}, {:timer, :sleep}],
        message: "Tests run async; use the injected environment instead.",
        paths: ["test/"],        # optional: apply only to files under these prefixes
        allow: ["test/support/"], # optional: exempt files under these prefixes
        only_async: true         # optional: only inside modules that `use ..., async: true`
      ]

  `calls` entries are `{Module, :function}` (any arity) or `{Module, :function, arity}`
  (an integer or a list of integers). Erlang modules are atoms (`:timer`).

  Calls are resolved through the aliases in force at the call site (lexically: an alias
  declared in another function or module does not apply), so `alias System, as: Sys` and
  `Sys.put_env/2` match, while a project-local `File` module (`alias MyApp.File`)
  does not match `{File, :cd!}`. Detected forms: remote calls, piped calls
  (arity includes the piped argument), captures (`&File.cd!/1`), `apply/3` and
  `Kernel.apply/3` with literal module and function and a literal argument list, and
  bare calls to functions brought in by an `import Module` in scope (respecting `only:`
  and `except:`; skipped when the file defines a function of the same name).

  A rule with an unknown key (for example `path:` for `paths:`), a non-list `paths`/`allow`
  or an invalid call spec raises `ArgumentError` instead of silently widening the rule.

  ## Presets

  `presets: [:async_safe_tests]` adds a rule (`only_async: true`) for `test/` that forbids
  what makes async tests flaky: `Process.sleep/1`, `:timer.sleep/1`, `System.put_env`/`delete_env`,
  `Application.put_env`/`delete_env`, and `File.cd`/`cd!`. Files under `test/support/`
  are exempt by default (`preset_allow`). Only modules with a literal `use ..., async: true`
  are checked: `async: false` modules run alone, and top-level scripts such as
  `test/test_helper.exs` run before any test, so the preset's "async tests" claim would be
  false there. Use an explicit rule without `only_async` to ban a call in every test file.

  ## Limitations

  Aliases are resolved lexically, but `use`-injected imports and dynamic
  module/function names are invisible, and a rule only sees syntax: it cannot tell a
  banned call in dead code from a live one.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [rules: [], presets: [], preset_allow: ["test/support/"]],
    explanations: [
      check: """
      Calls that mutate global state (`System.put_env`, `File.cd!`), sleep for a fixed time or
      bypass an injected port should be impossible to add silently. Configure `rules` with the
      exact calls, a message that says what to use instead, and optional `paths`/`allow` scopes.
      """,
      params: [
        rules: "List of rules: `calls`, `message`, optional `paths` and `allow` (see moduledoc).",
        presets: "Built-in rule sets to add. Supported: `:async_safe_tests`.",
        preset_allow: "Path prefixes exempt from preset rules."
      ]
    ]

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.CallPresets
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings

  @doc false
  @spec preset(atom(), [String.t()]) :: keyword()
  def preset(name, allow), do: CallPresets.fetch(name, allow)

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    rules =
      params
      |> rules()
      |> Enum.filter(&applies?(&1, filename))

    if rules == [] do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      ast = SourceFile.ast(source_file)
      {async_only, always} = Enum.split_with(rules, & &1.only_async)

      scan(ast, always, issue_meta) ++ scan(async_modules_only(ast), async_only, issue_meta)
    end
  end

  defp scan(_, [], _), do: []

  defp scan(ast, rules, issue_meta) do
    index = build_index(rules)

    ast
    |> Ast.expand_pipes()
    |> mark_captures()
    |> Scope.walk([], &visit(&1, &2, &3, index, issue_meta))
    |> Enum.reverse()
  end

  # Keeps only modules that declare `use ..., async: true`; other modules and loose
  # top-level code (scripts, `test_helper.exs`) are dropped.
  defp async_modules_only(ast) do
    ast
    |> top_level_statements()
    |> Enum.filter(&async_module?/1)
    |> then(&{:__block__, [], &1})
  end

  defp top_level_statements({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp top_level_statements(stmt), do: [stmt]

  defp async_module?({:defmodule, _, [_, [do: body]]}) do
    body
    |> Ast.strip_modules()
    |> top_level_statements()
    |> Enum.any?(fn
      {:use, _, [_, opts | _]} when is_list(opts) -> Keyword.get(opts, :async) == true
      _ -> false
    end)
  end

  defp async_module?(_), do: false

  defp rules(params) do
    rules = Params.get(params, :rules, __MODULE__)
    presets = Params.get(params, :presets, __MODULE__)

    allow =
      params
      |> Params.get(:preset_allow, __MODULE__)
      |> Settings.strings!(:preset_allow)

    unless is_list(rules), do: Settings.raise_bad(:rules, rules, "a list of rules")
    unless is_list(presets), do: Settings.raise_bad(:presets, presets, "a list of preset names")

    Enum.map(rules, &normalize_rule/1) ++
      for(p <- presets, do: normalize_rule(preset(p, allow)))
  end

  defp normalize_rule(rule) do
    Settings.known_keys!(
      rule,
      [:calls, :message, :paths, :allow, :only_async],
      "ForbiddenCall rule"
    )

    calls = rule[:calls]
    message = rule[:message]

    unless is_list(calls) and calls != [] and is_binary(message) do
      raise ArgumentError,
            "ForbiddenCall rule needs a non-empty :calls list and a :message string, got: #{inspect(rule)}"
    end

    %{
      calls: Enum.map(calls, &normalize_call/1),
      message: message,
      paths: Settings.strings!(rule[:paths] || [], :paths),
      allow: Settings.strings!(rule[:allow] || [], :allow),
      only_async: rule[:only_async] == true
    }
  end

  defp normalize_call({m, f}) when is_atom(m) and is_atom(f), do: {Ast.atom_name(m), f, :any}

  defp normalize_call({m, f, a}) when is_atom(m) and is_atom(f) and (is_integer(a) or is_list(a)),
    do: {Ast.atom_name(m), f, List.wrap(a)}

  defp normalize_call(other),
    do: raise(ArgumentError, "ForbiddenCall: invalid call spec #{inspect(other)}")

  defp applies?(rule, filename) do
    (rule.paths == [] or Paths.in_paths?(filename, rule.paths)) and
      not Paths.in_paths?(filename, rule.allow)
  end

  defp build_index(rules) do
    for rule <- rules, {m, f, arities} <- rule.calls, reduce: %{} do
      acc -> Map.update(acc, {m, f}, [{arities, rule}], &[{arities, rule} | &1])
    end
  end

  defp lookup(index, mod, fun, arity) do
    index
    |> Map.get({mod, fun}, [])
    |> Enum.find_value(fn {arities, rule} ->
      if arities == :any or arity in arities, do: rule
    end)
  end

  # `&Mod.fun/arity` becomes one synthetic node so the inner zero-argument remote call is
  # not reported a second time.
  defp mark_captures(ast) do
    Macro.prewalk(ast, fn
      {:&, _, [{:/, _, [{{:., meta, [mod_ast, fun]}, _, []}, arity]}]}
      when is_atom(fun) and is_integer(arity) ->
        {:__kogen_capture__, meta, [mod_ast, fun, arity]}

      node ->
        node
    end)
  end

  defp visit({:__kogen_capture__, meta, [mod_ast, fun, arity]}, env, acc, index, issue_meta),
    do: report(acc, index, Aliases.resolve(mod_ast, env.aliases), fun, arity, meta, issue_meta)

  defp visit({{:., meta, [kernel, :apply]}, _, [mod_ast, fun, args]}, env, acc, index, im)
       when is_atom(fun) and is_list(args) do
    if Aliases.resolve(kernel, env.aliases) == "Kernel",
      do: report(acc, index, Aliases.resolve(mod_ast, env.aliases), fun, length(args), meta, im),
      else: acc
  end

  defp visit({{:., meta, [mod_ast, fun]}, _, args}, env, acc, index, issue_meta)
       when is_atom(fun) and is_list(args),
       do:
         report(
           acc,
           index,
           Aliases.resolve(mod_ast, env.aliases),
           fun,
           length(args),
           meta,
           issue_meta
         )

  defp visit({:apply, meta, [mod_ast, fun, args]}, env, acc, index, issue_meta)
       when is_atom(fun) and is_list(args) do
    if MapSet.member?(env.locals, {:apply, 3}),
      do: acc,
      else:
        report(
          acc,
          index,
          Aliases.resolve(mod_ast, env.aliases),
          fun,
          length(args),
          meta,
          issue_meta
        )
  end

  defp visit({fun, meta, args}, env, acc, index, issue_meta)
       when is_atom(fun) and is_list(args) do
    arity = length(args)

    if MapSet.member?(env.locals, {fun, arity}) do
      acc
    else
      Enum.reduce(env.imports, acc, &import_hit(&1, &2, {fun, arity}, meta, {index, issue_meta}))
    end
  end

  defp visit(_, _, acc, _, _), do: acc

  defp import_hit({mod, only}, acc, {fun, arity}, meta, {index, issue_meta}) do
    if imported?(only, fun, arity),
      do: report(acc, index, mod, fun, arity, meta, issue_meta),
      else: acc
  end

  defp imported?(:all, _, _), do: true
  defp imported?({:except, list}, fun, arity), do: {fun, arity} not in list
  defp imported?(only, fun, arity), do: {fun, arity} in only

  defp report(acc, index, mod, fun, arity, meta, issue_meta) do
    case mod && lookup(index, mod, fun, arity) do
      nil ->
        acc

      false ->
        acc

      rule ->
        trigger = "#{mod}.#{fun}"

        [
          format_issue(issue_meta,
            message: "`#{trigger}/#{arity}` is forbidden here. #{rule.message}",
            trigger: Atom.to_string(fun),
            line_no: meta[:line]
          )
          | acc
        ]
    end
  end
end
