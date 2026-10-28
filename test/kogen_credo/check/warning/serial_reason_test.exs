defmodule KogenCredo.Check.Warning.SerialReasonTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.SerialReason

  defp run(source, params \\ [], file \\ "test/sample_test.exs") do
    source
    |> to_source_file(file)
    |> run_check(SerialReason, params)
  end

  test "reports explicit async: false without a tag" do
    """
    defmodule SampleTest do
      use ExUnit.Case, async: false
    end
    """
    |> run()
    |> assert_issue(fn issue ->
      assert issue.message =~ "no `@moduletag serial:"
      assert issue.trigger == "SampleTest"
    end)
  end

  test "reports a module with no async option (serial by default)" do
    "defmodule SampleTest do\n  use ExUnit.Case\nend\n"
    |> run()
    |> assert_issue()
  end

  test "reports aliased ExUnit.Case" do
    """
    defmodule SampleTest do
      alias ExUnit.Case, as: C
      use C
    end
    """
    |> run()
    |> assert_issue()
  end

  test "accepts a tag from the vocabulary" do
    """
    defmodule SampleTest do
      use ExUnit.Case, async: false
      @moduletag serial: :env
    end
    """
    |> run()
    |> refute_issues()
  end

  test "reports a tag outside the vocabulary" do
    """
    defmodule SampleTest do
      use ExUnit.Case, async: false
      @moduletag serial: :because
    end
    """
    |> run()
    |> assert_issue(fn issue -> assert issue.message =~ ":because" end)
  end

  test "custom vocabulary param and empty vocabulary accepting any atom" do
    src = """
    defmodule SampleTest do
      use ExUnit.Case, async: false
      @moduletag serial: :custom
    end
    """

    src
    |> run(serial_vocabulary: [:custom])
    |> refute_issues()

    src
    |> run(serial_vocabulary: [])
    |> refute_issues()

    src
    |> run(serial_vocabulary: [:other])
    |> assert_issue()
  end

  test "async modules and unknown async values are quiet" do
    """
    defmodule AsyncTest do
      use ExUnit.Case, async: true
    end

    defmodule DynamicTest do
      use ExUnit.Case, async: @flag
    end
    """
    |> run()
    |> refute_issues()
  end

  test "lookalike: other `use` and CaseTemplate modules are not test modules" do
    """
    defmodule SampleTest do
      use SomethingElse, async: false
    end

    defmodule Template do
      use ExUnit.CaseTemplate
    end
    """
    |> run()
    |> refute_issues()
  end

  test "an undeclared template is not analysed" do
    "defmodule SampleTest do\n  use MyApp.DataCase, async: false\nend\n"
    |> run()
    |> refute_issues()
  end

  describe "case_templates" do
    test ":inherit follows the options at the use site" do
      templates = [case_templates: %{"MyApp.DataCase" => :inherit}]
      serial = "defmodule SampleTest do\n  use MyApp.DataCase, async: false\nend\n"
      async = "defmodule SampleTest do\n  use MyApp.DataCase, async: true\nend\n"

      serial
      |> run(templates)
      |> assert_issue()

      async
      |> run(templates)
      |> refute_issues()
    end

    test ":async forces async even when the option says false" do
      "defmodule SampleTest do\n  use MyApp.Case, async: false\nend\n"
      |> run(case_templates: %{"MyApp.Case" => :async})
      |> refute_issues()
    end

    test ":serial forces serial even with async: true" do
      "defmodule SampleTest do\n  use MyApp.Case, async: true\nend\n"
      |> run(case_templates: [{"MyApp.Case", :serial}])
      |> assert_issue()
    end

    test "template alias is expanded" do
      """
      defmodule SampleTest do
        alias MyApp.Cases.Serial
        use Serial
      end
      """
      |> run(case_templates: %{"MyApp.Cases.Serial" => :serial})
      |> assert_issue()
    end
  end

  test "allowed_modules exempts a module" do
    "defmodule SampleTest do\n  use ExUnit.Case\nend\n"
    |> run(allowed_modules: ["SampleTest"])
    |> refute_issues()
  end

  test "file scope: non-test files are ignored, included_files overrides" do
    src = "defmodule Sample do\n  use ExUnit.Case\nend\n"

    src
    |> run([], "lib/sample.ex")
    |> refute_issues()

    src
    |> run([], "test/support/case.ex")
    |> refute_issues()

    src
    |> run([included_files: ["test/support/**"]], "test/support/case.ex")
    |> assert_issue()
  end

  test "nested module is judged on its own use" do
    """
    defmodule OuterTest do
      use ExUnit.Case, async: true

      defmodule InnerTest do
        use ExUnit.Case
      end
    end
    """
    |> run()
    |> assert_issue(fn issue -> assert issue.message =~ "OuterTest.InnerTest" end)
  end
end
