defmodule KogenCredo.Check.Warning.NoCredoDisableTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.NoCredoDisable

  defp run(source, params \\ []) do
    source
    |> to_source_file("lib/a.ex")
    |> run_check(NoCredoDisable, params)
  end

  describe "positives" do
    test "all disable directives" do
      source = """
      # credo:disable-for-this-file
      defmodule A do
        # credo:disable-for-next-line
        def f, do: 1
        def g, do: 2 # credo:disable-for-previous-line
        # credo:disable-for-lines:3
        def h, do: 3
      end
      """

      assert [first | _] = issues = run(source)
      assert length(issues) == 4
      assert first.message =~ "credo:disable-for-this-file"
      assert first.message =~ "Advisory"
    end

    test "disable naming a check" do
      assert [_] =
               run(
                 "# credo:disable-for-next-line Credo.Check.Readability.Specs\ndefmodule A do\nend\n"
               )
    end
  end

  describe "Credo's case-insensitive prefix" do
    test "reports `credo` in any case, as Credo's own comment finder honours it" do
      for prefix <- ["CREDO", "Credo", "cReDo"] do
        source = "defmodule A do\n  # #{prefix}:disable-for-next-line\n  def f, do: 1\nend\n"
        assert [issue] = run(source), "#{prefix} was not reported"
        assert issue.line_no == 2
        assert issue.trigger == "credo:disable-for-next-line"
      end

      assert [_] = run("# CREDO:disable-for-this-file\ndefmodule A do\nend\n")
    end

    test "the instruction stays case-sensitive, like Credo's literal comparison" do
      "# credo:DISABLE-FOR-THIS-FILE\ndefmodule A do\nend\n"
      |> run()
      |> refute_issues()
    end

    test "allowed_directives still applies to case variants" do
      source = "# Credo:disable-for-next-line\ndefmodule A do\nend\n"

      source
      |> run(allowed_directives: ["disable-for-next-line"])
      |> refute_issues()
    end

    test "signed disable-for-lines counts are reported" do
      assert [_] = run("defmodule A do\n  # credo:disable-for-lines:+2\n  def f, do: 1\nend\n")
      assert [_] = run("defmodule A do\n  # credo:disable-for-lines:-2\n  def f, do: 1\nend\n")
    end

    test "case-variant text inside strings is still not a comment" do
      (~S'defmodule A do; def f, do: "# CREDO:disable-for-this-file"; end' <> "\n")
      |> run()
      |> refute_issues()
    end
  end

  describe "negatives and lookalikes" do
    test "directive text inside strings and heredocs is not a comment" do
      source = ~S'''
      defmodule A do
        @moduledoc """
        Use # credo:disable-for-next-line sparingly.
        """
        def f, do: "# credo:disable-for-this-file"
      end
      '''

      source
      |> run()
      |> refute_issues()
    end

    test "unrelated comments and credo:enable-like text" do
      "# credo is great\n# credo:something-else\ndefmodule A do\nend\n"
      |> run()
      |> refute_issues()
    end
  end

  describe "params" do
    test "allowed_directives" do
      source =
        "# credo:disable-for-next-line\ndefmodule A do\nend\n# credo:disable-for-this-file\n"

      assert [issue] = run(source, allowed_directives: ["disable-for-next-line"])
      assert issue.line_no == 4
    end

    test "allowed_checks accepts directives naming only allowed checks" do
      source =
        "# credo:disable-for-next-line Credo.Check.Readability.Specs\ndefmodule A do\nend\n"

      source
      |> run(allowed_checks: ["Credo.Check.Readability.Specs"])
      |> refute_issues()

      assert [_] = run(source, allowed_checks: ["Credo.Check.Other"])
    end

    test "a bare directive is not covered by allowed_checks" do
      assert [_] =
               run("# credo:disable-for-next-line\ndefmodule A do\nend\n", allowed_checks: ["X"])
    end
  end
end
