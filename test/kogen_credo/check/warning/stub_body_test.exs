defmodule KogenCredo.Check.Warning.StubBodyTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.StubBody

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(StubBody, params)
  end

  defp fun(body), do: "defmodule A do\n  def f(x) do\n#{body}\n  end\nend\n"

  describe "positives" do
    test "stub atom" do
      [issue] = run(fun("    :not_implemented"))
      assert issue.message =~ ":not_implemented"
      assert issue.line_no == 2
    end

    test "error tuple with stub atom" do
      assert [_] = run(fun("    {:error, :not_implemented}"))
    end

    test "raise with a placeholder message" do
      assert [_] = run(fun("    raise \"not implemented\""))
      assert [_] = run(fun("    raise ArgumentError, \"TODO: later\""))
      assert [_] = run(fun("    raise \"stub for \#{x}\""))
    end

    test "stub exception module" do
      [issue] = run(fun("    raise NotImplementedError"))
      assert issue.message =~ "NotImplementedError"
    end

    test "tail position inside a branch" do
      source = fun("    case x do\n      :a -> 1\n      _ -> raise \"unimplemented\"\n    end")
      assert [_] = run(source)
    end

    test "defp and one-line def" do
      assert [_] = run("defmodule A do\n  defp f(_), do: :unimplemented\nend\n")
    end
  end

  describe "negatives and lookalikes" do
    test "real behaviour passes" do
      "    x + 1"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "stub atom as a pattern or earlier expression is not a tail" do
      source =
        fun(
          "    case g(x) do\n      {:error, :not_implemented} -> {:error, :unsupported}\n      v -> v\n    end"
        )

      source
      |> run()
      |> refute_issues()
    end

    test "unrelated raise messages pass" do
      "    raise ArgumentError, \"invalid input \#{inspect(x)}\""
      |> fun()
      |> run()
      |> refute_issues()
    end

    test ":todo is not a stub atom by default" do
      "    :todo"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "TODO comments are left to Credo's TagTODO" do
      "    # TODO later\n    x"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "raise followed by more code is not a tail stub" do
      "    _ = if x, do: raise(\"todo\")\n    :ok"
      |> fun()
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "custom stub atoms and pattern" do
      assert [_] = run(fun("    :todo"), "lib/a.ex", stub_atoms: [:todo])
      assert [_] = run(fun("    raise \"wip\""), "lib/a.ex", stub_pattern: ~r/wip/)
    end

    test "tests are not checked by default" do
      "    :not_implemented"
      |> fun()
      |> run("test/support/a.ex")
      |> refute_issues()
    end
  end
end
