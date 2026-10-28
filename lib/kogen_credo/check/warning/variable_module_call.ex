defmodule KogenCredo.Check.Warning.VariableModuleCall do
  @moduledoc """
  Flags calls on a variable used as a module: `mod.run(args)` and
  `apply(mod, :run, args)` where `mod` is a variable.

  Dispatch through a variable defeats static analysis: xref, Boundary, dependency
  graphs and capability tracers cannot see the callee. Prefer a behaviour with a
  compile-time chosen implementation (`@impl_mod Application.compile_env(...)`
  then `@impl_mod.run(args)`), or a literal `case` over the known modules.

  Field access without parentheses (`socket.assigns`, `user.name`) and calls on
  module attributes (`@adapter.call()`) are not reported.

  ## Limitations

  A parenthesised call on a variable is assumed to be a module call (the only valid
  meaning). Variables named in `allowed_variables` and functions in
  `ignored_functions` are skipped. `apply/2` and `apply/3` with a *variable function
  name* are reported only for a variable module.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/"],
      excluded_paths: [],
      allowed_variables: [],
      ignored_functions: [:module_info, :__info__, :__struct__, :behaviour_info],
      check_apply: true
    ],
    explanations: [
      check: """
      `mod.fun()` on a variable hides the callee from xref, Boundary and capability analysis. Use a
      behaviour whose implementation is picked at compile time (module attribute), or dispatch with
      an explicit `case` over the known modules.
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped.",
        allowed_variables: "Variable names that may hold a module (e.g. `[:adapter]`).",
        ignored_functions: "Function names never reported.",
        check_apply: "Also report `apply(variable, fun, args)`."
      ]
    ]

  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)

      opts = %{
        allowed: Params.get(params, :allowed_variables, __MODULE__),
        ignored: Params.get(params, :ignored_functions, __MODULE__),
        apply?: Params.get(params, :check_apply, __MODULE__)
      }

      source_file
      |> SourceFile.ast()
      |> Ast.walk([], &collect_call(&1, &2, opts))
      |> Enum.reverse()
      |> Enum.map(&call_issue(issue_meta, &1))
    else
      []
    end
  end

  defp collect_call({{:., _, [{name, _, ctx}, fun]}, meta, args}, acc, opts)
       when is_atom(name) and is_atom(ctx) and is_atom(fun) and is_list(args) do
    if reportable?(name, opts.allowed) and fun not in opts.ignored and
         not Keyword.get(meta, :no_parens, false),
       do: [{meta[:line], name, "#{name}.#{fun}(...)"} | acc],
       else: acc
  end

  defp collect_call({:apply, meta, [{name, _, ctx}, _, _]}, acc, opts)
       when is_atom(name) and is_atom(ctx) do
    if opts.apply? and reportable?(name, opts.allowed),
      do: [{meta[:line], name, "apply(#{name}, ...)"} | acc],
      else: acc
  end

  defp collect_call(_, acc, _), do: acc

  defp call_issue(issue_meta, {line, name, what}) do
    format_issue(issue_meta,
      message:
        "Call through variable module `#{what}` is invisible to xref and dependency tooling. " <>
          "Use a behaviour with a compile-time implementation, or `case` over the known modules.",
      trigger: Atom.to_string(name),
      line_no: line
    )
  end

  defp reportable?(name, allowed) do
    s = Atom.to_string(name)
    not String.starts_with?(s, "__") and name not in allowed
  end
end
