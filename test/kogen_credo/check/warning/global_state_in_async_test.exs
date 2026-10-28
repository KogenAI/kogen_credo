defmodule KogenCredo.Check.Warning.GlobalStateInAsyncTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.GlobalStateInAsync

  defp run(body, opts \\ "async: true", params \\ [], file \\ "test/sample_test.exs") do
    """
    defmodule SampleTest do
      use ExUnit.Case, #{opts}
    #{body}
    end
    """
    |> to_source_file(file)
    |> run_check(GlobalStateInAsync, params)
  end

  test "reports Application.put_env in an async module" do
    "  setup do\n    Application.put_env(:app, :mode, :x)\n  end\n"
    |> run()
    |> assert_issue(fn issue ->
      assert issue.message =~ "Application.put_env"
      assert issue.message =~ "app.mode"
    end)
  end

  test "reports each kind of global write" do
    body = """
      test "a" do
        System.put_env("FOO", "1")
        :ets.new(:cache, [:named_table, :public])
        :ets.insert(:cache, {1, 2})
        File.write!("priv/out.txt", "x")
        File.cd!("tmp")
        Logger.configure(level: :debug)
        :persistent_term.put(:key, 1)
        Mox.set_mox_global()
      end
    """

    issues = run(body)
    assert length(issues) == 8
  end

  test "setup :set_mox_global is reported" do
    "  setup :set_mox_global\n"
    |> run()
    |> assert_issue(fn i -> assert i.message =~ "set_mox_global" end)
  end

  test "module attribute values resolve" do
    """
      @table :shared
      test "a" do
        :ets.new(@table, [:named_table])
      end
    """
    |> run()
    |> assert_issue(fn issue -> assert issue.message =~ "shared" end)
  end

  test "quiet when serial, grouped, or template-forced serial" do
    body = "  test \"a\" do\n    Application.put_env(:app, :k, 1)\n  end\n"

    body
    |> run("async: false")
    |> refute_issues()

    body
    |> run()
    |> then(&assert length(&1) == 1)

    body
    |> run("async: true, group: :app_env")
    |> refute_issues()

    body
    |> run("")
    |> refute_issues()
  end

  test "lookalikes: reads, private tables, tmp_dir paths, comments and strings" do
    """
      @tag :tmp_dir
      test "a", %{tmp_dir: dir} do
        Application.get_env(:app, :k)
        :ets.new(:private, [:set])
        File.write!(Path.join(dir, "x"), "y")
        File.read!("priv/in.txt")
        # Application.put_env(:app, :k, 1)
        assert "Application.put_env" == "x"
        Map.put_env(%{}, 1, 2)
      end
    """
    |> run()
    |> refute_issues()
  end

  test "case_templates resolve async mode; undeclared templates are quiet" do
    src = """
    defmodule SampleTest do
      use MyApp.Case, async: true
      test "a" do
        Application.put_env(:app, :k, 1)
      end
    end
    """

    src
    |> to_source_file("test/s_test.exs")
    |> run_check(GlobalStateInAsync)
    |> refute_issues()

    src
    |> to_source_file("test/s_test.exs")
    |> run_check(GlobalStateInAsync, case_templates: %{"MyApp.Case" => :inherit})
    |> assert_issue()
  end

  test "kinds param narrows the report" do
    body =
      "  test \"a\" do\n    System.put_env(\"A\", \"1\")\n    Logger.configure(level: :info)\n  end\n"

    assert [issue] = run(body, "async: true", kinds: [:logger])
    assert issue.message =~ "Logger.configure"
  end

  test "file scope" do
    body = "  test \"a\" do\n    Application.put_env(:app, :k, 1)\n  end\n"

    body
    |> run("async: true", [], "lib/sample.ex")
    |> refute_issues()

    body
    |> run("async: true", [included_files: ["lib/**"]], "lib/sample.ex")
    |> assert_issue()
  end
end
