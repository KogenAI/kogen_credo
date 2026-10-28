defmodule KogenCredo.ParserOutputTest do
  use Credo.Test.Case, async: false
  import ExUnit.CaptureIO

  test "comment extraction does not print deprecation warnings from inspected code" do
    source =
      to_source_file(
        """
        defmodule ParserProbe do
          @tag :skip # a documented reason
          def value, do: 'legacy'
          # credo:disable-for-next-line
          def another, do: 'legacy'
        end
        """,
        "test/parser_probe_test.exs"
      )

    for {check, params} <- [
          {KogenCredo.Check.Warning.SkippedTest, [allow_with_comment: true]},
          {KogenCredo.Check.Warning.NoCredoDisable, []}
        ] do
      assert capture_io(:stderr, fn -> check.run(source, params) end) == ""
    end
  end
end
