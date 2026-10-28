defmodule KogenCredo.Check.Refactor.DomainSizeTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Refactor.DomainSize

  @domains [
    [name: "billing", paths: ["lib/shop/billing", "lib/shop/billing.ex"]],
    [name: "kernel", paths: ["lib/shop/kernel"], max_lines: 5]
  ]

  defp file(name, lines),
    do: to_source_file("# padding\n" <> String.duplicate("# line\n", lines - 1), name)

  defp run(files, params), do: run_check(files, DomainSize, params)

  test "reports a domain over the default limit, anchored at its largest file" do
    files = [
      file("lib/shop/billing/a.ex", 6),
      file("lib/shop/billing/b.ex", 3),
      file("lib/shop/other.ex", 50)
    ]

    [issue] = run(files, domains: @domains, max_lines: 8)

    assert issue.filename == "lib/shop/billing/a.ex"
    assert issue.message =~ "Domain `billing` has 9 lines (max 8) across 2 files"
  end

  test "a domain at its limit passes" do
    files = [file("lib/shop/billing/a.ex", 8)]

    files
    |> run(domains: @domains, max_lines: 8)
    |> refute_issues()
  end

  test "per-domain max_lines overrides the default" do
    files = [file("lib/shop/kernel/a.ex", 6)]
    [issue] = run(files, domains: @domains, max_lines: 1000)
    assert issue.message =~ "Domain `kernel` has 6 lines (max 5)"
  end

  test "a single-file domain path matches the file" do
    files = [file("lib/shop/billing.ex", 10)]
    assert [_] = run(files, domains: @domains, max_lines: 8)
  end

  test "files outside every domain are not counted" do
    files = [file("lib/shop/billing_extras/a.ex", 500)]

    files
    |> run(domains: @domains, max_lines: 8)
    |> refute_issues()
  end

  test "count_blank_and_comment_lines false counts only code" do
    code =
      to_source_file("defmodule A do\n\n  # c\n  def f, do: 1\nend\n", "lib/shop/billing/a.ex")

    assert [_] = run([code], domains: @domains, max_lines: 4)

    [code]
    |> run(domains: @domains, max_lines: 4, count_blank_and_comment_lines: false)
    |> refute_issues()
  end

  test "disabled without domains" do
    refute_issues(run([file("lib/shop/billing/a.ex", 9000)], []))
  end

  test "malformed domain raises" do
    assert_raise ArgumentError, ~r/needs :name/, fn ->
      DomainSize.run_on_all_source_files(Credo.Execution.build(), [file("lib/a.ex", 1)],
        domains: [[paths: ["lib"]]]
      )
    end
  end
end
