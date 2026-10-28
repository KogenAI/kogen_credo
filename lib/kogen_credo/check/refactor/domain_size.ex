defmodule KogenCredo.Check.Refactor.DomainSize do
  @moduledoc """
  Caps the total number of lines per domain. Configure `domains`; without it the
  check does nothing.

      {KogenCredo.Check.Refactor.DomainSize,
       domains: [
         [name: "billing", paths: ["lib/my_app/billing", "lib/my_app/billing.ex"]],
         [name: "kernel", paths: ["lib/my_app/kernel"], max_lines: 600]
       ],
       max_lines: 3000}

  A domain's size is the sum of lines of all analysed files under its `paths`
  (a file belongs to the first matching domain). A domain's own `max_lines`
  overrides the default. The issue is anchored at the domain's largest file.

  Set `count_blank_and_comment_lines: false` to count only lines with code.

  ## Limitations

  Only files that Credo analyses are counted, so `files.included`/`excluded` in
  `.credo.exs` affect totals. A line count is a proxy for how much a domain does.
  A malformed domain entry raises `ArgumentError`.
  """

  use Credo.Check,
    category: :refactor,
    base_priority: :low,
    param_defaults: [domains: [], max_lines: 3000, count_blank_and_comment_lines: true],
    explanations: [
      check: """
      A domain over its ceiling does too much. Re-slice it into smaller domains instead of raising the
      limit. Configure each domain's `paths` and optional `max_lines`.
      """,
      params: [
        domains: "List of `[name:, paths:, max_lines: n]`. Empty disables the check.",
        max_lines: "Default maximum lines per domain.",
        count_blank_and_comment_lines: "When false only lines with code are counted."
      ]
    ]

  alias Credo.Execution.ExecutionIssues
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Settings

  @impl Credo.Check
  def run_on_all_source_files(exec, source_files, params) do
    domains =
      params
      |> Params.get(:domains, __MODULE__)
      |> domains!()

    default =
      params
      |> Params.get(:max_lines, __MODULE__)
      |> Settings.integer!(:max_lines, 1)

    all? = Params.get(params, :count_blank_and_comment_lines, __MODULE__)

    if domains != [] do
      source_files
      |> counted_files(domains, all?)
      |> Enum.group_by(fn {domain, _, _} -> domain end, fn {_, sf, n} -> {sf, n} end)
      |> Enum.each(&report_domain(&1, default, params, exec))
    end

    :ok
  end

  defp counted_files(source_files, domains, all?) do
    Enum.flat_map(source_files, fn sf ->
      case Enum.find(domains, &Paths.in_paths?(sf.filename, &1.paths)) do
        nil -> []
        domain -> [{domain, sf, count(sf, all?)}]
      end
    end)
  end

  defp report_domain({domain, files}, default, params, exec) do
    total =
      files
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    limit = domain.max_lines || default

    if total > limit do
      issue = domain_issue(domain, files, {total, limit}, params)
      ExecutionIssues.append(exec, issue)
    end
  end

  defp domain_issue(domain, files, {total, limit}, params) do
    {sf, largest} = Enum.max_by(files, &elem(&1, 1))

    format_issue(IssueMeta.for(sf, params),
      message:
        "Domain `#{domain.name}` has #{total} lines (max #{limit}) across #{length(files)} files; " <>
          "this is the largest (#{largest} lines). Re-slice the domain instead of raising the limit.",
      line_no: 1,
      trigger: domain.name
    )
  end

  @impl Credo.Check
  def run(_, _), do: []

  defp domains!(domains) when is_list(domains), do: Enum.map(domains, &normalize/1)
  defp domains!(other), do: Settings.raise_bad(:domains, other, "a list of domain entries")

  defp normalize(domain) do
    Settings.known_keys!(domain, [:name, :paths, :max_lines], "DomainSize domain")

    unless is_binary(domain[:name]) and is_list(domain[:paths]) and domain[:paths] != [] do
      raise ArgumentError,
            "DomainSize domain needs :name (string) and :paths (non-empty list), got: #{inspect(domain)}"
    end

    max = domain[:max_lines]
    unless is_nil(max), do: Settings.integer!(max, :max_lines, 1)

    %{
      name: domain[:name],
      paths: Settings.strings!(domain[:paths], :paths),
      max_lines: max
    }
  end

  defp count(sf, true) do
    sf
    |> SourceFile.source()
    |> String.split("\n")
    |> trim_final()
    |> length()
  end

  defp count(sf, false) do
    sf
    |> SourceFile.source()
    |> String.split("\n")
    |> Enum.count(fn l ->
      t = String.trim(l)
      t != "" and not String.starts_with?(t, "#")
    end)
  end

  defp trim_final(lines), do: if(List.last(lines) == "", do: Enum.drop(lines, -1), else: lines)
end
