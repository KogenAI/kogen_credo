defmodule KogenCredo.Check.Refactor.DuplicateHelper do
  @moduledoc """
  Cross-file check: flags private helpers (`defp`) whose normalised definition
  (all clauses; variables renamed by first appearance; metadata dropped; pipes
  expanded) appears in at least `min_files` different files. Typical slop: the same
  `defp sha256/1` pasted into a dozen modules.

  Helpers smaller than `min_nodes` AST nodes, and names in `ignored_names`, are skipped.
  The same helper repeated inside one file counts once.

  ## Limitations

  Exact structural equality after renaming variables only: a copy with one changed
  literal or an extra clause is a different helper. Called function and module names
  are significant. Boilerplate callbacks are not exempt by default; add them to
  `ignored_names` if they trigger.
  """

  use Credo.Check,
    category: :refactor,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/"],
      excluded_paths: [],
      min_files: 3,
      min_nodes: 12,
      ignored_names: []
    ],
    explanations: [
      check: """
      The same private function pasted into several modules should live in one module and be
      called from the others. Duplicates drift apart and every copy needs the same fix.
      """,
      params: [
        included_paths: "Only files under these path prefixes are considered.",
        excluded_paths: "Files under these path prefixes are skipped.",
        min_files: "Report when this many different files hold the same helper.",
        min_nodes: "Minimum AST size of a helper to be considered.",
        ignored_names: "Helper names never reported."
      ]
    ]

  alias Credo.Execution.ExecutionIssues
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Settings

  @impl Credo.Check
  def run_on_all_source_files(exec, source_files, params) do
    {min_files, min_nodes, ignored} = limits(params)

    source_files
    |> scoped(params)
    |> Enum.flat_map(&defps(&1, min_nodes, ignored))
    |> Enum.group_by(& &1.hash)
    |> Enum.each(&report_group(&1, exec, min_files, params))

    :ok
  end

  defp limits(params) do
    min_files =
      params
      |> Params.get(:min_files, __MODULE__)
      |> Settings.integer!(:min_files, 2)

    min_nodes =
      params
      |> Params.get(:min_nodes, __MODULE__)
      |> Settings.integer!(:min_nodes, 1)

    ignored =
      params
      |> Params.get(:ignored_names, __MODULE__)
      |> Settings.atoms!(:ignored_names)

    {min_files, min_nodes, ignored}
  end

  defp scoped(source_files, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)
    Enum.filter(source_files, &Paths.in_scope?(&1.filename, included, excluded))
  end

  defp report_group({_, occurrences}, exec, min_files, params) do
    files =
      occurrences
      |> Enum.map(& &1.sf.filename)
      |> Enum.uniq()

    if length(files) >= min_files do
      Enum.each(occurrences, &report(exec, &1, files, params))
    end
  end

  @impl Credo.Check
  def run(_, _), do: []

  defp report(exec, occurrence, files, params) do
    others =
      files
      |> List.delete(occurrence.sf.filename)
      |> Enum.map(&Path.basename/1)
      |> Enum.take(4)
      |> Enum.join(", ")

    issue =
      format_issue(IssueMeta.for(occurrence.sf, params),
        message:
          "`defp #{occurrence.name}/#{occurrence.arity}` is duplicated in #{length(files)} files (also #{others}). " <>
            "Keep one definition in a shared module and call it.",
        trigger: Atom.to_string(occurrence.name),
        line_no: occurrence.line
      )

    ExecutionIssues.append(exec, issue)
  end

  # One candidate per `defp name/arity` of each module (clauses of different modules in the
  # same file are never merged). Code inside `quote` is a template, not a helper definition.
  defp defps(sf, min_nodes, ignored) do
    sf
    |> SourceFile.ast()
    |> Ast.modules()
    |> Enum.flat_map(fn {_, _, body} ->
      body
      |> Ast.strip_modules()
      |> strip_quotes()
      |> module_defps(sf, min_nodes, ignored)
    end)
  end

  defp strip_quotes(ast) do
    Macro.prewalk(ast, fn
      {:quote, meta, _} -> {:__block__, meta, []}
      node -> node
    end)
  end

  defp module_defps(body, sf, min_nodes, ignored) do
    body
    |> collect_defps(ignored)
    |> Enum.group_by(fn {name, arity, _, _} -> {name, arity} end)
    |> Enum.flat_map(&candidate(&1, sf, min_nodes))
  end

  defp collect_defps(body, ignored) do
    body
    |> Ast.walk([], &collect_defp(&1, &2, ignored))
    |> Enum.reverse()
  end

  defp collect_defp(node, acc, ignored) do
    case Ast.def_clause(node) do
      {:ok, {:defp, name, args, guard, def_body, meta}} ->
        if name in ignored,
          do: acc,
          else: [{name, length(args), meta[:line], [args, guard, def_body]} | acc]

      _ ->
        acc
    end
  end

  defp candidate({{name, arity}, clauses}, sf, min_nodes) do
    shape =
      clauses
      |> Enum.map(&elem(&1, 3))
      |> Ast.normalize()

    if Ast.size(shape) >= min_nodes do
      hash = :crypto.hash(:sha256, :erlang.term_to_binary({arity, shape}))
      [%{sf: sf, name: name, arity: arity, line: first_line(clauses), hash: hash}]
    else
      []
    end
  end

  defp first_line([{_, _, line, _} | _]), do: line
end
