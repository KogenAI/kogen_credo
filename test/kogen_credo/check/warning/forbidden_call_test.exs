defmodule KogenCredo.Check.Warning.ForbiddenCallTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.ForbiddenCall

  @rule [
    calls: [{System, :put_env}, {File, :cd!, 1}, {:timer, :sleep}],
    message: "Use the injected environment."
  ]

  defp run(source, filename \\ "lib/app/a.ex", params \\ [rules: [@rule]]) do
    source
    |> to_source_file(filename)
    |> run_check(ForbiddenCall, params)
  end

  describe "rule matching" do
    test "remote call is reported with the rule message" do
      [issue] = run(~s|defmodule A do def f, do: System.put_env("A", "1") end|)
      assert issue.message =~ "`System.put_env/2` is forbidden here"
      assert issue.message =~ "Use the injected environment."
    end

    test "erlang module call" do
      assert [_] = run("defmodule A do def f, do: :timer.sleep(10) end")
    end

    test "arity-restricted rule" do
      assert [_] = run("defmodule A do def f, do: File.cd!(\"x\") end")

      "defmodule A do def f, do: File.cd!(\"x\", fn -> :ok end) end"
      |> run()
      |> refute_issues()
    end

    test "piped call counts the piped argument" do
      assert [_] = run("defmodule A do def f(p), do: p |> File.cd!() end")
    end

    test "capture is reported with its own arity" do
      assert [issue] = run("defmodule A do def f, do: &File.cd!/1 end")
      assert issue.message =~ "File.cd!/1"

      "defmodule A do def f, do: &File.cd!/2 end"
      |> run()
      |> refute_issues()
    end

    test "apply with literal module and function" do
      assert [_] = run(~s|defmodule A do def f, do: apply(System, :put_env, ["A", "1"]) end|)
    end

    test "alias as: resolves to the banned module" do
      source = """
      defmodule A do
        alias System, as: Sys
        def f, do: Sys.put_env("A", "1")
      end
      """

      assert [_] = run(source)
    end

    test "import of a banned module reports bare calls" do
      source = """
      defmodule A do
        import System, only: [put_env: 2]
        def f, do: put_env("A", "1")
      end
      """

      assert [_] = run(source)
    end
  end

  describe "valid lookalikes" do
    test "a project-local module with the same short name is not the banned one" do
      source = """
      defmodule A do
        alias MyApp.File
        def f, do: File.cd!("x")
      end
      """

      source
      |> run()
      |> refute_issues()
    end

    test "same function name on another module" do
      "defmodule A do def f, do: Cache.put_env(:a, 1) end"
      |> run()
      |> refute_issues()
    end

    test "local function sharing a name with an imported banned function" do
      source = """
      defmodule A do
        import System, only: [put_env: 2]
        def put_env(a, b), do: {a, b}
        def f, do: put_env("A", "1")
      end
      """

      source
      |> run()
      |> refute_issues()
    end

    test "import only: restricts which bare calls match" do
      source = """
      defmodule A do
        import System, only: [get_env: 1]
        def f, do: put_env("A", "1")
      end
      """

      source
      |> run()
      |> refute_issues()
    end
  end

  describe "paths" do
    @scoped [
      calls: [{System, :put_env}],
      message: "no",
      paths: ["test/"],
      allow: ["test/support/"]
    ]

    test "rule applies only under paths" do
      source = ~s|defmodule A do def f, do: System.put_env("A", "1") end|
      assert [_] = run(source, "test/a_test.exs", rules: [@scoped])

      source
      |> run("lib/a.ex", rules: [@scoped])
      |> refute_issues()
    end

    test "allow exempts files" do
      source = ~s|defmodule A do def f, do: System.put_env("A", "1") end|
      refute_issues(run(source, "test/support/helper.ex", rules: [@scoped]))
    end

    test "rules may be maps" do
      rule = %{calls: [{System, :put_env}], message: "no"}

      assert [_] =
               run(~s|defmodule A do def f, do: System.put_env("A", "1") end|, "lib/a.ex",
                 rules: [rule]
               )
    end
  end

  describe "async_safe_tests preset scope" do
    test "only modules that `use ..., async: true` are checked" do
      sync = """
      defmodule ATest do
        use ExUnit.Case, async: false
        test "x", do: Process.sleep(10)
      end
      """

      default = """
      defmodule BTest do
        use ExUnit.Case
        test "x", do: Application.put_env(:a, :b, 1)
      end
      """

      async = """
      defmodule CTest do
        use ExUnit.Case, async: true
        test "x", do: Process.sleep(10)
      end
      """

      sync
      |> preset()
      |> refute_issues()

      default
      |> preset()
      |> refute_issues()

      assert [_] = preset(async)
    end

    test "loose top-level scripts such as test_helper.exs are not async tests" do
      "Application.put_env(:app, :client, Mock)\nExUnit.start()"
      |> preset("test/test_helper.exs")
      |> refute_issues()
    end

    test "an explicit rule without only_async bans the call everywhere in the path" do
      rule = [calls: [{Process, :sleep}], message: "no sleeping", paths: ["test/"]]

      assert [_] =
               run(
                 "defmodule ATest do\n use ExUnit.Case\n def f, do: Process.sleep(1)\nend",
                 "test/a_test.exs",
                 rules: [rule]
               )
    end
  end

  describe "async_safe_tests preset" do
    defp preset(source, filename \\ "test/a_test.exs"),
      do: run(source, filename, presets: [:async_safe_tests])

    test "reports sleeps and global mutation in tests" do
      source = """
      defmodule ATest do
        use ExUnit.Case, async: true
        test "x" do
          Process.sleep(100)
          :timer.sleep(5)
          System.put_env("A", "1")
          Application.put_env(:app, :k, 1)
          File.cd!("tmp")
        end
      end
      """

      assert length(preset(source)) == 5
    end

    test "does not touch lib files or test/support" do
      source = "defmodule A do def f, do: Process.sleep(1) end"

      source
      |> preset("lib/a.ex")
      |> refute_issues()

      source
      |> preset("test/support/helper.ex")
      |> refute_issues()
    end

    test "Process.sleep(:infinity) with other arity shapes is not special-cased away" do
      "defmodule ATest do def f, do: Process.send_after(self(), :x, 5) end"
      |> preset()
      |> refute_issues()
    end

    test "preset_allow replaces the exempt list" do
      source = "defmodule A do use ExUnit.Case, async: true\n def f, do: Process.sleep(1) end"

      assert [_] =
               run(source, "test/support/helper.ex",
                 presets: [:async_safe_tests],
                 preset_allow: []
               )
    end
  end

  describe "configuration" do
    test "no rules means no issues" do
      ~s|defmodule A do def f, do: System.put_env("A", "1") end|
      |> run("lib/a.ex", [])
      |> refute_issues()
    end

    test "invalid rule raises with an actionable message" do
      assert_raise ArgumentError, ~r/needs a non-empty :calls list/, fn ->
        "defmodule A do end"
        |> to_source_file("lib/a.ex")
        |> ForbiddenCall.run(rules: [[calls: [], message: "x"]])
      end
    end

    test "unknown preset raises" do
      assert_raise ArgumentError, ~r/unknown ForbiddenCall preset/, fn ->
        "defmodule A do end"
        |> to_source_file("lib/a.ex")
        |> ForbiddenCall.run(presets: [:nope])
      end
    end
  end
end
