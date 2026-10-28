defmodule KogenCredo.Check.Warning.UnboundedWait do
  @moduledoc """
  Flags waits that can hang a process or a test suite forever:

    * `receive` without an `after` clause;
    * `receive ... after :infinity`;
    * `:infinity` passed as the timeout argument of well-known blocking calls
      (`GenServer.call/3`, `Task.await/2`, `Task.yield/2`, `Agent.get/3`,
      `Process.sleep/1`, `:timer.sleep/1`, … see `infinity_calls`);
    * a `timeout: :infinity` keyword option in any call (`flag_timeout_option`).

  Calls are resolved through file aliases and pipes are expanded, so
  `task |> Task.await(:infinity)` is seen.

  ## Limitations

  Syntactic and name based. Only the listed calls are known, timeouts held in
  variables or module attributes are not evaluated, and some `receive` loops without
  `after` are correct (process-based servers). Add such files to `excluded_paths`
  or set `flag_receive_without_after: false`.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/", "test/"],
      excluded_paths: [],
      flag_receive_without_after: true,
      flag_timeout_option: true,
      # {Module, function, zero-based index of the timeout argument}
      infinity_calls: [
        {GenServer, :call, 2},
        {GenServer, :stop, 2},
        {Task, :await, 1},
        {Task, :yield, 1},
        {Task, :await_many, 1},
        {Agent, :get, 2},
        {Agent, :get_and_update, 2},
        {Agent, :update, 2},
        {Agent, :stop, 2},
        {Supervisor, :stop, 2},
        {Process, :sleep, 0},
        {:timer, :sleep, 0},
        {:gen_server, :call, 2}
      ]
    ],
    explanations: [
      check: """
      A `receive` without `after`, or a call with timeout `:infinity`, turns a lost message or a
      crashed peer into a hang that only a CI timeout will end. Use a finite deadline (and handle
      the timeout) so the failure is reported where it happens.
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped.",
        flag_receive_without_after: "Report `receive` blocks that have no `after` clause.",
        flag_timeout_option: "Report `timeout: :infinity` keyword options.",
        infinity_calls:
          "`{Module, :function, timeout_arg_index}` entries where `:infinity` is reported."
      ]
    ]

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)
      receive? = Params.get(params, :flag_receive_without_after, __MODULE__)
      option? = Params.get(params, :flag_timeout_option, __MODULE__)

      calls =
        params
        |> Params.get(:infinity_calls, __MODULE__)
        |> infinity_calls()

      cfg = %{receive?: receive?, option?: option?, calls: calls}

      source_file
      |> SourceFile.ast()
      |> Ast.expand_pipes()
      |> Scope.walk([], fn node, env, acc -> findings(node, cfg, env.aliases) ++ acc end)
      |> Enum.reverse()
      |> Enum.map(fn {line, msg} ->
        format_issue(issue_meta,
          message: msg <> ". Use a finite timeout and handle the timeout case.",
          trigger: ":infinity",
          line_no: line
        )
      end)
    else
      []
    end
  end

  defp infinity_calls(entries) when is_list(entries) do
    Map.new(entries, fn
      {m, f, i} when is_atom(m) and is_atom(f) and is_integer(i) and i >= 0 ->
        {{Ast.atom_name(m), f}, i}

      other ->
        raise ArgumentError,
              "infinity_calls entries must be {Module, :function, index}, got: #{inspect(other)}"
    end)
  end

  defp infinity_calls(other),
    do: raise(ArgumentError, "infinity_calls must be a list, got: #{inspect(other)}")

  defp findings({:receive, meta, [kw]}, cfg, _) when is_list(kw) do
    cond do
      not Keyword.has_key?(kw, :after) and cfg.receive? ->
        [{meta[:line], "`receive` without `after` waits forever if the message never arrives"}]

      infinity_after?(kw) ->
        [{meta[:line], "`receive ... after :infinity` waits forever"}]

      true ->
        []
    end
  end

  defp findings({{:., meta, [mod_ast, fun]}, _, args}, cfg, aliases)
       when is_atom(fun) and is_list(args) do
    mod = Aliases.resolve(mod_ast, aliases)

    positional =
      case cfg.calls[{mod, fun}] do
        nil ->
          []

        index ->
          if Enum.at(args, index) == :infinity,
            do: [
              {meta[:line], "`#{mod}.#{fun}` with `:infinity` timeout can hang forever"}
            ],
            else: []
      end

    positional ++ option_findings(meta, args, cfg)
  end

  defp findings({name, meta, args}, cfg, _) when is_atom(name) and is_list(args),
    do: option_findings(meta, args, cfg)

  defp findings(_, _, _), do: []

  defp option_findings(meta, args, cfg) do
    if cfg.option? and Enum.any?(args, &timeout_infinity_kw?/1),
      do: [{meta[:line], "`timeout: :infinity` disables the deadline"}],
      else: []
  end

  defp infinity_after?(kw) do
    kw
    |> Keyword.get(:after, [])
    |> List.wrap()
    |> Enum.any?(&match?({:->, _, [[:infinity], _]}, &1))
  end

  defp timeout_infinity_kw?(arg) when is_list(arg),
    do: Enum.any?(arg, &(&1 == {:timeout, :infinity}))

  defp timeout_infinity_kw?(_), do: false
end
