defmodule KogenCredo.Check.Refactor.SizeLimitsTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Refactor.SizeLimits

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(SizeLimits, params)
  end

  defp function(n) do
    body = Enum.map_join(1..n, "\n", &"    x#{&1} = #{&1}")
    "defmodule A do\n  def f do\n#{body}\n  end\nend\n"
  end

  describe "HEEx templates" do
    defp component(rows) do
      markup = Enum.map_join(1..rows, "\n", &"      <p>row #{&1}</p>")

      """
      defmodule A do
        def card(assigns) do
          ~H\"\"\"
      #{markup}
          \"\"\"
        end
      end
      """
    end

    test "template markup does not count toward function length" do
      60
      |> component()
      |> run("lib/a.ex", max_function_lines: 10)
      |> refute_issues()
    end

    test "count_template_lines true counts the markup" do
      assert [issue] =
               run(component(60), "lib/a.ex", max_function_lines: 10, count_template_lines: true)

      assert issue.message =~ "def card/1 spans 64 lines"
    end

    test "logic next to a template still counts" do
      logic = Enum.map_join(1..20, "\n", &"    x#{&1} = #{&1}")

      source = """
      defmodule A do
        def card(assigns) do
      #{logic}
          ~H\"\"\"
          <p>a</p>
          <p>b</p>
          \"\"\"
        end
      end
      """

      assert [issue] = run(source, "lib/a.ex", max_function_lines: 20)
      assert issue.message =~ "def card/1 spans 24 lines"
    end

    test "module and file counts stay raw" do
      assert [_, _] = run(component(60), "lib/a.ex", max_file_lines: 30, max_module_lines: 30)
    end
  end

  describe "functions" do
    test "function over the limit is reported" do
      [issue] = run(function(10), "lib/a.ex", max_function_lines: 5)
      assert issue.message =~ "def f/0 spans 12 lines (max 5)"
      assert issue.line_no == 2
    end

    test "function at the limit passes" do
      3
      |> function()
      |> run("lib/a.ex", max_function_lines: 5)
      |> refute_issues()
    end

    test "defp and defmacro are covered; each clause counts separately" do
      source = """
      defmodule A do
        defp g(1) do
          a = 1
          b = 2
          a + b
        end

        defp g(2), do: 2
      end
      """

      assert [issue] = run(source, "lib/a.ex", max_function_lines: 4)
      assert issue.message =~ "defp g/1"
    end

    test "count_blank_and_comment_lines false ignores padding" do
      source = "defmodule A do\n  def f do\n\n    # note\n\n    1\n  end\nend\n"
      assert [_] = run(source, "lib/a.ex", max_function_lines: 4)

      source
      |> run("lib/a.ex", max_function_lines: 4, count_blank_and_comment_lines: false)
      |> refute_issues()
    end
  end

  describe "modules and files" do
    test "module over the limit" do
      [issue] = run(function(10), "lib/a.ex", max_module_lines: 8, max_function_lines: 100)
      assert issue.message =~ "module A spans 14 lines (max 8)"
    end

    test "file over the limit" do
      [issue] =
        run(function(10), "lib/a.ex",
          max_file_lines: 10,
          max_module_lines: 100,
          max_function_lines: 100
        )

      assert issue.message =~ "File has 14 lines (max 10)"
      assert issue.line_no == 1
    end

    test "defaults are 400/400/40" do
      38
      |> function()
      |> run()
      |> refute_issues()

      assert [_] = run(function(39))
    end
  end

  describe "scope" do
    test "tests are skipped by default but can be included" do
      10
      |> function()
      |> run("test/a_test.exs", max_function_lines: 5)
      |> refute_issues()

      assert [_] =
               run(function(10), "test/a_test.exs",
                 max_function_lines: 5,
                 included_paths: ["test/"]
               )
    end

    test "excluded_paths" do
      10
      |> function()
      |> run("lib/app/generated/a.ex",
        max_function_lines: 5,
        excluded_paths: ["lib/app/generated"]
      )
      |> refute_issues()
    end
  end
end
