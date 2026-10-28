defmodule KogenCredo.Check.Warning.VariableModuleCallTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.VariableModuleCall

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(VariableModuleCall, params)
  end

  describe "positives" do
    test "call on a variable" do
      [issue] = run("defmodule A do def f(mod, x), do: mod.run(x) end")
      assert issue.message =~ "mod.run(...)"
    end

    test "zero-arity parenthesised call" do
      assert [_] = run("defmodule A do def f(mod), do: mod.name() end")
    end

    test "piped call on a variable module" do
      assert [_] = run("defmodule A do def f(mod, x), do: x |> mod.run() end")
    end

    test "apply with a variable module" do
      assert [_] = run("defmodule A do def f(mod, fun, args), do: apply(mod, fun, args) end")
    end
  end

  describe "valid lookalikes" do
    test "field access without parentheses" do
      "defmodule A do def f(socket, user), do: {socket.assigns, user.name} end"
      |> run()
      |> refute_issues()
    end

    test "literal module, attribute module and __MODULE__" do
      source = """
      defmodule A do
        @adapter Application.compile_env(:app, :adapter)
        def f(x), do: {Mod.run(x), @adapter.run(x), __MODULE__.other(x)}
      end
      """

      source
      |> run()
      |> refute_issues()
    end

    test "anonymous function call" do
      "defmodule A do def f(fun, x), do: fun.(x) end"
      |> run()
      |> refute_issues()
    end

    test "apply with a literal module" do
      "defmodule A do def f(args), do: apply(Mod, :run, args) end"
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "allowed_variables" do
      "defmodule A do def f(adapter, x), do: adapter.run(x) end"
      |> run("lib/a.ex", allowed_variables: [:adapter])
      |> refute_issues()
    end

    test "ignored_functions" do
      "defmodule A do def f(mod), do: mod.module_info() end"
      |> run()
      |> refute_issues()
    end

    test "check_apply false" do
      "defmodule A do def f(m, f, a), do: apply(m, f, a) end"
      |> run("lib/a.ex", check_apply: false)
      |> refute_issues()
    end

    test "tests are skipped by default" do
      "defmodule A do def f(mod), do: mod.run() end"
      |> run("test/a_test.exs")
      |> refute_issues()
    end
  end
end
