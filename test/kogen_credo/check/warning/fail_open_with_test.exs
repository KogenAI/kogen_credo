defmodule KogenCredo.Check.Warning.FailOpenWithTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.FailOpenWith

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(FailOpenWith, params)
  end

  defp with_else(else_clauses) do
    """
    defmodule A do
      def f(x) do
        with {:ok, y} <- g(x) do
          y
        else
    #{else_clauses}
        end
      end
    end
    """
  end

  describe "with/else positives" do
    test "catch-all returning nil" do
      [issue] = run(with_else("      _ -> nil"))
      assert issue.message =~ "catch-all"
    end

    test "named catch-all returning a default" do
      assert [_] = run(with_else("      _other -> []"))
    end

    test "error reason variable mapped to a constant" do
      [issue] = run(with_else("      {:error, _reason} -> :ok"))
      assert issue.message =~ "success-shaped default"
    end

    test "error mapped to {:ok, constant}" do
      assert [_] = run(with_else("      {:error, _} -> {:ok, []}"))
    end

    test "identity else is redundant" do
      [issue] = run(with_else("      {:error, r} -> {:error, r}\n      other -> other"))
      assert issue.message =~ "delete the `else`"
    end

    test "identity else can be allowed" do
      source = with_else("      {:error, r} -> {:error, r}\n      other -> other")

      source
      |> run("lib/a.ex", flag_identity_else: false)
      |> refute_issues()
    end
  end

  describe "with/else negatives and lookalikes" do
    test "catch-all returning an error is fail-closed" do
      "      _ -> {:error, :unexpected}"
      |> with_else()
      |> run()
      |> refute_issues()
    end

    test "catch-all raising passes" do
      "      other -> raise \"bad \#{inspect(other)}\""
      |> with_else()
      |> run()
      |> refute_issues()
    end

    test "translating specific errors passes" do
      "      {:error, :enoent} -> {:error, :not_found}\n      {:error, :eacces} -> :ok"
      |> with_else()
      |> run()
      |> refute_issues()
    end

    test "literal-reason error to :ok is deliberate" do
      "      {:error, :enoent} -> :ok"
      |> with_else()
      |> run()
      |> refute_issues()
    end

    test "narrow identity else is a closed-world assertion, not redundant" do
      "      {:error, r} -> {:error, r}"
      |> with_else()
      |> run()
      |> refute_issues()
    end

    test "catch-all returning a tagged atom is an explicit outcome" do
      "      _unavailable -> :unavailable"
      |> with_else()
      |> run()
      |> refute_issues()
    end

    test "catch-all returning a framework tuple or a translated response passes" do
      "      _error -> {:noreply, socket}"
      |> with_else()
      |> run()
      |> refute_issues()

      "      _error -> send_resp(conn, :not_found, \"404\")"
      |> with_else()
      |> run()
      |> refute_issues()

      "      _error -> redirect(conn, to: \"/\")"
      |> with_else()
      |> run()
      |> refute_issues()
    end

    test "catch-all returning {:ok, anything} is still success-shaped" do
      assert [_] = run(with_else("      _ -> {:ok, build()}"))
    end

    test "with without else" do
      """
      defmodule A do
        def f(x) do
          with {:ok, y} <- g(x), do: y
        end
      end
      """
      |> run()
      |> refute_issues()
    end
  end

  describe "boolean predicates" do
    test "case with ok -> true and error -> false is a predicate" do
      """
      defmodule A do
        def has_block?(body) do
          case check(body) do
            {:ok, _block} -> true
            {:error, _none} -> false
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "error -> false without a true branch is still reported" do
      assert [_] =
               run("""
               defmodule A do
                 def f(body) do
                   case check(body) do
                     {:ok, v} -> v
                     {:error, _none} -> false
                   end
                 end
               end
               """)
    end
  end

  describe "case" do
    @case_source """
    defmodule A do
      def f(x) do
        case g(x) do
          {:ok, v} -> v
          {:error, _} -> []
        end
      end
    end
    """

    test "error to empty list is reported" do
      [issue] = run(@case_source)
      assert issue.message =~ "`[]`"
    end

    test "flag_case false disables it" do
      @case_source
      |> run("lib/a.ex", flag_case: false)
      |> refute_issues()
    end

    test "bare :error and literal reasons pass" do
      """
      defmodule A do
        def f(m) do
          case Map.fetch(m, :a) do
            {:ok, v} -> v
            :error -> nil
          end
        end

        def g(p) do
          case File.rm(p) do
            :ok -> :ok
            {:error, :enoent} -> :ok
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "error clause that does more than return a constant passes" do
      """
      defmodule A do
        def f(x) do
          case g(x) do
            {:error, reason} ->
              Logger.warning("failed")
              {:error, reason}
            other -> other
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end
  end

  describe "scope" do
    test "test files are skipped by default" do
      "      _ -> nil"
      |> with_else()
      |> run("test/a_test.exs")
      |> refute_issues()
    end
  end
end
