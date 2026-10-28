defmodule KogenCredo.Diff.Report do
  @moduledoc """
  Result of a git-range run.

  `findings` are rule hits. `errors` are per-file failures (`{file, message}`), for example
  source that does not parse or a blob git could not read; they are never treated as success.
  `deleted` lists deleted files, which no rule evaluates. `files` is the number of files
  analysed.
  """

  defstruct findings: [], errors: [], deleted: [], files: 0

  @type t :: %__MODULE__{
          findings: [KogenCredo.Diff.Finding.t()],
          errors: [{String.t(), String.t()}],
          deleted: [String.t()],
          files: non_neg_integer()
        }
end
