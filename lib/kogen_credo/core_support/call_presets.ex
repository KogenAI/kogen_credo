defmodule KogenCredo.CoreSupport.CallPresets do
  @moduledoc """
  Named rule sets for `KogenCredo.Check.Warning.ForbiddenCall`.

  `:async_safe_tests` bans fixed sleeps and process-global mutations (environment,
  application env, working directory) in modules that run asynchronously.
  """

  @async_safe_calls [
    {Process, :sleep, 1},
    {:timer, :sleep, 1},
    {System, :put_env},
    {System, :delete_env},
    {Application, :put_env},
    {Application, :delete_env},
    {File, :cd},
    {File, :cd!}
  ]

  @doc "The rule keyword list for the preset `name`; `allow` lists path globs it must not apply to."
  @spec fetch(atom(), [String.t()]) :: keyword()
  def fetch(:async_safe_tests, allow) do
    [
      calls: @async_safe_calls,
      message:
        "Async tests must not sleep for fixed durations or mutate process-global state " <>
          "(environment, application env, working directory). Await a message/event, or inject the dependency.",
      paths: ["test/"],
      allow: allow,
      only_async: true
    ]
  end

  def fetch(other, _),
    do: raise(ArgumentError, "unknown ForbiddenCall preset: #{inspect(other)}")
end
