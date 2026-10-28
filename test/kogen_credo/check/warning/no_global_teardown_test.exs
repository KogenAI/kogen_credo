defmodule KogenCredo.Check.Warning.NoGlobalTeardownTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.NoGlobalTeardown

  defp run(body, params \\ [], file \\ "test/sample_test.exs", opts \\ "async: false") do
    """
    defmodule SampleTest do
      use ExUnit.Case, #{opts}
    #{body}
    end
    """
    |> to_source_file(file)
    |> run_check(NoGlobalTeardown, params)
  end

  test "reports :ets.delete/1 of a literal named table" do
    "  setup do\n    :ets.delete(:app_cache)\n  end\n"
    |> run()
    |> assert_issue(fn issue ->
      assert issue.message =~ "app_cache"
      assert issue.trigger == "delete"
    end)
  end

  test "reports via module attribute" do
    "  @t :app_cache\n  setup do\n    :ets.delete(@t)\n  end\n"
    |> run()
    |> assert_issue()
  end

  test "reports Application.stop, supervisor and named process teardown" do
    body = """
      test "a" do
        Application.stop(:my_app)
        Supervisor.terminate_child(MyApp.Supervisor, MyApp.Worker)
        GenServer.stop(MyApp.Server)
        Process.exit(Process.whereis(:named), :kill)
      end
    """

    assert length(run(body)) == 4
  end

  test "applies to async modules too, and expands aliases" do
    body = "  alias MyApp.Cache\n  test \"a\" do\n    GenServer.stop(Cache)\n  end\n"
    assert [issue] = run(body, [], "test/sample_test.exs", "async: true")
    assert issue.message =~ "MyApp.Cache"
  end

  test "lookalikes: private state is quiet" do
    """
      test "a" do
        table = :ets.new(:t, [:set])
        :ets.delete(table)
        :ets.delete(:app_cache, :key)
        pid = start_supervised!(Worker)
        GenServer.stop(pid)
        Supervisor.terminate_child(sup, id)
        Process.exit(pid, :kill)
        Map.delete(%{}, :a)
      end
    """
    |> run()
    |> refute_issues()
  end

  describe "terminate_child restored in the same block" do
    test "terminate_child followed by restart_child on the same supervisor is a bounce" do
      """
        alias MyApp.Sup
        test "recovers after restart" do
          :ok = Supervisor.terminate_child(Sup, MyApp.Worker)
          {:ok, _pid} = Supervisor.restart_child(MyApp.Sup, MyApp.Worker)
        end
      """
      |> run()
      |> refute_issues()
    end

    test "restart_child on another supervisor does not excuse it" do
      """
        test "a" do
          Supervisor.terminate_child(MyApp.Sup, MyApp.Worker)
          Supervisor.restart_child(MyApp.Other, MyApp.Worker)
        end
      """
      |> run()
      |> assert_issue()
    end

    test "restart of a different child does not excuse it" do
      """
        test "a" do
          Supervisor.terminate_child(MyApp.Sup, :a)
          Supervisor.restart_child(MyApp.Sup, :b)
        end
      """
      |> run()
      |> assert_issue()
    end

    test "a non-literal child id is never matched" do
      """
        test "a" do
          Supervisor.terminate_child(MyApp.Sup, id)
          Supervisor.restart_child(MyApp.Sup, id)
        end
      """
      |> run()
      |> assert_issue()
    end

    test "restart before termination does not excuse it" do
      """
        test "a" do
          Supervisor.restart_child(MyApp.Sup, MyApp.Worker)
          Supervisor.terminate_child(MyApp.Sup, MyApp.Worker)
        end
      """
      |> run()
      |> assert_issue()
    end

    test "restart in a branch does not excuse it" do
      """
        test "a" do
          Supervisor.terminate_child(MyApp.Sup, MyApp.Worker)

          if flag do
            Supervisor.restart_child(MyApp.Sup, MyApp.Worker)
          end
        end
      """
      |> run()
      |> assert_issue()
    end

    test "restart inside an anonymous function or on_exit does not excuse it" do
      """
        test "a" do
          Supervisor.terminate_child(MyApp.Sup, MyApp.Worker)
          on_exit(fn -> Supervisor.restart_child(MyApp.Sup, MyApp.Worker) end)
        end
      """
      |> run()
      |> assert_issue()
    end

    test "restart in another function does not excuse it" do
      """
        defp stop, do: Supervisor.terminate_child(MyApp.Sup, MyApp.Worker)
        defp start, do: Supervisor.restart_child(MyApp.Sup, MyApp.Worker)
      """
      |> run()
      |> assert_issue()
    end

    test "termination in a branch is not excused by a later top-level restart" do
      """
        test "a" do
          if flag, do: Supervisor.terminate_child(MyApp.Sup, MyApp.Worker)
          Supervisor.restart_child(MyApp.Sup, MyApp.Worker)
        end
      """
      |> run()
      |> assert_issue()
    end

    test "restart in another test does not excuse it" do
      """
        test "a" do
          Supervisor.terminate_child(MyApp.Sup, MyApp.Worker)
        end

        test "b" do
          Supervisor.restart_child(MyApp.Sup, MyApp.Worker)
        end
      """
      |> run()
      |> assert_issue()
    end

    test "other teardowns in the same block are still reported" do
      """
        test "a" do
          Supervisor.terminate_child(MyApp.Sup, MyApp.Worker)
          Supervisor.restart_child(MyApp.Sup, MyApp.Worker)
          GenServer.stop(MyApp.Server)
        end
      """
      |> run()
      |> assert_issue(fn issue -> assert issue.trigger == "stop" end)
    end
  end

  test "a table the module created itself is exempt" do
    "  setup do\n    :ets.new(:mine, [:named_table])\n    on_exit(fn -> :ets.delete(:mine) end)\n  end\n"
    |> run()
    |> refute_issues()
  end

  test "allowed_targets param" do
    body = "  test \"a\" do\n    GenServer.stop(MyApp.Server)\n  end\n"

    body
    |> run(allowed_targets: ["MyApp.Server"])
    |> refute_issues()

    body
    |> run(allowed_targets: ["Other"])
    |> assert_issue()
  end

  test "file scope" do
    body = "  test \"a\" do\n    Application.stop(:x)\n  end\n"

    body
    |> run([], "lib/x.ex")
    |> refute_issues()
  end

  test "modules that are not test modules are ignored" do
    """
    defmodule Plain do
      def stop, do: Application.stop(:x)
    end
    """
    |> to_source_file("test/plain_test.exs")
    |> run_check(NoGlobalTeardown)
    |> refute_issues()
  end
end
