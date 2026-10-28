defmodule KogenCredo.Check.Warning.NoGlobalTeardown do
  @moduledoc """
  A test must not destroy or stop app-owned, named state: `:ets.delete/1` of a
  named table, `Application.stop/1`, `Supervisor.terminate_child/2` on a named
  supervisor, `GenServer.stop/1` of a registered name, or
  `Process.exit(Process.whereis(name), ...)`.

  The module that does it may pass, but it breaks every other module that
  relies on the app's table or process. Start a private instance instead
  (`start_supervised/1` with a per-test name, a table created in `setup`).

  ## Params

    * `allowed_targets` - target names (e.g. `"MyApp.Cache"`, `":my_table"`
      without the colon: `"my_table"`) that may be torn down.
    * `case_templates` - declared case templates (see `KogenCredo.TestModuleInfo`).
    * `included_files` - path globs. Default `["test/**/*_test.exs"]`.

  ## Limits

  A target is "global" when it is a literal atom, module alias or module
  attribute holding one. A table the same module creates with `:ets.new/2`
  under that name is treated as test-owned and exempt. A name registered by
  `start_supervised` in the test is not recognised, so tests that stop their
  own named child must list it in `allowed_targets`. Applies to serial modules
  too: destruction hurts later modules just the same.

  A `Supervisor.terminate_child/2` is not reported when a later top-level
  statement of the same test, setup or function body calls
  `Supervisor.restart_child/2` with the same literal supervisor and the same
  literal child id (a restart-recovery test). A restart that comes first, names
  another child or supervisor, or sits inside a branch, anonymous function,
  `on_exit` or another block does not count. If an assertion between the two
  calls fails, the child stays down; the exemption proves ordering, not
  cleanup. The child still goes down during the test, so the module should be
  serial.
  """

  use Credo.Check,
    base_priority: :low,
    category: :warning,
    param_defaults: [
      allowed_targets: [],
      case_templates: %{},
      included_files: ["test/**/*_test.exs"]
    ],
    explanations: [
      check: """
      Tests must not delete or stop named, app-owned state.

      **Bad:**
      ```elixir
      setup do
        :ets.delete(:app_cache)
      end
      ```

      **Good:** start a private instance, e.g. `start_supervised!({Cache, name: unique_name})`.
      """,
      params: [
        allowed_targets: "Target names that tests may tear down.",
        case_templates: "Map of case template module name => :inherit | :async | :serial.",
        included_files: "Path globs of files to check."
      ]
    ]

  alias KogenCredo.SafetySupport
  alias KogenCredo.TestModuleInfo

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    allowed =
      params
      |> Params.get(:allowed_targets, __MODULE__)
      |> Enum.map(&to_string/1)

    included = Params.get(params, :included_files, __MODULE__)

    if SafetySupport.path_matches?(source_file.filename, included) do
      ast = Credo.SourceFile.ast(source_file)
      restored = restored_lines(ast)

      ast
      |> TestModuleInfo.parse(case_templates: all_templates(params))
      |> Enum.flat_map(&teardown_issues(&1, allowed, restored, issue_meta))
    else
      []
    end
  end

  defp teardown_issues(info, allowed, restored, issue_meta) do
    for td <- info.teardowns,
        td.target not in allowed,
        not (td.call == ":ets.delete/1" and td.target in info.created_tables),
        td.line not in restored do
      teardown_issue(issue_meta, info, td)
    end
  end

  defp teardown_issue(issue_meta, info, td) do
    format_issue(issue_meta,
      message:
        "#{info.name} calls #{td.call} on #{td.target}, which is app-wide named state. " <>
          "Other modules depending on it break. Start a private instance (start_supervised with a per-test name, a table created in setup) instead.",
      trigger:
        td.call
        |> String.split(["(", "/"])
        |> hd()
        |> String.split(".")
        |> List.last(),
      line_no: td.line
    )
  end

  # Lines of `Supervisor.terminate_child(sup, id)` calls that a later statement
  # of the same straight-line test/setup/def body undoes with
  # `Supervisor.restart_child(sup, id)`. Supervisor and child must both be
  # static literals (alias or atom) and equal. Only top-level statements of the
  # body count (optionally as `x = call` / `{:ok, _} = call`): a restart in a
  # branch, anonymous function, `on_exit` callback or another block is not
  # guaranteed to run, so it does not excuse the termination.
  defp restored_lines(ast) do
    aliases = SafetySupport.aliases(ast)

    {_, lines} = Macro.prewalk(ast, [], &collect_bounces(&1, &2, aliases))
    lines
  end

  defp collect_bounces({kind, _, [_ | _] = args} = node, acc, aliases)
       when kind in [:test, :setup, :setup_all, :def, :defp],
       do: {node, bounced_lines(body_statements(args), aliases) ++ acc}

  defp collect_bounces(node, acc, _), do: {node, acc}

  defp body_statements(args) do
    case List.last(args) do
      opts when is_list(opts) ->
        case Keyword.get(opts, :do) do
          {:__block__, _, stmts} when is_list(stmts) -> stmts
          nil -> []
          single -> [single]
        end

      _ ->
        []
    end
  end

  defp bounced_lines(statements, aliases) do
    calls = indexed_calls(statements, aliases)

    for {:terminate_child, sup, child, line, index} <- calls,
        sup != nil and child != nil,
        restarted_later?(calls, sup, child, index),
        do: line
  end

  defp indexed_calls(statements, aliases) do
    statements
    |> Enum.map(&supervisor_call(&1, aliases))
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {nil, _} -> []
      {call, index} -> [Tuple.insert_at(call, 4, index)]
    end)
  end

  defp restarted_later?(calls, sup, child, index) do
    Enum.any?(calls, fn
      {:restart_child, ^sup, ^child, _, later} -> later > index
      _ -> false
    end)
  end

  defp supervisor_call({:=, _, [_, rhs]}, aliases), do: supervisor_call(rhs, aliases)

  defp supervisor_call(
         {{:., _, [{:__aliases__, _, _}, fun]}, meta, [sup, child | _]} = node,
         aliases
       )
       when fun in [:terminate_child, :restart_child] do
    case SafetySupport.remote_call(node, aliases) do
      {[:Supervisor], ^fun, _} ->
        {fun, literal_name(sup, aliases), literal_name(child, aliases), meta[:line]}

      _ ->
        nil
    end
  end

  defp supervisor_call(_, _), do: nil

  defp literal_name({:__aliases__, _, parts}, aliases) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do:
        parts
        |> SafetySupport.expand(aliases)
        |> Enum.join(".")
  end

  defp literal_name(atom, _) when is_atom(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp literal_name(_, _), do: nil

  defp all_templates(params), do: Params.get(params, :case_templates, __MODULE__)
end
