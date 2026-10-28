defmodule KogenCredo.Diff.Rule do
  @moduledoc """
  A diff rule judges one changed function against its base version.

  `check/2` receives a `KogenCredo.Diff.Change` and the rule options (a keyword list shared by
  all rules) and returns findings built with `KogenCredo.Diff.Finding.for_change/3`. The severity
  of a finding is assigned by `KogenCredo.Diff.check/3` from `default_severity/0` and the
  `:severity` option, so a rule never decides by itself that a hit blocks a build.
  """

  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Finding

  @callback id() :: String.t()
  @callback default_severity() :: Finding.severity()
  @callback check(Change.t(), keyword()) :: [Finding.t()]
end
