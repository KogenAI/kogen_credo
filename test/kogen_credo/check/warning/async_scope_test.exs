defmodule KogenCredo.Check.Warning.AsyncScopeTest do
  # Lexical-scope and target regressions shared by the async-safety checks
  # (GlobalStateInAsync, SerialReason, NoGlobalTeardown via TestModuleInfo).
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.GlobalStateInAsync
  alias KogenCredo.Check.Warning.NoGlobalTeardown
  alias KogenCredo.Check.Warning.SerialReason

  defp run(check, source, params \\ []) do
    source
    |> to_source_file("test/sample_test.exs")
    |> run_check(check, params)
  end

  describe "GlobalStateInAsync: pipes" do
    test "a piped File.write! is a write to the piped path, not to the data" do
      """
      defmodule SampleTest do
        use ExUnit.Case, async: true
        test "a" do
          "tmp/out.txt" |> File.write!("payload")
        end
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      |> assert_issue(fn issue ->
        assert issue.message =~ ~s("tmp/out.txt")
        refute issue.message =~ "payload"
      end)
    end

    test "a piped ets insert into a named table is a write to that table" do
      """
      defmodule SampleTest do
        use ExUnit.Case, async: true
        test "a" do
          :shared |> :ets.insert({1, 2})
        end
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      |> assert_issue(fn issue -> assert issue.message =~ ~s(ets "shared") end)
    end
  end

  describe "GlobalStateInAsync: lexical scope" do
    test "writes inside quote are generated code, not the module's own" do
      """
      defmodule SampleTest do
        use ExUnit.Case, async: true
        defmacro __using__(_) do
          quote do
            Application.put_env(:app, :mode, 1)
          end
        end
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      |> refute_issues()
    end

    test "a nested helper module's writes are not charged to the enclosing async test" do
      """
      defmodule SampleTest do
        use ExUnit.Case, async: true

        defmodule Helper do
          def go, do: Application.put_env(:app, :mode, 1)
        end

        test "a", do: assert(true)
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      |> refute_issues()
    end

    test "nested test modules are judged by their own async/group options" do
      """
      defmodule OuterTest do
        use ExUnit.Case, async: false

        defmodule InnerAsyncTest do
          use ExUnit.Case, async: true
          test "a", do: Application.put_env(:app, :inner, 1)
        end

        defmodule InnerGroupedTest do
          use ExUnit.Case, async: true, group: :g
          test "a", do: Application.put_env(:app, :grouped, 1)
        end

        test "outer", do: Application.put_env(:app, :outer, 1)
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      |> assert_issue(fn issue ->
        assert issue.message =~ "OuterTest.InnerAsyncTest"
        assert issue.message =~ "app.inner"
      end)
    end

    test "an async outer module does not inherit the inner module's serial mode" do
      """
      defmodule OuterTest do
        use ExUnit.Case, async: true

        defmodule InnerTest do
          use ExUnit.Case, async: false
          test "a", do: Application.put_env(:app, :inner, 1)
        end

        test "outer", do: Application.put_env(:app, :outer, 1)
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      |> assert_issue(fn issue ->
        assert issue.message =~ "app.outer"
        refute issue.message =~ "app.inner"
      end)
    end
  end

  describe "GlobalStateInAsync: real targets" do
    test "an aliased project Application module is not OTP Application" do
      """
      defmodule SampleTest do
        use ExUnit.Case, async: true
        alias MyApp.Application
        test "a", do: Application.put_env(:app, :mode, 1)
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      |> refute_issues()
    end

    test "an alias of the real module still counts" do
      """
      defmodule SampleTest do
        use ExUnit.Case, async: true
        alias System, as: Sys
        test "a", do: Sys.put_env("FOO", "1")
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      |> assert_issue()
    end

    test "unnamed ets tables and variable keys are not global names" do
      """
      defmodule SampleTest do
        use ExUnit.Case, async: true
        test "a" do
          t = :ets.new(:scratch, [:set])
          :ets.insert(t, {1, 2})
          Application.put_env(:app, key(), 1)
        end
      end
      """
      |> then(&run(GlobalStateInAsync, &1))
      # only the dynamic Application key remains (dynamic writes are still node-wide)
      |> assert_issue(fn issue -> assert issue.message =~ "dynamic key" end)
    end

    test "template :async forces async even with async: false written" do
      """
      defmodule SampleTest do
        use MyApp.AsyncCase, async: false
        test "a", do: Application.put_env(:app, :mode, 1)
      end
      """
      |> then(&run(GlobalStateInAsync, &1, case_templates: %{"MyApp.AsyncCase" => :async}))
      |> assert_issue()
    end

    test "template :serial forces serial even with async: true written" do
      """
      defmodule SampleTest do
        use MyApp.SerialCase, async: true
        test "a", do: Application.put_env(:app, :mode, 1)
      end
      """
      |> then(&run(GlobalStateInAsync, &1, case_templates: %{"MyApp.SerialCase" => :serial}))
      |> refute_issues()
    end

    test "a template given as a keyword list or atom key is normalised" do
      src = """
      defmodule SampleTest do
        use MyApp.DataCase, async: true
        test "a", do: Application.put_env(:app, :mode, 1)
      end
      """

      GlobalStateInAsync
      |> run(src, case_templates: [{MyApp.DataCase, :inherit}])
      |> assert_issue()

      GlobalStateInAsync
      |> run(src, case_templates: %{})
      |> refute_issues()
    end
  end

  describe "SerialReason" do
    test "serial: true and serial: nil explain nothing, even with an empty vocabulary" do
      for value <- ["true", "nil", "false", "some_call()"] do
        """
        defmodule SampleTest do
          use ExUnit.Case, async: false
          @moduletag serial: #{value}
        end
        """
        |> then(&run(SerialReason, &1, serial_vocabulary: []))
        |> assert_issue(fn issue -> assert issue.message =~ "not a literal reason atom" end)
      end
    end

    test "nested modules are judged separately" do
      """
      defmodule OuterTest do
        use ExUnit.Case, async: true

        defmodule InnerTest do
          use ExUnit.Case, async: false
        end
      end
      """
      |> then(&run(SerialReason, &1))
      |> assert_issue(fn issue -> assert issue.message =~ "OuterTest.InnerTest runs serially" end)
    end

    test "a moduletag on the outer module does not excuse an inner serial module" do
      """
      defmodule OuterTest do
        use ExUnit.Case, async: false
        @moduletag serial: :env

        defmodule InnerTest do
          use ExUnit.Case, async: false
        end
      end
      """
      |> then(&run(SerialReason, &1))
      |> assert_issue(fn issue -> assert issue.message =~ "OuterTest.InnerTest" end)
    end

    test "a template that forces async is not reported, one that forces serial is" do
      params = [case_templates: %{"A.Async" => :async, "A.Serial" => :serial}]

      "defmodule T do\n  use A.Async, async: false\nend\n"
      |> then(&run(SerialReason, &1, params))
      |> refute_issues()

      "defmodule T do\n  use A.Serial, async: true\nend\n"
      |> then(&run(SerialReason, &1, params))
      |> assert_issue()
    end
  end

  describe "NoGlobalTeardown" do
    test "a piped GenServer.stop on a named process is reported with its target" do
      """
      defmodule SampleTest do
        use ExUnit.Case, async: false
        test "a" do
          MyApp.Worker |> GenServer.stop()
        end
      end
      """
      |> then(&run(NoGlobalTeardown, &1))
      |> assert_issue(fn issue -> assert issue.message =~ "MyApp.Worker" end)
    end
  end
end

defmodule KogenCredo.Check.Warning.GlobalNameInventoryPipeTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.GlobalNameInventory

  test "a piped Phoenix.PubSub call still reads its topic argument" do
    """
    defmodule MyApp.Lobby do
      def join(), do: MyApp.PubSub |> Phoenix.PubSub.subscribe("rooms:lobby")
    end
    """
    |> to_source_file("lib/my_app/lobby.ex")
    |> run_check(GlobalNameInventory)
    |> assert_issue(fn issue -> assert issue.message =~ "rooms:lobby" end)
  end
end
