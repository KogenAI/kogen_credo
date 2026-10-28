defmodule KogenCredo.Check.Warning.TestHasNoAssertionsTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.TestHasNoAssertions

  defp run(source, filename \\ "test/a_test.exs", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(TestHasNoAssertions, params)
  end

  defp test_body(body),
    do: "defmodule ATest do\n  use ExUnit.Case\n  test \"does things\" do\n#{body}\n  end\nend\n"

  describe "positives" do
    test "test that only calls code" do
      [issue] = run(test_body("    compute()\n    other()"))
      assert issue.message =~ ~s(Test "does things" has no assertion)
      assert issue.line_no == 3
    end

    test "only binds a variable" do
      assert [_] = run(test_body("    result = compute()\n    _ = result"))
    end

    test "empty-ish body" do
      assert [_] = run(test_body("    :ok"))
    end

    test "each assertion-free test is reported separately" do
      source = """
      defmodule ATest do
        use ExUnit.Case
        test "a" do
          compute()
        end
        test "b" do
          assert compute() == 1
        end
        test "c", %{conn: conn} do
          get(conn, "/")
        end
      end
      """

      assert [a, c] = run(source)
      assert {a.line_no, c.line_no} == {3, 9}
    end
  end

  describe "negatives and lookalikes" do
    test "assert, refute and assert_* count" do
      for body <- [
            "assert x",
            "refute x",
            "assert_raise ArgumentError, fn -> x end",
            "assert_receive :a",
            "refute_receive :a"
          ] do
        ("    " <> body)
        |> test_body()
        |> run()
        |> refute_issues()
      end
    end

    test "assertion nested in a closure or pipe" do
      "    Enum.each(list, fn x -> assert x end)"
      |> test_body()
      |> run()
      |> refute_issues()

      "    compute() |> assert_ok()"
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "Mox style verification and flunk" do
      "    expect(Mock, :call, fn -> :ok end)\n    run()"
      |> test_body()
      |> run()
      |> refute_issues()

      "    verify!()"
      |> test_body()
      |> run()
      |> refute_issues()

      "    flunk(\"boom\")"
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "destructuring match counts, plain binding does not" do
      "    {:ok, user} = create()"
      |> test_body()
      |> run()
      |> refute_issues()

      "    %{id: ^id} = fetch(id)"
      |> test_body()
      |> run()
      |> refute_issues()

      assert [_] = run(test_body("    user = create()"))
    end

    test "pending tests without a body are not reported" do
      "defmodule ATest do\n  use ExUnit.Case\n  test \"todo\"\nend\n"
      |> run()
      |> refute_issues()
    end

    test "functions that are not tests" do
      "defmodule ATest do\n  def helper, do: compute()\nend\n"
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "assertion_helpers" do
      source = test_body("    check_invoice(x)")
      assert [_] = run(source)

      source
      |> run("test/a_test.exs", assertion_helpers: [:check_invoice])
      |> refute_issues()
    end

    test "assertion_prefixes" do
      source = test_body("    must_have(x)")

      source
      |> run("test/a_test.exs", assertion_prefixes: ["must_"])
      |> refute_issues()
    end

    test "count_pattern_matches false" do
      assert [_] =
               run(test_body("    {:ok, user} = create()"), "test/a_test.exs",
                 count_pattern_matches: false
               )
    end

    test "non-test files are ignored" do
      "    compute()"
      |> test_body()
      |> run("lib/a.ex")
      |> refute_issues()
    end
  end
end
