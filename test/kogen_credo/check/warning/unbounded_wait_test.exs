defmodule KogenCredo.Check.Warning.UnboundedWaitTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.UnboundedWait

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(UnboundedWait, params)
  end

  defp fun(body), do: "defmodule A do\n  def f(pid, task) do\n#{body}\n  end\nend\n"

  describe "receive" do
    test "without after is reported" do
      [issue] = run(fun("    receive do\n      :msg -> :ok\n    end"))
      assert issue.message =~ "without `after`"
    end

    test "with a finite after passes" do
      "    receive do\n      :msg -> :ok\n    after\n      500 -> :timeout\n    end"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "after :infinity is reported" do
      assert [_] =
               run(
                 fun(
                   "    receive do\n      :msg -> :ok\n    after\n      :infinity -> :ok\n    end"
                 )
               )
    end

    test "flag_receive_without_after false" do
      source = fun("    receive do\n      :msg -> :ok\n    end")

      source
      |> run("lib/a.ex", flag_receive_without_after: false)
      |> refute_issues()
    end
  end

  describe "infinity timeouts" do
    test "GenServer.call, Task.await, Agent.get and sleep" do
      source =
        fun("""
            GenServer.call(pid, :req, :infinity)
            Task.await(task, :infinity)
            Agent.get(pid, & &1, :infinity)
            Process.sleep(:infinity)
            :timer.sleep(:infinity)
        """)

      assert length(run(source)) == 5
    end

    test "piped timeouts are positional" do
      assert [_] = run(fun("    task |> Task.await(:infinity)"))
    end

    test "aliased module is resolved" do
      source =
        "defmodule A do\n  alias GenServer, as: GS\n  def f(p), do: GS.call(p, :x, :infinity)\nend\n"

      assert [_] = run(source)
    end

    test "finite timeouts and defaults pass" do
      "    GenServer.call(pid, :req, 5_000)\n    Task.await(task)\n    Process.sleep(10)"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "a user module with the same function names passes" do
      "    MyApp.Task.await(task, :infinity)"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "timeout: :infinity option" do
      assert [_] = run(fun("    Repo.all(query, timeout: :infinity)"))
      assert [_] = run(fun("    Task.async_stream(list, &work/1, timeout: :infinity)"))

      "    Repo.all(query, timeout: 5_000)"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "flag_timeout_option false" do
      "    Repo.all(query, timeout: :infinity)"
      |> fun()
      |> run("lib/a.ex", flag_timeout_option: false)
      |> refute_issues()
    end

    test "infinity_calls is configurable" do
      source = fun("    MyApp.Bus.wait(pid, :infinity)")
      assert [_] = run(source, "lib/a.ex", infinity_calls: [{MyApp.Bus, :wait, 1}])
    end
  end

  describe "scope" do
    test "tests are checked by default" do
      assert [_] = run(fun("    receive do\n      :a -> :ok\n    end"), "test/a_test.exs")
    end

    test "other directories are not" do
      "    receive do\n      :a -> :ok\n    end"
      |> fun()
      |> run("scripts/a.exs")
      |> refute_issues()
    end
  end
end
