defmodule KogenCredo.Check.Readability.JustifiedCoverageIgnoreTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Readability.JustifiedCoverageIgnore

  test "bare coveralls-ignore-next-line fails" do
    """
    defmodule MyModule do
      def some_fn do
        # coveralls-ignore-next-line
        :ok
      end
    end
    """
    |> to_source_file("lib/my_module.ex")
    |> run_check(JustifiedCoverageIgnore)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Coverage ignore marker lacks reason"
    end)
  end

  test "bare coveralls-ignore-start fails" do
    """
    defmodule MyModule do
      def some_fn do
        # coveralls-ignore-start
        :ok
        # coveralls-ignore-stop
      end
    end
    """
    |> to_source_file("lib/my_module.ex")
    |> run_check(JustifiedCoverageIgnore)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Coverage ignore marker lacks reason"
    end)
  end

  test "justified coveralls-ignore-next-line passes" do
    """
    defmodule MyModule do
      def some_fn do
        # coveralls-ignore-next-line: Shell git not-found branch
        :ok
      end
    end
    """
    |> to_source_file("lib/my_module.ex")
    |> run_check(JustifiedCoverageIgnore)
    |> refute_issues()
  end

  test "justified coveralls-ignore-start passes" do
    """
    defmodule MyModule do
      def some_fn do
        # coveralls-ignore-start: OS subprocess glue, exercised by make llm integration
        :ok
        # coveralls-ignore-stop
      end
    end
    """
    |> to_source_file("lib/my_module.ex")
    |> run_check(JustifiedCoverageIgnore)
    |> refute_issues()
  end

  test "grace period active — bare marker passes" do
    far_future = iso_date_from_today(30)

    """
    defmodule MyModule do
      def some_fn do
        # coveralls-ignore-next-line
        :ok
      end
    end
    """
    |> to_source_file("lib/my_module.ex")
    |> run_check(JustifiedCoverageIgnore, allow_bare_until: far_future)
    |> refute_issues()
  end

  test "grace period expired — bare marker fails" do
    past = iso_date_from_today(-1)

    """
    defmodule MyModule do
      def some_fn do
        # coveralls-ignore-next-line
        :ok
      end
    end
    """
    |> to_source_file("lib/my_module.ex")
    |> run_check(JustifiedCoverageIgnore, allow_bare_until: past)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Coverage ignore marker lacks reason"
    end)
  end

  test "coveralls-ignore-stop line is not flagged" do
    """
    defmodule MyModule do
      def some_fn do
        # coveralls-ignore-stop
        :ok
      end
    end
    """
    |> to_source_file("lib/my_module.ex")
    |> run_check(JustifiedCoverageIgnore)
    |> refute_issues()
  end

  test "reports correct line number" do
    """
    defmodule MyModule do
      def some_fn do
        # coveralls-ignore-next-line
        :ok
      end
    end
    """
    |> to_source_file("lib/my_module.ex")
    |> run_check(JustifiedCoverageIgnore)
    |> assert_issue(fn issue ->
      assert issue.line_no == 3
    end)
  end

  defp iso_date_from_today(days) do
    Date.utc_today()
    |> Date.add(days)
    |> Date.to_iso8601()
  end
end
