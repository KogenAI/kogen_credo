defmodule KogenCredo.Check.Readability.ErrorReasonStringTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Readability.ErrorReasonString

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(ErrorReasonString, params)
  end

  describe "positives" do
    test "string reason returned from a function" do
      source = """
      defmodule A do
        def f(x) do
          if x, do: :ok, else: {:error, "something went wrong"}
        end
      end
      """

      [issue] = run(source)
      assert issue.message =~ ~s|{:error, "something went wrong"}|
      assert issue.line_no == 3
    end

    test "interpolated reason" do
      source = ~S'''
      defmodule A do
        def f(x), do: {:error, "bad value #{inspect(x)}"}
      end
      '''

      assert [issue] = run(source)
      assert issue.line_no == 2
    end

    test "string reason in a pipe, return value and with/else" do
      source = """
      defmodule A do
        def f(x) do
          with {:ok, y} <- g(x) do
            y
          else
            _ -> {:error, "unknown"}
          end
        end

        def h(_), do: {:error, "second"}
      end
      """

      assert [a, b] = run(source)
      assert {a.line_no, b.line_no} == {6, 10}
    end
  end

  describe "negatives and lookalikes" do
    test "atom and tagged reasons pass" do
      source = """
      defmodule A do
        def f(x), do: if(x, do: {:error, :not_found}, else: {:error, {:invalid, "email"}})
        def g, do: {:ok, "text"}
        def h(msg), do: {:error, msg}
      end
      """

      source
      |> run()
      |> refute_issues()
    end

    test "match patterns handling a library's string error are not constructions" do
      source = """
      defmodule A do
        def f(x) do
          case g(x) do
            {:error, "timeout"} -> :retry
            other -> other
          end
        end

        def h({:error, "bad"}), do: :bad
        def i(x), do: {:error, "msg"} = x
      end
      """

      source
      |> run()
      |> refute_issues()
    end

    test "typespecs are not constructions" do
      source =
        "defmodule A do\n  @spec f() :: {:error, String.t()}\n  def f, do: {:error, :x}\nend\n"

      source
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "flag_interpolated false" do
      source = ~S'''
      defmodule A do
        def f(x), do: {:error, "bad #{x}"}
      end
      '''

      source
      |> run("lib/a.ex", flag_interpolated: false)
      |> refute_issues()
    end

    test "Mix tasks and tests are skipped by default" do
      source = "defmodule A do\n  def f, do: {:error, \"x\"}\nend\n"

      source
      |> run("lib/mix/tasks/a.ex")
      |> refute_issues()

      source
      |> run("test/a_test.exs")
      |> refute_issues()
    end

    test "excluded_paths replaces the default exclusion" do
      source = "defmodule A do\n  def f, do: {:error, \"x\"}\nend\n"
      assert [_] = run(source, "lib/mix/tasks/a.ex", excluded_paths: [])
    end
  end
end
