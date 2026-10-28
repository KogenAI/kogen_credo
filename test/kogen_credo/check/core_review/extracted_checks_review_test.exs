defmodule KogenCredo.Check.CoreReview.ExtractedChecksTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Readability.EmptySetupBlock
  alias KogenCredo.Check.Readability.JustifiedCoverageIgnore
  alias KogenCredo.Check.Warning.RuntimeEnvDevDefault
  alias KogenCredo.Check.Warning.SkippedTest

  defp run(check, source, params \\ [], filename \\ "test/a_test.exs") do
    source
    |> to_source_file(filename)
    |> run_check(check, params)
  end

  describe "SkippedTest" do
    defp in_module(tag_line),
      do:
        "defmodule ATest do\n  use ExUnit.Case\n\n  #{tag_line}\n  test \"t\", do: assert(true)\nend\n"

    test "keyword options: skip among other options is found, skip false/nil is not" do
      assert [_] = run(SkippedTest, in_module("@tag skip: true, timeout: 1000"))
      assert [_] = run(SkippedTest, in_module("@tag timeout: 1000, skip: \"flaky\""))
      assert [_] = run(SkippedTest, in_module("@tag [:integration, :skip]"))
      assert [] == run(SkippedTest, in_module("@tag skip: false"))
      assert [] == run(SkippedTest, in_module("@tag skip: nil"))
      assert [] == run(SkippedTest, in_module("@tag [:integration, timeout: 10]"))
      assert [] == run(SkippedTest, in_module("@tag :skipped_before"))
    end

    test "@describetag :skip skips a whole describe" do
      assert [%{message: m}] = run(SkippedTest, in_module("@describetag :skip"))
      assert m =~ "describe"
    end

    test "allow_with_comment needs a real comment: a # inside a string is not one" do
      with_comment = in_module("@tag :skip # tracked in #123")
      with_string = in_module("@tag skip: \"see #123\"")

      assert [] == run(SkippedTest, with_comment, allow_with_comment: true)
      assert [_] = run(SkippedTest, with_string, allow_with_comment: true)
      assert [_] = run(SkippedTest, in_module("@tag :skip #"), allow_with_comment: true)
      assert [_] = run(SkippedTest, with_comment)
    end
  end

  describe "RuntimeEnvDevDefault" do
    test "a piped System.get_env default is the same call" do
      source = "import Config\ndir = \"CODEGEN_DIR\" |> System.get_env(\"/Users/me/codegen\")\n"
      assert [%{line_no: 2}] = run(RuntimeEnvDevDefault, source, [], "config/runtime.exs")
      assert [] == run(RuntimeEnvDevDefault, source, [], "config/dev.exs")

      assert [] ==
               run(
                 RuntimeEnvDevDefault,
                 "x = \"K\" |> System.get_env()",
                 [],
                 "config/runtime.exs"
               )
    end
  end

  describe "JustifiedCoverageIgnore" do
    test "a malformed allow_bare_until raises instead of being ignored" do
      source = to_source_file("# coveralls-ignore-next-line\nx = 1\n", "lib/a.ex")

      assert_raise ArgumentError, ~r/allow_bare_until must be an ISO 8601 date/, fn ->
        JustifiedCoverageIgnore.run(source, allow_bare_until: "next tuesday")
      end

      assert_raise ArgumentError, ~r/allow_bare_until/, fn ->
        JustifiedCoverageIgnore.run(source, allow_bare_until: 20_260_526)
      end
    end

    test "a valid past date keeps flagging, a future date grants the grace period" do
      source = "# coveralls-ignore-next-line\nx = 1\n"

      assert [_] =
               run(JustifiedCoverageIgnore, source, [allow_bare_until: "2000-01-01"], "lib/a.ex")

      assert [] ==
               run(JustifiedCoverageIgnore, source, [allow_bare_until: "2999-01-01"], "lib/a.ex")
    end
  end

  describe "EmptySetupBlock" do
    test "setup with a real body, in a describe block, is not reported; an empty one is" do
      source = """
      defmodule ATest do
        use ExUnit.Case

        describe "d" do
          setup do
            :ok
          end

          setup do
            {:ok, a: 1}
          end

          test "t", do: assert(true)
        end
      end
      """

      assert [%{line_no: 5}] = run(EmptySetupBlock, source)
    end
  end
end
