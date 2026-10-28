defmodule KogenCredo.Check.Warning.TestModuleShapeTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.TestModuleShape

  defp run(source, filename \\ "test/app/a_test.exs", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(TestModuleShape, params)
  end

  defp tests(n), do: Enum.map_join(1..n, "\n", &"  test \"t#{&1}\", do: assert(true)")

  describe "async" do
    test "use Case without async is reported" do
      [issue] = run("defmodule ATest do\n  use ExUnit.Case\nend\n")
      assert issue.message =~ "not `async: true`"
    end

    test "async: false is reported" do
      assert [_] = run("defmodule ATest do\n  use ExUnit.Case, async: false\nend\n")
    end

    test "custom case templates are checked" do
      assert [_] = run("defmodule ATest do\n  use MyApp.DataCase\nend\n")
    end

    test "async: true passes" do
      "defmodule ATest do\n  use ExUnit.Case, async: true\nend\n"
      |> run()
      |> refute_issues()
    end

    test "use of non-case modules passes" do
      "defmodule ATest do\n  use Mox.Helper\nend\n"
      |> run()
      |> refute_issues()
    end

    test "serial_allowed by exact path, suffix and glob" do
      source = "defmodule ATest do\n  use ExUnit.Case\nend\n"

      source
      |> run("test/app/a_test.exs", serial_allowed: ["test/app/a_test.exs"])
      |> refute_issues()

      source
      |> run("test/app/a_test.exs", serial_allowed: ["app/a_test.exs"])
      |> refute_issues()

      source
      |> run("test/app/a_test.exs", serial_allowed: ["test/app/*_test.exs"])
      |> refute_issues()

      assert [_] = run(source, "test/app/a_test.exs", serial_allowed: ["test/other/*_test.exs"])
    end

    test "require_async false disables the async rule" do
      "defmodule ATest do\n  use ExUnit.Case\nend\n"
      |> run("test/a_test.exs", require_async: false)
      |> refute_issues()
    end
  end

  describe "size" do
    test "more tests than max_tests is reported" do
      source = "defmodule ATest do\n  use ExUnit.Case, async: true\n#{tests(4)}\nend\n"
      [issue] = run(source, "test/a_test.exs", max_tests: 3)
      assert issue.message =~ "4 test runs"
    end

    test "exactly max_tests passes" do
      source = "defmodule ATest do\n  use ExUnit.Case, async: true\n#{tests(3)}\nend\n"

      source
      |> run("test/a_test.exs", max_tests: 3)
      |> refute_issues()
    end

    test "parameterize multiplies the count" do
      source =
        "defmodule ATest do\n  use ExUnit.Case, async: true, parameterize: [%{a: 1}, %{a: 2}]\n#{tests(3)}\nend\n"

      [issue] = run(source, "test/a_test.exs", max_tests: 5)
      assert issue.message =~ "3 tests x 2 params"
    end

    test "nested modules are counted separately" do
      source = """
      defmodule ATest do
        use ExUnit.Case, async: true
        defmodule Inner do
          use ExUnit.Case, async: true
      #{tests(3)}
        end
      #{tests(2)}
      end
      """

      source
      |> run("test/a_test.exs", max_tests: 3)
      |> refute_issues()
    end
  end

  describe "filename scope" do
    test "non-test files are ignored" do
      "defmodule A do\n  use ExUnit.Case\nend\n"
      |> run("test/support/case.ex")
      |> refute_issues()

      "defmodule A do\n  use ExUnit.Case\nend\n"
      |> run("lib/a.ex")
      |> refute_issues()
    end

    test "file_suffixes can be changed" do
      assert [_] =
               run("defmodule A do\n  use ExUnit.Case\nend\n", "test/support/case.ex",
                 file_suffixes: [".ex"]
               )
    end
  end
end
