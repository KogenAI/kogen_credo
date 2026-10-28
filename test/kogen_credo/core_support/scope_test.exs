defmodule KogenCredo.CoreSupport.ScopeTest do
  use ExUnit.Case, async: true

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Modules
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings

  defp ast(source), do: Code.string_to_quoted!(source)

  # Collects `{called_function, resolved_module}` for every remote call `X.f()`.
  defp remote_calls(source) do
    source
    |> ast()
    |> Scope.walk([], fn
      {{:., _, [mod, fun]}, _, []}, env, acc when is_atom(fun) ->
        [{fun, Aliases.resolve(mod, env.aliases)} | acc]

      _, _, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  describe "Scope.walk aliases" do
    test "an alias in one function does not leak into the next" do
      calls =
        remote_calls("""
        defmodule M do
          def a do
            alias MyApp.File
            File.cd!()
          end

          def b, do: File.cd!()
        end
        """)

      assert calls == [cd!: "MyApp.File", cd!: "File"]
    end

    test "an alias applies only after its declaration within a block" do
      calls =
        remote_calls(
          "defmodule M do\n  def a do\n    Sys.x()\n    alias System, as: Sys\n    Sys.y()\n  end\nend"
        )

      assert calls == [x: "Sys", y: "System"]
    end

    test "chained aliases expand through earlier aliases" do
      calls = remote_calls("alias MyApp.Infra\nalias Infra.Disk\nDisk.read()")
      assert calls == [read: "MyApp.Infra.Disk"]
    end

    test "multi-alias, as: and __MODULE__ forms" do
      source = """
      defmodule Outer do
        alias __MODULE__.Inner
        alias Elixir.System, as: Sys
        alias Foo.{Bar, Baz.Qux}

        def f do
          Inner.a()
          Sys.b()
          Bar.c()
          Qux.d()
          __MODULE__.e()
        end
      end
      """

      assert remote_calls(source) == [
               a: "Outer.Inner",
               b: "System",
               c: "Foo.Bar",
               d: "Foo.Baz.Qux",
               e: "Outer"
             ]
    end

    test "nested defmodule is Outer.Inner and aliases Inner for later siblings" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def f, do: __MODULE__.x()
        end

        def g, do: Inner.y()
      end
      """

      assert remote_calls(source) == [x: "Outer.Inner", y: "Outer.Inner"]
    end

    test "a nested defmodule that repeats the parent name is not deduplicated (Elixir semantics)" do
      source = """
      defmodule Outer do
        defmodule Outer.Inner do
          def f, do: __MODULE__.x()
        end
      end
      """

      assert remote_calls(source) == [x: "Outer.Outer.Inner"]
    end
  end

  describe "Scope.walk imports" do
    defp imports_at_calls(source) do
      source
      |> ast()
      |> Scope.walk([], fn
        {:probe, _, []}, env, acc -> [env.imports | acc]
        _, _, acc -> acc
      end)
      |> Enum.reverse()
    end

    test "import is visible after declaration and only inside its function" do
      source = """
      defmodule M do
        def a do
          probe()
          import System, only: [put_env: 2]
          probe()
        end

        def b, do: probe()
      end
      """

      assert imports_at_calls(source) == [[], [{"System", [put_env: 2]}], []]
    end

    test "except: and plain import" do
      source = "import System, except: [halt: 1]\nimport File\nprobe()"
      assert imports_at_calls(source) == [[{"File", :all}, {"System", {:except, [halt: 1]}}]]
    end
  end

  describe "Aliases.resolve with __MODULE__" do
    test "resolves only when the enclosing module is known" do
      node = ast("__MODULE__.Child")
      assert Aliases.resolve(node, %{__MODULE__: "Parent"}) == "Parent.Child"
      assert Aliases.resolve(node, %{}) == nil
      module_node = ast("__MODULE__")
      assert Aliases.resolve(module_node, %{__MODULE__: "Parent"}) == "Parent"
    end
  end

  describe "Modules.prune" do
    defp pruned(source, skip) do
      source
      |> ast()
      |> Modules.prune(skip)
      |> Macro.to_string()
    end

    test "removes nested modules whose full name is under a skipped module" do
      source = """
      defmodule MyApp.Codec do
        defmodule Inner do
          def a, do: %{"k" => 1}
        end
      end

      defmodule MyApp.Other do
        def b, do: %{"k" => 2}
      end
      """

      out = pruned(source, [MyApp.Codec])
      refute out =~ "def a"
      assert out =~ "def b"
    end

    test "a nested defmodule that repeats a skipped name is a different module" do
      source = """
      defmodule Foo do
        defmodule Foo.Codec do
          def a, do: 1
        end
      end
      """

      assert pruned(source, [Foo.Codec]) =~ "def a"
      refute pruned(source, [Foo.Foo.Codec]) =~ "def a"
    end

    test "does not match on a name prefix without a dot" do
      source = "defmodule MyApp.CodecExtra do\n  def a, do: 1\nend"
      assert pruned(source, [MyApp.Codec]) =~ "def a"
    end
  end

  describe "malformed settings raise instead of passing silently" do
    test "path lists must be lists of strings" do
      assert_raise ArgumentError, ~r/list of strings/, fn ->
        (&Paths.in_paths?/2).("lib/a.ex", "lib/")
      end

      assert_raise ArgumentError, ~r/list of strings/, fn ->
        (&Paths.in_scope?/2).("lib/a.ex", [:lib])
      end

      assert_raise ArgumentError, ~r/list of strings/, fn ->
        (&Paths.matches_any?/2).("a", "a")
      end
    end

    test "Settings validators" do
      assert Settings.integer!(3, :n, 1) == 3

      assert_raise ArgumentError, ~r/:n must be an integer >= 1/, fn ->
        (&Settings.integer!/3).("3", :n, 1)
      end

      assert_raise ArgumentError, fn -> Settings.integer!(0, :n, 1) end
      assert_raise ArgumentError, ~r/list of atoms/, fn -> Settings.atoms!(["Foo"], :mods) end

      assert_raise ArgumentError, ~r/unknown keys \[:path\]/, fn ->
        Settings.known_keys!([calls: [], path: "x"], [:calls, :paths], "rule")
      end
    end
  end
end
