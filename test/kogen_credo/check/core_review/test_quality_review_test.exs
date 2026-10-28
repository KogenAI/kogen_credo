defmodule KogenCredo.Check.CoreReview.TestQualityTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.NoCredoDisable
  alias KogenCredo.Check.Warning.TestHasNoAssertions
  alias KogenCredo.Check.Warning.VacuousTest
  alias KogenCredo.Check.Warning.WeakAssertion

  defp run(check, source, params \\ [], filename \\ "test/a_test.exs") do
    source
    |> to_source_file(filename)
    |> run_check(check, params)
  end

  defp line_numbers(check, source, params \\ [], filename \\ "test/a_test.exs") do
    check
    |> run(source, params, filename)
    |> Enum.map(& &1.line_no)
  end

  defp wrap(body),
    do: "defmodule ATest do\n  use ExUnit.Case\n  test \"t\" do\n#{indent(body)}\n  end\nend\n"

  defp indent(body) do
    body
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  describe "VacuousTest" do
    test "constants evaluate only from literals and pure operators" do
      for src <- [
            "assert true",
            "assert 1 == 1",
            "refute false",
            "assert \"a\" <> \"b\" == \"ab\"",
            "assert 1 in [1, 2]",
            "refute nil"
          ] do
        assert [_] = run(VacuousTest, wrap(src)), src
      end

      for src <- [
            "assert false",
            "assert nil",
            "refute true",
            "assert x == 1",
            "assert System.get_env(\"A\") == nil",
            "assert 1 == 2"
          ] do
        assert [] == run(VacuousTest, wrap(src)), src
      end
    end

    test "self comparison direction depends on assert/refute" do
      assert [_] = run(VacuousTest, wrap("x = f()\nassert x == x"))
      assert [_] = run(VacuousTest, wrap("x = f()\nassert x.a >= x.a"))
      assert [_] = run(VacuousTest, wrap("x = f()\nrefute x != x"))
      assert [] == run(VacuousTest, wrap("x = f()\nassert x != x"))
      assert [] == run(VacuousTest, wrap("x = f()\nrefute x == x"))
      assert [] == run(VacuousTest, wrap("x = f()\ny = g()\nassert x == y"))
      assert [] == run(VacuousTest, wrap("assert f() == f()"))
    end

    test "or true on either side" do
      assert [_] = run(VacuousTest, wrap("assert f() or true"))
      assert [_] = run(VacuousTest, wrap("assert true || f()"))
      assert [] == run(VacuousTest, wrap("assert f() and true"))
    end

    test "binding match is reported, with an honest message, and can be allowed" do
      [issue] = run(VacuousTest, wrap("assert x = f()"))
      assert issue.message =~ "truthy"
      refute issue.message =~ "never fail"
      assert [] == run(VacuousTest, wrap("assert x = f()"), allow_binding_match: true)
      assert [] == run(VacuousTest, wrap("assert {:ok, x} = f()"))
      assert [] == run(VacuousTest, wrap("assert ^x = f()"))
    end

    test "match?(var, expr) is vacuous even when binding matches are allowed" do
      assert [_] = run(VacuousTest, wrap("assert match?(_, f())"), allow_binding_match: true)
      assert [] == run(VacuousTest, wrap("assert match?({:ok, _}, f())"))
    end

    test "assertions in describe blocks, setup-less non-test code and non-test files" do
      source = """
      defmodule ATest do
        use ExUnit.Case

        describe "d" do
          test "t", do: assert(true)
        end

        def helper, do: assert(true)
      end
      """

      assert [%{line_no: 5}] = run(VacuousTest, source)
      assert [] == run(VacuousTest, source, [], "lib/a.ex")
      assert [_] = run(VacuousTest, source, [file_suffixes: ["_spec.exs"]], "test/a_spec.exs")
    end

    test "custom test macros" do
      source = "defmodule ATest do\n  property \"p\" do\n    assert true\n  end\nend"
      assert [] == run(VacuousTest, source)
      assert [_] = run(VacuousTest, source, test_macros: [:property])
    end
  end

  describe "WeakAssertion" do
    test "weak shapes" do
      for src <- [
            "assert is_map(f())",
            "assert f() != nil",
            "assert nil != f()",
            "assert not is_nil(f())",
            "assert !is_nil(f())",
            "refute is_nil(f())",
            "refute f() == nil",
            "assert length(f()) > 0",
            "assert length(f()) >= 1",
            "assert map_size(f()) > 0",
            "assert Enum.count(f()) > 0",
            "assert f() != []",
            "assert f() != %{}",
            "refute f() == []",
            "refute Enum.empty?(f())",
            "assert_receive _",
            "assert_received _"
          ] do
        assert [_] = run(WeakAssertion, wrap(src)), src
      end
    end

    test "strong shapes are not reported" do
      for src <- [
            "assert f() == %{a: 1}",
            "assert %{a: 1} = f()",
            "assert length(f()) == 2",
            "assert_receive {:done, _}",
            "assert is_struct(f(), Foo)",
            "assert is_function(f(), 1)",
            "assert_raise ArgumentError, fn -> f() end",
            "refute f() == 1"
          ] do
        assert [] == run(WeakAssertion, wrap(src)), src
      end
    end

    test "a test is judged as a whole by default, assert-per-assert on request" do
      body = "assert is_map(f())\nassert f().a == 1"
      assert [] == run(WeakAssertion, wrap(body))
      assert [_] = run(WeakAssertion, wrap(body), only_when_all_weak: false)
    end

    test "custom helpers: weak_helpers lowers, assertion_helpers raises the test's strength" do
      body = "assert is_map(f())\ncheck_shape(f())"
      assert [_] = run(WeakAssertion, wrap(body))
      assert [] == run(WeakAssertion, wrap(body), assertion_helpers: [:check_shape])
      # still reported when asked per assertion
      assert [_] =
               run(WeakAssertion, wrap(body),
                 assertion_helpers: [:check_shape],
                 only_when_all_weak: false
               )

      assert [_] = run(WeakAssertion, wrap("assert_ok(f())"), weak_helpers: [:assert_ok])
      assert [] == run(WeakAssertion, wrap("assert_ok(f())"))
    end

    test "piped assertions are understood" do
      assert [_] = run(WeakAssertion, wrap("f() |> is_map() |> assert()"))
    end

    test "reports the line of each weak assertion" do
      source = """
      defmodule ATest do
        use ExUnit.Case

        test "a" do
          assert is_map(f())
          assert is_list(g())
        end
      end
      """

      assert [5, 6] = line_numbers(WeakAssertion, source)
    end

    test "malformed params raise" do
      source_file = to_source_file("x = 1", "test/a_test.exs")

      assert_raise ArgumentError, fn ->
        WeakAssertion.run(source_file, weak_predicates: ["is_map"])
      end
    end
  end

  describe "TestHasNoAssertions" do
    test "assertion forms" do
      for src <- [
            "assert f()",
            "refute f()",
            "assert_receive :x",
            "assert_raise ArgumentError, fn -> f() end",
            "flunk(\"no\")",
            "{:ok, _} = f()",
            "%{a: 1} = f()",
            "f() |> assert()",
            "ExUnit.Assertions.assert(f())",
            "MyApp.Assertions.assert_ok(f())",
            "expect(Mock, :f, fn -> 1 end)\nf()",
            "verify_on_exit!()\nf()",
            "verify!()\nf()"
          ] do
        assert [] == run(TestHasNoAssertions, wrap(src)), src
      end
    end

    test "non-assertions" do
      for src <- [
            "f()",
            "x = f()",
            "_ = f()",
            "expected(f())",
            "verification_result(f())",
            "MyApp.Verify.verify(f())",
            "# only a comment",
            ""
          ] do
        assert [_] = run(TestHasNoAssertions, wrap(src)), src
      end
    end

    test "count_pattern_matches: false and custom helper names" do
      assert [_] = run(TestHasNoAssertions, wrap("{:ok, _} = f()"), count_pattern_matches: false)
      assert [] == run(TestHasNoAssertions, wrap("check_it(f())"), assertion_helpers: [:check_it])
      assert [] == run(TestHasNoAssertions, wrap("must_hold(f())"), assertion_prefixes: ["must_"])

      assert [] == run(TestHasNoAssertions, wrap("must_hold(f())"), assertion_prefixes: ["must"])
      assert [_] = run(TestHasNoAssertions, wrap("musty(f())"), assertion_prefixes: ["must"])
    end

    test "pending tests, other files and dynamic names" do
      assert [] ==
               run(
                 TestHasNoAssertions,
                 "defmodule ATest do\n  use ExUnit.Case\n  test \"todo\"\nend"
               )

      assert [] == run(TestHasNoAssertions, wrap("f()"), [], "lib/a.ex")

      source = """
      defmodule ATest do
        use ExUnit.Case

        for n <- 1..2 do
          test "case \#{n}" do
            f(unquote(n))
          end
        end
      end
      """

      assert [%{message: m}] = run(TestHasNoAssertions, source)
      assert m =~ "(dynamic name)"
    end
  end

  describe "NoCredoDisable" do
    test "only real comments that Credo itself would honour are reported" do
      source = ~S'''
      defmodule A do
        @moduledoc """
        # credo:disable-for-this-file
        """

        def f, do: "# credo:disable-for-next-line"

        # credo:disable-for-next-line
        def g, do: 1

        # note: credo:disable-for-next-line is not a directive here
        def h, do: 2

        def i, do: 3 # credo:disable-for-lines:3
      end
      '''

      assert [8, 14] = line_numbers(NoCredoDisable, source, [], "lib/a.ex")
    end

    test "allowed directives, including disable-for-lines:N by base name" do
      source = "# credo:disable-for-lines:5\nx = 1\n# credo:disable-for-next-line\ny = 2\n"
      assert [_, _] = run(NoCredoDisable, source, [], "lib/a.ex")

      assert [%{line_no: 3}] =
               run(
                 NoCredoDisable,
                 source,
                 [allowed_directives: ["disable-for-lines"]],
                 "lib/a.ex"
               )

      assert [] ==
               run(
                 NoCredoDisable,
                 source,
                 [allowed_directives: ["disable-for-lines:5", "disable-for-next-line"]],
                 "lib/a.ex"
               )
    end

    test "allowed_checks only exempt directives that name only allowed checks" do
      source = """
      # credo:disable-for-next-line Credo.Check.Readability.Specs
      x = 1
      # credo:disable-for-next-line Credo.Check.Readability.Specs Credo.Check.Design.TagTODO
      y = 2
      # credo:disable-for-next-line
      z = 3
      """

      params = [allowed_checks: ["Credo.Check.Readability.Specs"]]
      assert [3, 5] = line_numbers(NoCredoDisable, source, params, "lib/a.ex")
    end

    test "the message states the advisory limit" do
      [issue] = run(NoCredoDisable, "# credo:disable-for-this-file\n", [], "lib/a.ex")
      assert issue.message =~ "Advisory"
    end
  end
end
