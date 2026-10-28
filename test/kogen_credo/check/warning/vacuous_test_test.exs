defmodule KogenCredo.Check.Warning.VacuousTestTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.VacuousTest

  defp run(source, filename \\ "test/a_test.exs", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(VacuousTest, params)
  end

  defp test_body(body),
    do: "defmodule ATest do\n  use ExUnit.Case\n  test \"x\" do\n#{body}\n  end\nend\n"

  describe "positives" do
    test "constant assertions" do
      for body <- [
            "assert true",
            "assert 1 == 1",
            "refute false",
            "assert \"a\" <> \"b\" == \"ab\"",
            "assert :a in [:a]"
          ] do
        assert [_] = run(test_body("    " <> body)), body
      end
    end

    test "message names the offending assertion" do
      [issue] = run(test_body("    assert 1 == 1"))
      assert issue.message =~ "`1 == 1` is constant"
      assert issue.line_no == 4
    end

    test "comparison of a value with itself" do
      assert [_] = run(test_body("    assert result == result"))
      assert [_] = run(test_body("    assert user.name == user.name"))
    end

    test "or true" do
      assert [_] = run(test_body("    assert result or true"))
      assert [_] = run(test_body("    assert result || true"))
    end

    test "match assertions that can never fail" do
      assert [_] = run(test_body("    assert _ = compute()"))
      assert [_] = run(test_body("    assert value = compute()"))
      assert [_] = run(test_body("    assert match?(_, compute())"))
    end

    test "assert var = expr is the assert-and-keep idiom when var is used later" do
      "    assert token = compute()\n    assert Repo.get_by(Token, token: token)"
      |> test_body()
      |> run()
      |> refute_issues()

      "    assert html = render()\n    assert html =~ \"ok\""
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "an unused or underscored binding is still reported" do
      assert [_] = run(test_body("    assert token = compute()\n    assert other"))
      assert [_] = run(test_body("    assert _token = compute()\n    assert _token"))
    end

    test "allow_binding_match skips plain binding" do
      "    assert value = compute()"
      |> test_body()
      |> run("test/a_test.exs", allow_binding_match: true)
      |> refute_issues()

      "    assert _ = compute()"
      |> test_body()
      |> run("test/a_test.exs", allow_binding_match: true)
      |> refute_issues()
    end
  end

  describe "negatives and lookalikes" do
    test "real assertions pass" do
      body = """
          assert compute() == 3
          assert {:ok, _} = compute()
          assert %{id: ^id} = compute()
          refute compute() == nil
          assert match?({:ok, _}, compute())
          assert 1 + 1 == compute()
      """

      body
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "calling the same function twice is a determinism check, not vacuous" do
      "    assert compute() == compute()"
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "constant assertions that fail are not reported as vacuous" do
      "    refute true"
      |> test_body()
      |> run()
      |> refute_issues()

      "    assert false"
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "assertions outside test blocks are not inspected" do
      source = "defmodule ATest do\n  def helper, do: assert(true)\nend\n"

      source
      |> run()
      |> refute_issues()
    end
  end

  describe "scope" do
    test "non-test files are ignored" do
      "    assert true"
      |> test_body()
      |> run("lib/a.ex")
      |> refute_issues()
    end

    test "test_macros adds property-like macros" do
      source = "defmodule ATest do\n  property \"x\" do\n    assert true\n  end\nend\n"

      source
      |> run()
      |> refute_issues()

      assert [_] = run(source, "test/a_test.exs", test_macros: [:test, :property])
    end
  end
end
