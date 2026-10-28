defmodule KogenCredo.Diff.CLI do
  @moduledoc """
  Argument handling and rendering behind `mix kogen.diff_check`, free of `Mix.shell` so it can
  be tested: `run/1` returns `{output, exit_code}`.

  Exit codes: `0` nothing at or above `--fail-on`, `1` findings at or above `--fail-on`,
  `2` usage error (including an empty `--rules`/`--error-rules`, or a `--path` that matches no
  file in either tree), git failure or any file whose source could not be analysed (an unparsable
  file is never reported as success).
  """

  alias KogenCredo.Diff
  alias KogenCredo.Diff.Finding
  alias KogenCredo.Diff.Json
  alias KogenCredo.Diff.Report

  # `--path` values (default `lib/`) are relative to `--repo`, which may be a subdirectory of the
  # work tree. Umbrella roots need `--path apps/NAME/lib/` (repeatable) or `--repo apps/NAME`.
  @switches [
    repo: :string,
    path: :keep,
    format: :string,
    rules: :string,
    error_rules: :string,
    fail_on: :string,
    sensitive_field: :keep,
    cast_sensitive_field: :keep,
    repo_name: :keep
  ]

  @formats %{"text" => :text, "json" => :json, "github" => :github}
  @fail_levels %{"advisory" => :advisory, "error" => :error, "none" => :none}

  @doc "Parses `argv`, runs the diff and renders the result."
  @spec run([String.t()]) :: {String.t(), 0 | 1 | 2}
  def run(argv) do
    with {:ok, range, opts, format, fail_on} <- parse(argv),
         {:ok, report} <- Diff.run(range, opts) do
      {render(report, format), exit_code(report, fail_on)}
    else
      {:error, message} -> {"kogen.diff_check: " <> message, 2}
    end
  end

  @doc false
  @spec parse([String.t()]) ::
          {:ok, String.t(), keyword(), :text | :json | :github, :advisory | :error | :none}
          | {:error, String.t()}
  def parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [range], []} ->
        build(range, opts)

      {_, _, [{name, _} | _]} ->
        {:error, "invalid option #{name}\n\n" <> usage()}

      {_, args, []} ->
        {:error, "expected exactly one RANGE, got #{length(args)}\n\n" <> usage()}
    end
  end

  defp build(range, opts) do
    format = Keyword.get(opts, :format, "text")
    fail_on = Keyword.get(opts, :fail_on, "error")

    with :ok <- one_of(format, ~w(text json github), "--format"),
         :ok <- one_of(fail_on, ~w(advisory error none), "--fail-on"),
         {:ok, run_opts} <- run_options(opts) do
      {:ok, range, run_opts, Map.fetch!(@formats, format), Map.fetch!(@fail_levels, fail_on)}
    end
  end

  defp run_options(opts) do
    with {:ok, rules} <- rules(Keyword.get(opts, :rules)),
         {:ok, error_rules} <- rule_ids(Keyword.get(opts, :error_rules), "--error-rules"),
         {:ok, fields} <- field_options(opts) do
      paths = for {:path, p} <- opts, do: p

      run_opts =
        [repo: Keyword.get(opts, :repo, "."), severity: Map.new(error_rules, &{&1, :error})]
        |> put_unless_empty(:paths, paths)
        |> put_unless_empty(:rules, rules)
        |> put_unless_empty(:sensitive_fields, fields.sensitive)
        |> put_unless_empty(:cast_sensitive_fields, fields.cast)
        |> put_unless_empty(:repo_names, fields.repo_names)

      {:ok, run_opts}
    end
  end

  defp field_options(opts) do
    with {:ok, sensitive} <- names(opts, :sensitive_field, field_name()),
         {:ok, cast} <- names(opts, :cast_sensitive_field, field_name()),
         {:ok, repo_names} <- names(opts, :repo_name, repo_name()) do
      {:ok, %{sensitive: sensitive, cast: cast, repo_names: repo_names}}
    end
  end

  defp field_name, do: ~r/\A[a-z_][a-z0-9_]*\z/
  defp repo_name, do: ~r/\A[A-Z][A-Za-z0-9_]*\z/

  defp put_unless_empty(opts, _, []), do: opts
  defp put_unless_empty(opts, key, value), do: Keyword.put(opts, key, value)

  defp one_of(value, allowed, flag) do
    if value in allowed,
      do: :ok,
      else: {:error, "#{flag} must be one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}"}
  end

  defp rule_ids(nil, _), do: {:ok, []}

  defp rule_ids(list, flag) do
    ids = String.split(list, ",", trim: true)

    unknown = Enum.reject(ids, &match?({:ok, _}, Diff.rule_by_id(&1)))

    cond do
      ids == [] -> {:error, "#{flag} needs at least one rule id, got #{inspect(list)}"}
      unknown == [] -> {:ok, ids}
      true -> {:error, "unknown rule(s): #{Enum.join(unknown, ", ")}"}
    end
  end

  defp rules(nil), do: {:ok, []}

  defp rules(list) do
    with {:ok, ids} <- rule_ids(list, "--rules") do
      {:ok, Enum.map(ids, fn id -> elem(Diff.rule_by_id(id), 1) end)}
    end
  end

  # The values stay strings: the rules compare them by name with the atoms of the analysed code,
  # so a field or repo the code does not mention (yet) is accepted like any other valid name.
  defp names(opts, key, regex) do
    values = for {^key, v} <- opts, do: v

    case Enum.reject(values, &Regex.match?(regex, &1)) do
      [] ->
        {:ok, values}

      [bad | _] ->
        flag =
          key
          |> to_string()
          |> String.replace("_", "-")

        {:error, "invalid --#{flag} #{inspect(bad)}"}
    end
  end

  @doc false
  @spec exit_code(Report.t(), :advisory | :error | :none) :: 0 | 1 | 2
  def exit_code(%Report{errors: [_ | _]}, _), do: 2

  def exit_code(%Report{findings: findings}, fail_on) do
    blocking =
      case fail_on do
        :none -> []
        :advisory -> findings
        :error -> Enum.filter(findings, &(&1.severity == :error))
      end

    if blocking == [], do: 0, else: 1
  end

  @doc false
  @spec render(Report.t(), :text | :json | :github) :: String.t()
  def render(%Report{} = r, :text) do
    lines =
      Enum.map(r.findings, &Finding.format/1) ++
        Enum.map(r.errors, fn {file, msg} -> Finding.clean("#{file}: ERROR #{msg}") end) ++
        Enum.map(r.deleted, &Finding.clean("#{&1}: deleted, not analysed"))

    summary =
      "#{length(r.findings)} finding(s), #{length(r.errors)} error(s), #{r.files} file(s) analysed"

    lines
    |> Enum.concat([summary])
    |> Enum.join("\n")
  end

  def render(%Report{} = r, :json) do
    Json.encode(%{
      "findings" => Enum.map(r.findings, &Finding.to_map/1),
      "errors" => Enum.map(r.errors, fn {file, msg} -> %{"file" => file, "message" => msg} end),
      "deleted" => r.deleted,
      "files" => r.files
    })
  end

  def render(%Report{} = r, :github) do
    errors =
      Enum.map(r.errors, fn {file, msg} ->
        Finding.github_line("error", file, nil, "kogen.diff_check", msg)
      end)

    Enum.join(Enum.map(r.findings, &Finding.to_github/1) ++ errors, "\n")
  end

  defp usage do
    """
    usage: mix kogen.diff_check BASE..HEAD | BASE...HEAD [--repo PATH] [--path P]...
           [--format text|json|github] [--rules a,b] [--error-rules a,b]
           [--fail-on advisory|error|none] [--sensitive-field F]... [--cast-sensitive-field F]...
           [--repo-name Name]...\
    """
  end
end
