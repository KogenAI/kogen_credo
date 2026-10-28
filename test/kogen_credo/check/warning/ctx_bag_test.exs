defmodule KogenCredo.Check.Warning.CtxBagTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.CtxBag

  defp run(source, filename \\ "lib/app/runner.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(CtxBag, params)
  end

  defp ctx_module(n) do
    funs = for i <- 1..n, do: "  def f#{i}(ctx), do: g#{i}(ctx)\n"
    "defmodule App.Runner do\n#{funs}end\n"
  end

  describe "named bag" do
    test "reports ctx used in several clauses" do
      [issue] = run(ctx_module(3))
      assert issue.message =~ "`ctx` is a bag-style parameter name"
      assert issue.message =~ "3 clauses"
    end

    test "does not report below min_named_clauses" do
      2
      |> ctx_module()
      |> run()
      |> refute_issues()
    end

    test "min_named_clauses param lowers the bar" do
      assert [_] = run(ctx_module(2), "lib/app/runner.ex", min_named_clauses: 2)
    end

    test "allowed_names exempts a name" do
      5
      |> ctx_module()
      |> run("lib/app/runner.ex", allowed_names: [:ctx])
      |> refute_issues()
    end

    test "ordinary parameter names are fine" do
      """
      defmodule App.Runner do
        def f1(root), do: g(root)
        def f2(root), do: g(root)
        def f3(root), do: g(root)
        def f4(root), do: g(root)
      end
      """
      |> run()
      |> refute_issues()
    end
  end

  describe "structural bag" do
    defp structural(extra \\ "") do
      reads = Enum.map_join(~w(root env now runner cwd a b c), "\n", &"    _ = state.#{&1}")

      """
      defmodule App.Worker do
        def one(state), do: two(state)
        def two(state), do: three(state)
        def three(state), do: four(state)
        def four(state#{extra}) do
      #{reads}
          :ok
        end
      end
      """
    end

    test "reports a differently named bag with many ambient fields" do
      [issue] = run(structural())
      assert issue.message =~ "`state` is threaded like a context bag"
    end

    test "a struct-typed parameter is exempt" do
      source = String.replace(structural(), "def one(state)", "def one(%App.State{} = state)")

      source
      |> run()
      |> refute_issues()
    end

    test "thresholds can be raised" do
      refute_issues(run(structural(), "lib/app/worker.ex", min_fields: 20))
    end
  end

  describe "scope" do
    test "test files are skipped by default" do
      5
      |> ctx_module()
      |> run("test/app/runner_test.exs")
      |> refute_issues()
    end

    test "included_paths can add test paths" do
      assert [_] = run(ctx_module(5), "test/support/x.ex", included_paths: ["test/"])
    end

    test "excluded_paths skip files" do
      5
      |> ctx_module()
      |> run("lib/app/web/runner.ex", excluded_paths: ["lib/app/web"])
      |> refute_issues()
    end
  end
end
