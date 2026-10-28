defmodule KogenCredo.Check.Warning.BroadRescueTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.BroadRescue

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(BroadRescue, params)
  end

  defp try_with(rescue_clauses) do
    """
    defmodule A do
      def f do
        try do
          work()
        rescue
    #{rescue_clauses}
        end
      end
    end
    """
  end

  describe "positives" do
    test "rescue _" do
      [issue] = run(try_with("      _ -> :error"))
      assert issue.message =~ "Broad `rescue`"
    end

    test "rescue with a bare variable" do
      assert [_] = run(try_with("      e -> {:error, Exception.message(e)}"))
    end

    test "rescue e in Exception, RuntimeError and ErlangError" do
      assert [_] = run(try_with("      e in Exception -> {:error, e}"))
      assert [_] = run(try_with("      e in [RuntimeError] -> {:error, e}"))
      assert [_] = run(try_with("      e in [ErlangError, File.Error] -> {:error, e}"))
    end

    test "catch with variable kind and reason" do
      source = """
      defmodule A do
        def f do
          work()
        catch
          kind, reason -> {kind, reason}
        end
      end
      """

      assert [issue] = run(source)
      assert issue.message =~ "Broad `catch`"
    end

    test "implicit try in def body" do
      source = """
      defmodule A do
        def f do
          work()
        rescue
          _ -> nil
        end
      end
      """

      assert [_] = run(source)
    end

    test "aliased broad exception is resolved" do
      source = """
      defmodule A do
        alias RuntimeError, as: RE
        def f do
          work()
        rescue
          e in RE -> {:error, e}
        end
      end
      """

      assert [_] = run(source)
    end
  end

  describe "negatives and lookalikes" do
    test "narrow rescue passes" do
      "      e in [File.Error] -> {:error, e}\n      e in Jason.DecodeError -> {:error, e}"
      |> try_with()
      |> run()
      |> refute_issues()
    end

    test "broad rescue that re-raises passes" do
      "      e ->\n        Logger.error(\"x\")\n        reraise e, __STACKTRACE__"
      |> try_with()
      |> run()
      |> refute_issues()
    end

    test "catch with a fixed kind passes" do
      source = """
      defmodule A do
        def f do
          work()
        catch
          :exit, _ -> :stopped
          value -> value
        end
      end
      """

      source
      |> run()
      |> refute_issues()
    end

    test "a local module named like a broad one is not Elixir's" do
      source = """
      defmodule A do
        alias MyApp.Exception
        def f do
          work()
        rescue
          e in Exception -> {:error, e}
        end
      end
      """

      source
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "broad_exceptions can be extended" do
      source = try_with("      e in [ArgumentError] -> {:error, e}")
      assert [_] = run(source, "lib/a.ex", broad_exceptions: [ArgumentError])
    end

    test "tests are skipped by default but can be included" do
      source = try_with("      _ -> :error")

      source
      |> run("test/a_test.exs")
      |> refute_issues()

      assert [_] = run(source, "test/a_test.exs", included_paths: ["test/"])
    end

    test "excluded_paths skip a boundary module" do
      "      _ -> :error"
      |> try_with()
      |> run("lib/app/boundary/x.ex", excluded_paths: ["lib/app/boundary"])
      |> refute_issues()
    end
  end
end
