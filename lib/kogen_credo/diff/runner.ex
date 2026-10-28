defmodule KogenCredo.Diff.Runner do
  @moduledoc false

  alias KogenCredo.Diff
  alias KogenCredo.Diff.Finding
  alias KogenCredo.Diff.Git
  alias KogenCredo.Diff.Report

  @doc """
  Runs the rules over a git range.

  Options: `:repo` (default `"."`), `:paths` (default `["lib/"]`, always relative to `:repo`,
  and each must match a file in the base or head tree), `:rules` (modules, default
  all) and the rule options documented in `KogenCredo.Diff`. Returns `{:error, message}` for an
  invalid range, a bad repo or path, or any git failure.
  """
  @spec run(String.t(), keyword()) :: {:ok, Report.t()} | {:error, String.t()}
  def run(range, opts \\ []) do
    repo = Keyword.get(opts, :repo, ".")
    paths = Keyword.get(opts, :paths, ["lib/"])

    with {:ok, spec} <- Git.parse_range(range),
         {:ok, repo} <- Git.validate_repo(repo),
         {:ok, paths} <- Git.validate_paths(paths),
         {:ok, revs} <- Git.resolve(repo, spec) do
      changed_report(repo, revs, paths, opts)
    end
  end

  defp changed_report(repo, {base, head} = revs, paths, opts) do
    with :ok <- Git.check_paths(repo, base, head, paths),
         {:ok, entries} <- Git.changed_files(repo, base, head, paths) do
      {:ok, build_report(entries, repo, revs, opts)}
    end
  end

  defp build_report(entries, repo, revs, opts) do
    rules = Keyword.get(opts, :rules, Diff.rules())
    report = Enum.reduce(entries, %Report{}, &analyse(&1, &2, repo, revs, rules, opts))

    # `analyse/6` prepends deleted files and errors; restore discovery order.
    %{
      report
      | findings: Enum.sort_by(report.findings, &{&1.file, &1.line, &1.rule}),
        deleted: Enum.reverse(report.deleted),
        errors: Enum.reverse(report.errors)
    }
  end

  defp analyse(%{status: :deleted, base_path: path}, report, _, _, _, _),
    do: %{report | deleted: [path | report.deleted]}

  defp analyse(entry, report, repo, {base, head}, rules, opts) do
    result =
      with {:ok, base_src} <- read(repo, base, entry.base_path),
           {:ok, head_src} <- Git.show(repo, head, entry.head_path),
           {:ok, changes} <- Diff.changes(entry.head_path, base_src, head_src) do
        {:ok, Diff.check(changes, rules, opts)}
      end

    case result do
      {:ok, findings} ->
        %{report | findings: report.findings ++ findings, files: report.files + 1}

      {:error, reason} ->
        %{report | errors: [{entry.head_path, describe(reason)} | report.errors]}
    end
  end

  defp read(_, _, nil), do: {:ok, nil}
  defp read(repo, sha, path), do: Git.show(repo, sha, path)

  defp describe({:invalid_source, side, message}),
    do: "invalid #{side} source (#{Finding.clean(message)}); file skipped"

  defp describe(message) when is_binary(message), do: Finding.clean(message)
end
