defmodule KogenCredo.Check.Warning.BroadRescue do
  @moduledoc """
  Flags broad `rescue`/`catch` clauses that do not re-raise:

    * `rescue _ ->` and `rescue e ->` (any exception);
    * `rescue e in [Exception]` / `RuntimeError` / `ErlangError` (`broad_exceptions`);
    * `catch kind, reason ->` and `catch _, _ ->` with a variable kind.

  Narrow rescues (`rescue e in [File.Error]`), `catch :exit, _ ->`, and one-argument
  `catch value ->` (throws only) pass. A clause whose body contains `raise`,
  `reraise`, `throw` or `exit` counts as re-raising.

  ## Limitations

  Syntactic. A body that raises a *different* exception is treated as a re-raise,
  and a rescue that logs and returns an error tuple is still reported on purpose.
  Where a boundary really must absorb every error, list its path in `excluded_paths`.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      broad_exceptions: [Exception, RuntimeError, ErlangError],
      included_paths: ["lib/"],
      excluded_paths: []
    ],
    explanations: [
      check: """
      Rescuing every exception launders bugs (`FunctionClauseError`, `KeyError`, a typo) into a
      value and hides defects from supervisors and tests. Rescue the specific exception at the
      I/O edge (`rescue e in File.Error`) and return a typed `{:error, reason}`, or let it crash.
      """,
      params: [
        broad_exceptions: "Exception modules treated as 'any exception'.",
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped."
      ]
    ]

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings

  @reraise_kernel [:reraise, :raise, :throw, :exit]
  @reraise_erlang [:raise, :error, :exit, :throw]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)

      broad =
        params
        |> Params.get(:broad_exceptions, __MODULE__)
        |> Settings.modules!(:broad_exceptions)

      source_file
      |> SourceFile.ast()
      |> Scope.walk([], &collect_issues(&1, &2, &3, broad, issue_meta))
      |> Enum.sort_by(& &1.line_no)
    else
      []
    end
  end

  defp collect_issues({:try, _, [kw]}, env, acc, broad, issue_meta) when is_list(kw),
    do: clauses_issues(kw, broad, env.aliases, issue_meta) ++ acc

  defp collect_issues({kind, _, [_, kw]}, env, acc, broad, issue_meta)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(kw),
       do: clauses_issues(kw, broad, env.aliases, issue_meta) ++ acc

  defp collect_issues(_, _, acc, _, _), do: acc

  defp clauses_issues(kw, broad, aliases, issue_meta) do
    for {kind, clauses} <- kw,
        kind in [:rescue, :catch],
        is_list(clauses),
        {:->, meta, [args, body]} <- clauses,
        broad?(kind, args, broad, aliases),
        not reraises?(body, aliases) do
      format_issue(issue_meta,
        message:
          "Broad `#{kind}` without re-raise swallows bugs. Rescue the specific exception at the I/O edge " <>
            "and return a typed {:error, reason}, or let it crash.",
        trigger: to_string(kind),
        line_no: meta[:line]
      )
    end
  end

  defp broad?(:rescue, [pattern], broad, aliases) do
    case pattern do
      {:in, _, [_, mods]} ->
        mods
        |> List.wrap()
        |> Enum.any?(&(Aliases.resolve(&1, aliases) in broad))

      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        true

      {:__aliases__, _, _} = mod ->
        Aliases.resolve(mod, aliases) in broad

      _ ->
        false
    end
  end

  defp broad?(:catch, [kind, reason], _, _),
    do: Ast.any_var?(kind) and Ast.any_var?(reason)

  defp broad?(_, _, _, _), do: false

  defp reraises?(body, aliases), do: Ast.walk(body, false, &reraise_step(&1, &2, aliases))

  defp reraise_step(_, true, _), do: true

  defp reraise_step({f, _, args}, _, _) when f in @reraise_kernel and is_list(args), do: true

  defp reraise_step({{:., _, [mod, f]}, _, args}, _, aliases) when is_atom(f) and is_list(args) do
    case Aliases.resolve(mod, aliases) do
      ":erlang" -> f in @reraise_erlang
      "Kernel" -> f in @reraise_kernel
      _ -> false
    end
  end

  defp reraise_step(_, found, _), do: found
end
