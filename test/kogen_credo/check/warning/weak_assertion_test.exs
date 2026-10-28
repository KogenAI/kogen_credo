defmodule KogenCredo.Check.Warning.WeakAssertionTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.WeakAssertion

  defp run(source, filename \\ "test/a_test.exs", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(WeakAssertion, params)
  end

  defp test_body(body),
    do: "defmodule ATest do\n  use ExUnit.Case\n  test \"x\" do\n#{body}\n  end\nend\n"

  describe "positives (sole assertion is weak)" do
    test "type predicates" do
      for pred <- ~w(is_map is_list is_binary is_atom is_struct) do
        assert [issue] = run(test_body("    assert #{pred}(compute())")), pred
        assert issue.message =~ "only checks the type"
      end
    end

    test "non-nil checks" do
      for body <- [
            "assert x != nil",
            "assert not is_nil(x)",
            "assert !is_nil(x)",
            "refute is_nil(x)",
            "refute x == nil"
          ] do
        assert [issue] = run(test_body("    " <> body)), body
        assert issue.message =~ "not nil"
      end
    end

    test "non-empty checks" do
      for body <- [
            "assert length(x) > 0",
            "assert x != []",
            "assert Enum.count(x) > 0",
            "refute x == []"
          ] do
        assert [_] = run(test_body("    " <> body)), body
      end
    end

    test "wildcard receive" do
      assert [_] = run(test_body("    send(self(), :a)\n    assert_receive _"))
      assert [_] = run(test_body("    assert_received _"))
    end

    test "every weak assertion in an all-weak test is reported" do
      assert [_, _] = run(test_body("    assert is_map(x)\n    assert x != nil"))
    end
  end

  describe "negatives and lookalikes" do
    test "weak assertion next to a strong one is not reported by default" do
      "    assert is_map(x)\n    assert x.id == 1"
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "concrete assertions pass" do
      body = """
          assert x == %{a: 1}
          assert {:ok, _} = x
          assert_receive {:done, _}
          assert_raise ArgumentError, fn -> x end
          assert length(x) == 2
          assert x != 5
      """

      body
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "custom assertion helpers count as strong" do
      "    assert is_map(x)\n    assert_valid_invoice(x)"
      |> test_body()
      |> run()
      |> refute_issues()
    end

    test "assertions outside tests are ignored" do
      "defmodule ATest do\n  def h(x), do: assert(is_map(x))\nend\n"
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "only_when_all_weak false reports each weak assertion" do
      source = test_body("    assert is_map(x)\n    assert x.id == 1")
      assert [_] = run(source, "test/a_test.exs", only_when_all_weak: false)
    end

    test "weak_predicates can be narrowed" do
      "    assert is_map(x)"
      |> test_body()
      |> run("test/a_test.exs", weak_predicates: [:is_list])
      |> refute_issues()
    end

    test "weak_helpers" do
      assert [_] =
               run(test_body("    assert_ok(x)"), "test/a_test.exs", weak_helpers: [:assert_ok])
    end

    test "non-test files are ignored" do
      "    assert is_map(x)"
      |> test_body()
      |> run("lib/a.ex")
      |> refute_issues()
    end
  end
end
