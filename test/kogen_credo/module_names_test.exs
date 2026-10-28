defmodule KogenCredo.ModuleNamesTest do
  # Modules in analysed code are identified by name. None of these tests may need the module to
  # be loaded, and the analysis must not create an atom for a name it only reads.
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.BroadRescue
  alias KogenCredo.Check.Warning.DomainReach
  alias KogenCredo.Check.Warning.ForbiddenCall
  alias KogenCredo.Check.Warning.GlobalNameInventory
  alias KogenCredo.Check.Warning.GlobalStateInAsync
  alias KogenCredo.Check.Warning.StringKeyAccess
  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Modules
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings
  alias KogenCredo.Diff
  alias KogenCredo.Diff.CLI
  alias KogenCredo.Diff.Rules.ChangesetWeakened
  alias KogenCredo.Diff.Rules.QueryLostScope
  alias KogenCredo.Integrity
  alias KogenCredo.Integrity.ModuleRef
  alias KogenCredo.SafetySupport

  defp run(check, source, params, filename \\ "lib/app/a.ex") do
    source
    |> to_source_file(filename)
    |> run_check(check, params)
  end

  # A module name no code of this VM mentions: the parser makes atoms for its segments, but
  # nothing may make the atom of the whole module.
  defp unknown_name do
    "Zz#{System.unique_integer([:positive])}.Billing.Invoice"
  end

  defp refute_module_atom(name) do
    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
  end

  defp remote_calls(source) do
    source
    |> Code.string_to_quoted!()
    |> Scope.walk([], fn
      {{:., _, [mod, fun]}, _, []}, env, acc when is_atom(fun) ->
        [{fun, Aliases.resolve(mod, env.aliases)} | acc]

      _, _, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  describe "aliases that no loaded code mentions" do
    test "resolve to their name without creating the module atom" do
      name = unknown_name()
      [root | _] = String.split(name, ".")

      calls = remote_calls("alias #{root}.Billing\nBilling.Invoice.pay()\n#{name}.pay()")

      assert calls == [pay: name, pay: name]
      refute_module_atom(name)
    end

    test "lexical alias chains expand through earlier aliases, per scope" do
      [root | _] = String.split(unknown_name(), ".")

      calls =
        remote_calls("""
        defmodule #{root}.App do
          alias #{root}.Infra
          alias Infra.Disk

          def a do
            Disk.read()
            alias Disk.Cache
            Cache.get()
          end

          def b, do: Cache.get()
        end
        """)

      assert calls == [
               read: "#{root}.Infra.Disk",
               get: "#{root}.Infra.Disk.Cache",
               get: "Cache"
             ]

      refute_module_atom("#{root}.Infra.Disk.Cache")
    end

    test "nested defmodule and __MODULE__ build their names from the enclosing name" do
      [root | _] = String.split(unknown_name(), ".")

      calls =
        remote_calls("""
        defmodule #{root} do
          defmodule Inner do
            def f, do: __MODULE__.x()
          end

          def g, do: Inner.y()
        end
        """)

      assert calls == [x: "#{root}.Inner", y: "#{root}.Inner"]
      refute_module_atom("#{root}.Inner")
    end

    test "Erlang modules keep their colon and Elixir. prefixes are dropped" do
      assert Aliases.resolve(:rand, %{}) == ":rand"
      assert Aliases.resolve(Enum, %{}) == "Enum"
      assert Ast.module_name(:"Elixir.Foo.Bar") == "Foo.Bar"
      assert Ast.join_name([:"Elixir", :Foo]) == "Foo"
      assert Ast.join_name(["MyApp.Billing", :Invoice]) == "MyApp.Billing.Invoice"
    end
  end

  describe "Modules.prune/2 prefixes" do
    @source """
    defmodule MyApp.Codec do
      defmodule Inner do
        def a, do: %{"k" => 1}
      end
    end

    defmodule MyApp.CodecExtra do
      def b, do: %{"k" => 2}
    end
    """

    defp pruned(skip) do
      @source
      |> Code.string_to_quoted!()
      |> Modules.prune(skip)
      |> Macro.to_string()
    end

    test "atom and string forms prune the same modules" do
      for skip <- [[MyApp.Codec], ["MyApp.Codec"], ["Elixir.MyApp.Codec"]] do
        out = pruned(skip)
        refute out =~ "def a"
        assert out =~ "def b"
      end
    end

    test "a prefix naming a module that does not exist anywhere still prunes by name" do
      name = unknown_name()

      source =
        "defmodule #{name} do\n  def a, do: 1\nend\ndefmodule Other do\n  def b, do: 2\nend"

      out =
        source
        |> Code.string_to_quoted!()
        |> Modules.prune([name])
        |> Macro.to_string()

      refute out =~ "def a"
      assert out =~ "def b"
      refute_module_atom(name)
    end
  end

  describe "checks with modules that are not loaded" do
    test "ForbiddenCall reports a banned module reached through an alias or an import" do
      source = """
      defmodule A do
        alias MyApp.NotLoaded, as: NL
        import MyApp.NotLoaded.Banned, only: [boom: 1]

        def f, do: NL.Banned.boom(1)
        def g, do: boom(2)
        def h, do: NL.Other.boom(3)
      end
      """

      rules = [[calls: [{MyApp.NotLoaded.Banned, :boom}], message: "no"]]
      issues = run(ForbiddenCall, source, rules: rules)

      assert Enum.map(issues, & &1.line_no) == [5, 6]
      assert Enum.all?(issues, &(&1.message =~ "`MyApp.NotLoaded.Banned.boom/1` is forbidden"))
    end

    test "ForbiddenCall trigger text of Erlang and Elixir modules is unchanged" do
      source = "defmodule A do\n  def f, do: :timer.sleep(1)\nend"
      rules = [[calls: [{:timer, :sleep}], message: "no"]]

      assert [issue] = run(ForbiddenCall, source, rules: rules)
      assert issue.message =~ "`:timer.sleep/1` is forbidden"
      assert issue.trigger == "sleep"
    end

    test "BroadRescue matches configured exceptions through lexical aliases" do
      source = """
      defmodule A do
        alias MyApp.NotLoaded, as: NL

        def f do
          risky()
        rescue
          e in NL.Error -> {:error, e}
        end
      end
      """

      assert [%{line_no: 7}] = run(BroadRescue, source, broad_exceptions: [MyApp.NotLoaded.Error])
      assert [] = run(BroadRescue, source, broad_exceptions: [MyApp.NotLoaded.Other])
    end

    test "StringKeyAccess prunes codec modules given as atoms, never as strings" do
      source = """
      defmodule MyApp.NotLoaded.Wire do
        def f(params), do: Map.get(params, "id")
      end
      """

      assert [] = run(StringKeyAccess, source, codec_modules: [MyApp.NotLoaded.Wire])
      assert [_] = run(StringKeyAccess, source, codec_modules: [MyApp.NotLoaded.Other])

      source_file = to_source_file(source, "lib/app/a.ex")

      assert_raise ArgumentError, ~r/codec_modules must be a list of atoms/, fn ->
        StringKeyAccess.run(source_file, codec_modules: ["X"])
      end
    end

    test "DomainReach compares namespaces by name and prints the same message" do
      source = """
      defmodule MyApp.A.Thing do
        alias MyApp.B.Internal
        def f, do: Internal.go()
      end
      """

      domains = [
        [name: "a", namespace: MyApp.A, paths: ["lib/a/"]],
        [name: "b", namespace: MyApp.B, paths: ["lib/b/"]]
      ]

      params = [domains: domains, shared: [MyApp.Shared, MyApp.Ports]]

      assert [issue] = run(DomainReach, source, params, "lib/a/thing.ex")
      assert issue.trigger == "MyApp.B.Internal"

      assert issue.message ==
               "Domain `a` references MyApp.B.Internal (domain `b`). Depend on a shared contract/port " <>
                 "([MyApp.Shared, MyApp.Ports]) or an event instead of another domain's internals."
    end
  end

  describe "SafetySupport.repo_receiver?/3" do
    test "repo names and modules match by name, as atoms or strings, for unknown repos" do
      tree = Code.string_to_quoted!("alias Zz.Data.Store, as: S")
      aliases = SafetySupport.aliases(tree)
      node = {:__aliases__, [], [:S]}

      assert SafetySupport.repo_receiver?(node, aliases, repo_names: ["Store"])
      assert SafetySupport.repo_receiver?(node, aliases, repo_names: [:Store])
      assert SafetySupport.repo_receiver?(node, aliases, repo_modules: ["Zz.Data.Store"])
      assert SafetySupport.repo_receiver?(node, aliases, repo_modules: [Zz.Data.Store])
      refute SafetySupport.repo_receiver?(node, aliases, repo_names: ["Repo"])
    end
  end

  describe "field and repo names given as strings" do
    defp mod(body), do: "defmodule App.X do\n#{body}\nend\n"

    defp hits(rule, base, head, opts) do
      {:ok, changes} = Diff.changes("lib/app/x.ex", base, head)
      Diff.check(changes, [rule], opts)
    end

    test "QueryLostScope accepts string and atom fields, including unknown ones" do
      field = "tenant_#{System.unique_integer([:positive])}"
      base = mod("def get(id, t), do: Repo.get_by(Doc, id: id, #{field}: t)")
      head = mod("def get(id, _t), do: Repo.get_by(Doc, id: id)")

      assert [hit] = hits(QueryLostScope, base, head, sensitive_fields: [field])
      assert hit.message =~ ":#{field} (1 -> 0)"
      assert [] = hits(QueryLostScope, base, head, sensitive_fields: ["other_scope"])
    end

    test "ChangesetWeakened accepts string cast fields" do
      base = mod("def cs(u, a), do: cast(u, a, [:name])")
      head = mod("def cs(u, a), do: cast(u, a, [:name, :plan])")

      assert [hit] = hits(ChangesetWeakened, base, head, cast_sensitive_fields: ["plan"])
      assert hit.message =~ "added :plan to cast"
      assert [] = hits(ChangesetWeakened, base, head, cast_sensitive_fields: ["role"])
    end

    test "repo names accept strings and atoms" do
      base = mod("def get(id, t), do: Data.get_by(Doc, id: id, tenant_x: t)")
      head = mod("def get(id, _t), do: Data.get_by(Doc, id: id)")
      fields = [sensitive_fields: [:tenant_x]]

      assert [_] = hits(QueryLostScope, base, head, [repo_names: ["Data"]] ++ fields)
      assert [_] = hits(QueryLostScope, base, head, [repo_names: [:Data]] ++ fields)
      assert [] = hits(QueryLostScope, base, head, fields)
    end

    test "the CLI keeps valid names it has never seen as strings" do
      unique = System.unique_integer([:positive])
      field = "scope_#{unique}"
      cast = "cast_#{unique}"
      repo = "Store#{unique}"

      assert {:ok, "a..b", opts, :text, :error} =
               CLI.parse([
                 "a..b",
                 "--sensitive-field",
                 field,
                 "--cast-sensitive-field",
                 cast,
                 "--repo-name",
                 repo
               ])

      assert opts[:sensitive_fields] == [field]
      assert opts[:cast_sensitive_fields] == [cast]
      assert opts[:repo_names] == [repo]

      for name <- [field, cast, repo] do
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end

    test "the CLI still rejects names that are not identifiers" do
      assert {:error, "invalid --sensitive-field" <> _} =
               CLI.parse(["a..b", "--sensitive-field", "Bad Field"])

      assert {:error, "invalid --repo-name" <> _} =
               CLI.parse(["a..b", "--repo-name", "lower_case"])
    end
  end

  describe "Integrity module references" do
    test "a module written in a config is a name, never an atom, and never a plain string" do
      name = "Zz#{System.unique_integer([:positive])}.Check"
      source = ~s|%{configs: [%{name: "default", checks: [{#{name}, []}]}]}|

      assert {:ok, %{configs: [%{checks: [{%ModuleRef{name: ^name}, []}]}]}} =
               Integrity.parse_config(source)

      refute_module_atom(name)
    end

    test "Elixir-prefixed atoms and aliases are the same reference, a string is not" do
      golden = ~S|%{configs: [%{name: "default", checks: [{A, []}]}]}|
      same = ~S|%{configs: [%{name: "default", checks: [{:"Elixir.A", []}]}]}|
      string = ~S|%{configs: [%{name: "default", checks: [{"A", []}]}]}|

      assert {:ok, []} = Integrity.compare_sources(golden, same)
      assert {:error, {:actual, :not_a_credo_config}} = Integrity.compare_sources(golden, string)
    end

    test "references print like the module" do
      assert inspect(%ModuleRef{name: "Credo.Check.Design.TagTODO"}) ==
               "Credo.Check.Design.TagTODO"
    end
  end

  describe "Ast.inspect_names/1" do
    test "matches inspect/1 of the same module atoms, including its limit" do
      short = [MyApp.Shared, MyApp.Ports, :ets]
      loaded = Application.spec(:elixir, :modules)
      long = Enum.take(loaded, 60)

      for atoms <- [[], short, long] do
        names = Enum.map(atoms, &Ast.atom_name/1)
        assert Ast.inspect_names(names) == inspect(atoms)
      end
    end
  end

  test "unresolved child aliases keep Supervisor names opaque" do
    source = """
    defmodule MyApp.Workers do
      alias __MODULE__.Supervisor
      def start, do: Supervisor.start_link([], name: MyApp.Workers.Sup)
    end
    """

    GlobalNameInventory
    |> run(source, [])
    |> refute_issues()
  end

  test "unresolved child aliases do not become Application global-state calls" do
    source = """
    defmodule MyApp.WorkerTest do
      use ExUnit.Case, async: true
      alias __MODULE__.Application
      test "updates a worker" do
        Application.put_env(:my_app, :value, 1)
      end
    end
    """

    GlobalStateInAsync
    |> run(source, [], "test/worker_test.exs")
    |> refute_issues()
  end

  test "module-list validation preserves legacy boolean atom entries" do
    assert Settings.modules!([true, false], :ignored_modules) == [":true", ":false"]
    assert_raise ArgumentError, fn -> Settings.modules!([nil], :ignored_modules) end
    assert_raise ArgumentError, fn -> Settings.modules!(["Map"], :ignored_modules) end
  end
end
