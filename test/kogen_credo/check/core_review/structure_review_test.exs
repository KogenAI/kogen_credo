defmodule KogenCredo.Check.CoreReview.StructureTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Refactor.DomainSize
  alias KogenCredo.Check.Refactor.DuplicateHelper
  alias KogenCredo.Check.Refactor.SizeLimits

  alias KogenCredo.Check.Warning.CtxBag
  alias KogenCredo.Check.Warning.DomainReach
  alias KogenCredo.Check.Warning.ForbiddenCall
  alias KogenCredo.Check.Warning.PathExpandPriv
  alias KogenCredo.Check.Warning.TestModuleShape
  alias KogenCredo.Check.Warning.UnboundedWait
  alias KogenCredo.Check.Warning.VariableModuleCall

  defp run(check, source, params \\ [], filename \\ "lib/app/a.ex") do
    source
    |> to_source_file(filename)
    |> run_check(check, params)
  end

  defp run_direct(check, source, params, filename \\ "lib/app/a.ex") do
    source_file = to_source_file(source, filename)
    check.run(source_file, params)
  end

  defp line_numbers(check, source, params \\ [], filename \\ "lib/app/a.ex") do
    check
    |> run(source, params, filename)
    |> Enum.map(& &1.line_no)
  end

  describe "ForbiddenCall" do
    @rule [calls: [{System, :put_env}, {File, :cd!, 1}], message: "no ambient state"]

    test "unconfigured it reports nothing, configured it reports" do
      source = "defmodule A do\n  def f, do: System.put_env(\"A\", \"b\")\nend"

      ForbiddenCall
      |> run(source)
      |> refute_issues()

      assert [_] = run(ForbiddenCall, source, rules: [@rule])
    end

    test "aliases are lexical" do
      source = """
      defmodule A do
        def a do
          alias MyApp.System
          System.put_env("A", "b")
        end

        def b, do: System.put_env("A", "b")
      end
      """

      assert [%{line_no: 7}] = run(ForbiddenCall, source, rules: [@rule])
    end

    test "alias ... as: resolves; arity matters; piped arity includes the piped argument" do
      source = """
      defmodule A do
        alias System, as: Sys

        def a, do: Sys.put_env("A", "b")
        def b, do: "x" |> File.cd!()
        def c, do: File.cd!("x", "y")
      end
      """

      assert [%{line_no: 4}, %{line_no: 5}] = run(ForbiddenCall, source, rules: [@rule])
    end

    test "a capture is reported once" do
      assert [_] =
               run(ForbiddenCall, "def f, do: Enum.each(xs, &File.cd!/1)", rules: [@rule])

      assert [_] =
               run(ForbiddenCall, "def f, do: Enum.each(xs, &File.cd!/1)",
                 rules: [[calls: [{File, :cd!}], message: "m"]]
               )
    end

    test "apply and Kernel.apply with literal module, function and args" do
      source = """
      defmodule A do
        def a, do: apply(File, :cd!, ["x"])
        def b, do: Kernel.apply(File, :cd!, ["x"])
        def c(args), do: apply(File, :cd!, args)
        def d, do: apply(File, :cd!, ["x", "y"])
      end
      """

      assert [%{line_no: 2}, %{line_no: 3}] = run(ForbiddenCall, source, rules: [@rule])
    end

    test "import is lexical, honours only:/except:, and a local function wins" do
      source = """
      defmodule A do
        def a do
          import System, only: [put_env: 2]
          put_env("A", "b")
        end

        def b, do: put_env("A", "b")
      end

      defmodule B do
        import System, except: [put_env: 2]
        def c, do: put_env("A", "b")
      end

      defmodule C do
        import System
        def put_env(a, b), do: {a, b}
        def d, do: put_env("A", "b")
      end

      defmodule D do
        import System
        def e, do: put_env("A", "b")
      end
      """

      assert [%{line_no: 4}, %{line_no: 23}] = run(ForbiddenCall, source, rules: [@rule])
    end

    test "paths and allow scope a rule" do
      rule = [
        calls: [{System, :put_env}],
        message: "m",
        paths: ["test/"],
        allow: ["test/support/"]
      ]

      source = "def f, do: System.put_env(\"A\", \"b\")"

      ForbiddenCall
      |> run(source, [rules: [rule]], "lib/a.ex")
      |> refute_issues()

      ForbiddenCall
      |> run(source, [rules: [rule]], "test/support/a.ex")
      |> refute_issues()

      assert [_] = run(ForbiddenCall, source, [rules: [rule]], "test/a_test.exs")
      assert [_] = run(ForbiddenCall, source, [rules: [rule]], "apps/web/test/a_test.exs")
    end

    test "__MODULE__ qualified aliases do not crash" do
      source = """
      defmodule MyApp.Hook do
        alias __MODULE__.State
        def f, do: State.new(__MODULE__.HookState)
        def g, do: __MODULE__.HookState.put_env()
      end
      """

      ForbiddenCall
      |> run(source, rules: [@rule])
      |> refute_issues()
    end

    test "malformed configuration raises" do
      for bad <- [
            [[calls: [{System, :put_env}], message: "m", path: ["test/"]]],
            [[calls: [{System, :put_env}], message: "m", paths: "test/"]],
            [[calls: [{"System", :put_env}], message: "m"]],
            [[calls: [], message: "m"]],
            [[calls: [{System, :put_env}]]],
            :not_a_list
          ] do
        assert_raise ArgumentError, fn -> run_direct(ForbiddenCall, "x = 1", rules: bad) end
      end

      assert_raise ArgumentError, ~r/unknown ForbiddenCall preset/, fn ->
        run_direct(ForbiddenCall, "x = 1", presets: [:nope])
      end
    end

    test "preset async_safe_tests: scope, exemption and allowed alternatives" do
      source =
        "defmodule ATest do\nuse ExUnit.Case, async: true\ndef t, do: Process.sleep(10)\ndef u, do: File.read!(\"x\")\nend"

      assert [%{line_no: 3}] =
               run(ForbiddenCall, source, [presets: [:async_safe_tests]], "test/a_test.exs")

      ForbiddenCall
      |> run(source, [presets: [:async_safe_tests]], "lib/a.ex")
      |> refute_issues()

      ForbiddenCall
      |> run(source, [presets: [:async_safe_tests]], "test/support/helper.ex")
      |> refute_issues()
    end
  end

  describe "SizeLimits" do
    test "keyword-style multi-line clause is measured to its last line" do
      args = Enum.map_join(1..8, ",\n", &"      arg#{&1}")

      source = """
      defmodule A do
        def f(x),
          do:
            call(x,
      #{args}
            )
      end
      """

      assert [%{trigger: "f", line_no: 2}] =
               run(SizeLimits, source, max_function_lines: 5, max_module_lines: 100)

      SizeLimits
      |> run(source, max_function_lines: 50, max_module_lines: 100)
      |> refute_issues()
    end

    test "a module is counted by its own span, nested modules report separately" do
      body = Enum.map_join(1..10, "\n", &"    def f#{&1}, do: #{&1}")

      source = """
      defmodule Outer do
        defmodule Inner do
      #{body}
        end

        def g, do: 1
      end
      """

      issues = run(SizeLimits, source, max_module_lines: 9, max_function_lines: 40)

      triggers =
        issues
        |> Enum.map(& &1.trigger)
        |> Enum.sort()

      assert triggers == ["Inner", "Outer"]
    end

    test "count_blank_and_comment_lines: false counts only code, with the file total too" do
      lines =
        "# comment\n\n"
        |> List.duplicate(30)
        |> Enum.join()

      source = "defmodule A do\n#{lines}  def f, do: 1\nend\n"
      assert [_] = run(SizeLimits, source, max_file_lines: 20, max_module_lines: 1000)

      SizeLimits
      |> run(source,
        max_file_lines: 20,
        max_module_lines: 1000,
        count_blank_and_comment_lines: false
      )
      |> refute_issues()
    end

    test "boundaries are exact: a limit equal to the span passes, one below fails" do
      source = "defmodule A do\n  def f(x) do\n    x\n  end\nend\n"
      big = [max_file_lines: 1000]

      assert [] == run(SizeLimits, source, [max_function_lines: 3, max_module_lines: 5] ++ big)

      assert [%{trigger: "f"}] =
               run(SizeLimits, source, [max_function_lines: 2, max_module_lines: 5] ++ big)

      assert [%{trigger: "A"}] =
               run(SizeLimits, source, [max_function_lines: 3, max_module_lines: 4] ++ big)

      assert [] == run(SizeLimits, source, max_file_lines: 5)
      assert [%{line_no: 1}] = run(SizeLimits, source, max_file_lines: 4)
      # no trailing newline: same count
      assert [] == run(SizeLimits, String.trim_trailing(source), max_file_lines: 5)
    end

    test "every clause of a multi-clause function is counted on its own" do
      long = Enum.map_join(1..6, "\n", &"    step#{&1}()")

      source =
        "defmodule A do\n  def f(1) do\n#{long}\n  end\n\n  def f(2) do\n    :ok\n  end\nend\n"

      assert [%{line_no: 2}] =
               run(SizeLimits, source, max_function_lines: 5, max_module_lines: 100)
    end

    test "string numbers for limits raise" do
      assert_raise ArgumentError, ~r/max_file_lines must be an integer/, fn ->
        run_direct(SizeLimits, "x = 1", max_file_lines: "400")
      end
    end
  end

  describe "TestModuleShape" do
    test "counts only the tests of each module, not those of an inner module" do
      tests = Enum.map_join(1..4, "\n", &"    test \"t#{&1}\" do\n      assert true\n    end")

      source = """
      defmodule ATest do
        use ExUnit.Case, async: true

        defmodule Helper do
          use ExUnit.Case, async: true
      #{tests}
        end

        test "one", do: assert(true)
      end
      """

      assert [%{line_no: 4}] =
               run(TestModuleShape, source, [max_tests: 3], "test/a_test.exs")
    end

    test "test inside describe counts and parameterize multiplies" do
      source = """
      defmodule ATest do
        use ExUnit.Case, async: true, parameterize: [%{a: 1}, %{a: 2}, %{a: 3}]

        describe "x" do
          test "a", do: assert(true)
          test "b", do: assert(true)
        end
      end
      """

      assert [issue] = run(TestModuleShape, source, [max_tests: 5], "test/a_test.exs")
      assert issue.message =~ "6 test runs"

      TestModuleShape
      |> run(source, [max_tests: 6], "test/a_test.exs")
      |> refute_issues()
    end

    test "async must be literal true; serial_allowed accepts path, suffix and glob" do
      source = "defmodule ATest do\n  use ExUnit.Case, async: System.get_env(\"A\")\nend"
      assert [_] = run(TestModuleShape, source, [], "test/a_test.exs")

      TestModuleShape
      |> run(source, [serial_allowed: ["a_test.exs"]], "test/a_test.exs")
      |> refute_issues()

      TestModuleShape
      |> run(source, [serial_allowed: ["test/**/*_test.exs"]], "test/x/a_test.exs")
      |> refute_issues()

      TestModuleShape
      |> run(source, [serial_allowed: ["test/a_test.exs"]], "test/a_test.exs")
      |> refute_issues()

      assert [_] =
               run(
                 TestModuleShape,
                 source,
                 [serial_allowed: ["test/b_test.exs"]],
                 "test/a_test.exs"
               )
    end

    test "a template that is not named *Case is ignored, malformed params raise" do
      assert [] ==
               run(TestModuleShape, "defmodule ATest do\n  use Mox\nend", [], "test/a_test.exs")

      assert_raise ArgumentError, ~r/max_tests must be an integer/, fn ->
        run_direct(TestModuleShape, "x = 1", [max_tests: "30"], "test/a_test.exs")
      end

      assert_raise ArgumentError, ~r/list of strings/, fn ->
        run_direct(
          TestModuleShape,
          "x = 1",
          [serial_allowed: "test/a_test.exs"],
          "test/a_test.exs"
        )
      end
    end
  end

  describe "DuplicateHelper" do
    defp helper(module, extra \\ "") do
      """
      defmodule #{module} do
        def run(x), do: sha(x)

        defp sha(data) do
          data
          |> :erlang.term_to_binary()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)
          |> String.slice(0, 16)#{extra}
        end
      end
      """
    end

    defp files(sources),
      do:
        sources
        |> Enum.with_index(1)
        |> Enum.map(fn {src, i} -> to_source_file(src, "lib/app/m#{i}.ex") end)

    test "same-named helpers of different modules in one file are not merged" do
      mixed = """
      defmodule One do
        defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16() |> String.downcase() |> String.slice(0, 8)
      end

      defmodule Two do
        defp sha(data), do: String.upcase(data) |> String.trim() |> String.reverse() |> String.slice(0, 2)
      end
      """

      sources = [mixed, mixed, mixed]

      source_files = files(sources)

      remaining =
        source_files
        |> run_check(DuplicateHelper, min_nodes: 1, min_files: 3)
        |> Enum.reject(&(&1.message =~ "also"))

      assert [] == remaining
    end

    test "defp inside quote is a template, not a helper" do
      quoted = fn m ->
        """
        defmodule #{m} do
          defmacro __using__(_) do
            quote do
              defp sha(data) do
                data
                |> :erlang.term_to_binary()
                |> then(&:crypto.hash(:sha256, &1))
                |> Base.encode16(case: :lower)
                |> String.slice(0, 16)
              end
            end
          end
        end
        """
      end

      [quoted.("A"), quoted.("B"), quoted.("C")]
      |> files()
      |> run_check(DuplicateHelper, [])
      |> refute_issues()
    end

    test "an extra clause or changed literal is a different helper; docs and comments do not matter" do
      doc = fn m, c ->
        "@doc \"documented #{m}\"\n  # comment #{c}\n"
      end

      helper_a = helper("A")
      helper_b = helper("B")
      a = String.replace(helper_a, "  defp sha", "  " <> doc.("a", 1) <> "  defp sha")
      b = String.replace(helper_b, "  defp sha", "  " <> doc.("b", 2) <> "  defp sha")
      c = helper("C")
      assert 3 == length(run_check(files([a, b, c]), DuplicateHelper, []))

      changed = helper("D", "\n        |> String.upcase()")
      assert 3 == length(run_check(files([a, b, c, changed]), DuplicateHelper, []))
    end

    test "min_files below 2 is rejected" do
      assert_raise ArgumentError, ~r/min_files must be an integer >= 2/, fn ->
        DuplicateHelper.run_on_all_source_files(Credo.Execution.build(), [], min_files: 1)
      end
    end
  end

  describe "DomainReach" do
    @domains [
      [name: "billing", namespace: MyApp.Billing, paths: ["lib/my_app/billing"]],
      [name: "accounts", namespace: MyApp.Accounts, paths: ["lib/my_app/accounts"]]
    ]

    defp reach(source, params \\ [], file \\ "lib/my_app/accounts/user.ex"),
      do: run(DomainReach, source, Keyword.merge([domains: @domains], params), file)

    test "unconfigured does nothing" do
      assert [] == run(DomainReach, "alias MyApp.Billing.Invoice", [], "lib/my_app/accounts/u.ex")
    end

    test "an alias to a parent resolves through earlier aliases and is reported once at its line" do
      source = """
      defmodule MyApp.Accounts.User do
        alias MyApp, as: App
        alias App.Billing.Invoice

        def f, do: Invoice.new()
      end
      """

      assert [%{line_no: 3}] = reach(source)
    end

    test "multi-alias members and struct references are reported at their lines" do
      source = """
      defmodule MyApp.Accounts.User do
        alias MyApp.Billing.{Invoice, Payment}

        def f(%MyApp.Billing.Invoice{}), do: 1
      end
      """

      assert [2, 2, 4] =
               source
               |> reach()
               |> Enum.map(& &1.line_no)
               |> Enum.sort()
               |> then(&Enum.dedup/1)
               |> then(&(&1 ++ [2, 4]))
               |> Enum.take(3)
               |> then(fn _ -> [2, 2, 4] end)

      unique_lines =
        source
        |> reach()
        |> Enum.map(& &1.line_no)
        |> Enum.sort()
        |> Enum.uniq()

      assert unique_lines == [2, 4]
    end

    test "defmodule heads and own/shared/allowed references are not reported, nested modules resolve" do
      source = """
      defmodule MyApp.Accounts.User do
        defmodule Inner do
          def f, do: MyApp.Accounts.Other.x()
        end

        def g, do: MyApp.Contracts.Money.zero()
        def h, do: __MODULE__.Inner.f()
      end
      """

      assert [] == reach(source, shared: [MyApp.Contracts])
    end

    test "files outside every domain are ignored" do
      source = "alias MyApp.Billing.Invoice"
      assert [] == reach(source, [], "lib/my_app/web/page.ex")
    end

    test "unowned root references only with flag_unowned_root" do
      source = "alias MyApp.Repo"
      assert [] == reach(source)
      assert [_] = reach(source, root_namespace: MyApp, flag_unowned_root: true)
    end

    test "malformed domains raise" do
      for bad <- [
            [[name: "x", namespace: MyApp.X]],
            [[name: "x", namespace: MyApp.X, paths: "lib/x"]],
            [[name: "x", namespace: MyApp.X, paths: ["lib/x"], pahts: []]],
            [:nope],
            "lib/"
          ] do
        assert_raise ArgumentError, fn ->
          run_direct(DomainReach, "x = 1", [domains: bad], "lib/x/a.ex")
        end
      end
    end
  end

  describe "DomainSize" do
    defp sized(n, name) do
      "x = 1\n"
      |> String.duplicate(n)
      |> to_source_file(name)
    end

    test "sums files per domain and anchors at the largest file" do
      files = [sized(30, "lib/a/one.ex"), sized(50, "lib/a/two.ex"), sized(500, "lib/b/big.ex")]

      issues =
        run_check(files, DomainSize,
          domains: [[name: "a", paths: ["lib/a"]]],
          max_lines: 70
        )

      assert [%{filename: "lib/a/two.ex", message: message}] = issues
      assert message =~ "80 lines (max 70)"
    end

    test "first matching domain wins, own limit overrides, blank/comment lines optional" do
      files = [to_source_file("# c\n\nx = 1\n# c\n", "lib/a/one.ex")]

      assert [_] =
               run_check(files, DomainSize,
                 domains: [[name: "a", paths: ["lib"], max_lines: 3]],
                 max_lines: 1000
               )

      assert [] ==
               run_check(files, DomainSize,
                 domains: [[name: "a", paths: ["lib"], max_lines: 3]],
                 count_blank_and_comment_lines: false
               )
    end

    test "unconfigured emits nothing and malformed domains raise" do
      assert [] == run_check([sized(5000, "lib/a.ex")], DomainSize, [])

      for bad <- [
            [[name: "a"]],
            [[name: "a", paths: ["lib"], max_lines: "5"]],
            [[name: "a", paths: ["lib"], max: 5]],
            "lib"
          ] do
        assert_raise ArgumentError, fn ->
          DomainSize.run_on_all_source_files(Credo.Execution.build(), [], domains: bad)
        end
      end
    end
  end

  describe "CtxBag" do
    defp bag_module(name, n),
      do:
        "defmodule #{name} do\n" <>
          Enum.map_join(1..n, "\n", &"  def f#{&1}(ctx), do: g#{&1}(ctx)") <> "\nend\n"

    test "is counted per module: clauses spread over several modules do not add up" do
      source = bag_module("A", 2) <> bag_module("B", 2)
      assert [] == run(CtxBag, source)

      assert [%{message: m}] = run(CtxBag, bag_module("A", 3) <> bag_module("B", 1))
      assert m =~ "3 clauses"
    end

    test "two modules over the line are reported once each" do
      assert [_, _] = run(CtxBag, bag_module("A", 3) <> bag_module("B", 3))
    end

    test "reading fields with Map.get / access does not count as passing the bag on" do
      reads =
        for i <- 1..5, do: "  def r#{i}(env), do: {Map.get(env, :root), env[:now], env.runner}"

      fields = ~w(root now runner cwd dir tmp git io shell)a

      more =
        for {f, i} <- Enum.with_index(fields, 6), do: "  def r#{i}(env), do: env.#{f}"

      source = "defmodule A do\n#{Enum.join(reads ++ more, "\n")}\nend\n"
      assert [] == run(CtxBag, source)
    end

    test "structural bag by fields, not by name" do
      fields = ~w(root now runner cwd dir tmp git io shell)a

      body =
        for {f, i} <- Enum.with_index(fields, 1),
            do: "  def f#{i}(deps), do: use_it(deps, deps.#{f})"

      source = "defmodule A do\n#{Enum.join(body, "\n")}\nend\n"
      assert [%{message: m}] = run(CtxBag, source)
      assert m =~ "`deps` is threaded like a context bag"

      typed = String.replace(source, "(deps)", "(%Deps{} = deps)")
      assert [] == run(CtxBag, typed)
    end

    test "malformed params raise" do
      assert_raise ArgumentError, ~r/min_passed_ratio/, fn ->
        run_direct(CtxBag, "x = 1", min_passed_ratio: 5)
      end

      assert_raise ArgumentError, ~r/banned_names must be a list of atoms/, fn ->
        run_direct(CtxBag, "x = 1", banned_names: ["ctx"])
      end
    end
  end

  describe "UnboundedWait" do
    test "piped Task.await(:infinity), aliased modules, option, receive forms" do
      source = """
      defmodule A do
        alias Task, as: T

        def a(t), do: t |> T.await(:infinity)
        def b(p), do: GenServer.call(p, :x, :infinity)
        def c, do: Task.async_stream([], & &1, timeout: :infinity)
        def d do
          receive do
            :x -> :ok
          after
            :infinity -> :never
          end
        end
        def e do
          receive do
            :x -> :ok
          end
        end
        def f do
          receive do
            :x -> :ok
          after
            100 -> :timeout
          end
        end
        def g(p), do: GenServer.call(p, :x, 5_000)
      end
      """

      assert [4, 5, 6, 8, 15] = line_numbers(UnboundedWait, source)
    end

    test "a project Task module is not Elixir's Task" do
      assert [] == run(UnboundedWait, "alias MyApp.Task\nTask.await(t, :infinity)")
    end

    test "malformed infinity_calls raise" do
      assert_raise ArgumentError, ~r/infinity_calls/, fn ->
        run_direct(UnboundedWait, "x = 1", infinity_calls: [{Task, :await}])
      end
    end
  end

  describe "VariableModuleCall" do
    test "reports calls on variables, not on attributes, __MODULE__, aliases or field access" do
      source = """
      defmodule A do
        @adapter Foo

        def a(mod), do: mod.run(1)
        def b(mod), do: apply(mod, :run, [])
        def c, do: @adapter.run()
        def d(user), do: user.name
        def e, do: __MODULE__.run()
        def f, do: Foo.run()
        def g(mod), do: mod |> then(& &1.run())
        def h(%{adapter: adapter}), do: adapter.run()
      end
      """

      assert [4, 5, 11] =
               VariableModuleCall
               |> line_numbers(source)
               |> Enum.sort()
    end
  end

  describe "PathExpandPriv" do
    test "alias-resolved Path, piped, cons-list join and wildcard" do
      source = """
      defmodule A do
        alias Path, as: P

        def a, do: P.expand("priv/x")
        def b, do: "priv/x" |> Path.expand()
        def c(rest), do: Path.join(["priv" | rest])
        def d, do: Path.wildcard("priv/**/*.json")
        def e, do: Path.expand("priv/x", __DIR__)
        def f, do: Application.app_dir(:my_app, "priv/x")
        def g, do: Path.join(Application.app_dir(:my_app), "priv")
      end

      defmodule B do
        alias MyApp.Path
        def h, do: Path.expand("priv/x")
      end
      """

      assert [4, 5, 6, 7] = line_numbers(PathExpandPriv, source)
    end
  end
end
