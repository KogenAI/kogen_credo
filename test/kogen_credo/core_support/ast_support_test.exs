defmodule KogenCredo.CoreSupport.AstSupportTest do
  use ExUnit.Case, async: true

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Modules
  alias KogenCredo.CoreSupport.Tests

  defp ast(source), do: Code.string_to_quoted!(source)

  defp resolve(source, aliases) do
    source
    |> ast()
    |> Aliases.resolve(aliases)
  end

  describe "Ast" do
    test "expand_pipes rewrites local and remote pipe targets" do
      expanded =
        "a |> f(b) |> M.g(c)"
        |> ast()
        |> Ast.expand_pipes()
        |> Macro.to_string()

      assert expanded == "M.g(f(a, b), c)"
    end

    test "normalize ignores variable names and metadata but keeps calls" do
      a =
        "def f(x), do: x |> String.upcase()"
        |> ast()
        |> Ast.normalize()

      b =
        "def f(y),\n do: y |> String.upcase()"
        |> ast()
        |> Ast.normalize()

      c =
        "def f(y), do: y |> String.downcase()"
        |> ast()
        |> Ast.normalize()

      assert a == b
      refute a == c
    end

    test "def_clause parses guards and bodies" do
      clause =
        "defp f(x) when is_atom(x), do: x"
        |> ast()
        |> Ast.def_clause()

      assert {:ok, {:defp, :f, [_], guard, _, _}} = clause
      assert guard != nil

      not_a_def =
        "x = 1"
        |> ast()
        |> Ast.def_clause()

      assert not_a_def == :error
    end

    test "string_text joins literal parts of interpolations" do
      text =
        ~S|"a #{b} c"|
        |> ast()
        |> Ast.string_text()

      assert text =~ "a"
      assert Ast.string_text(:atom) == nil
    end

    test "prefixed? looks at the text of an atom" do
      assert Ast.prefixed?(:_ignored, "_")
      assert Ast.prefixed?(:__MODULE__, "__")
      refute Ast.prefixed?(:name, "_")
    end

    test "modules and strip_modules handle nesting" do
      tree = ast("defmodule A do\n  defmodule B do\n    def x, do: 1\n  end\n  def y, do: 2\nend")
      assert length(Ast.modules(tree)) == 2
      [{_, _, body} | _] = Ast.modules(tree)

      stripped =
        body
        |> Ast.strip_modules()
        |> Macro.to_string()

      refute stripped =~ "def x"
    end
  end

  describe "Aliases" do
    test "build handles plain, as: and multi-alias forms" do
      aliases =
        "alias A.B\nalias C.D, as: E\nalias F.{G, H.I}"
        |> ast()
        |> Aliases.build()

      assert aliases == %{B: "A.B", E: "C.D", G: "F.G", I: "F.H.I"}
    end

    test "resolve expands the first segment and passes Erlang modules" do
      aliases = %{S: "System"}
      assert resolve("S", aliases) == "System"
      assert resolve("S.Sub", aliases) == "System.Sub"
      assert resolve("File", aliases) == "File"
      assert Aliases.resolve(:timer, aliases) == ":timer"
      assert resolve("var", aliases) == nil
    end

    test "local_functions lists name and arity" do
      locals =
        "def a(x, y), do: 1\ndefp b, do: 2\ndef c(x) when x > 1, do: 3"
        |> ast()
        |> Aliases.local_functions()

      assert MapSet.equal?(locals, MapSet.new([{:a, 2}, {:b, 0}, {:c, 1}]))
    end
  end

  describe "Modules.prune/2" do
    test "empties skipped modules, including nested ones and children by prefix" do
      source = """
      defmodule MyApp do
        defmodule Codec do
          def a, do: "str"
        end

        defmodule Codec.Json do
          def b, do: "str"
        end

        def c, do: "keep"
      end
      """

      out =
        source
        |> ast()
        |> Modules.prune([MyApp.Codec])
        |> Macro.to_string()

      refute out =~ ~s("str")
      assert out =~ ~s("keep")
    end

    test "an empty skip list is the identity" do
      tree = ast("defmodule A do\n  def a, do: 1\nend")
      assert Modules.prune(tree, []) == tree
    end
  end

  describe "Tests" do
    test "test_blocks skips pending tests and returns bodies" do
      tree =
        ast(
          ~s|test "a" do\n  assert 1\nend\ntest "pending"\ntest "b", %{x: x} do\n  assert x\nend|
        )

      names =
        tree
        |> Tests.test_blocks()
        |> Enum.map(& &1.name)

      assert names == ["a", "b"]
    end

    test "assertion_name?" do
      assert Enum.all?(
               [:assert, :refute, :assert_receive, :refute_in_delta],
               &Tests.assertion_name?/1
             )

      refute Enum.any?([:asserted, :check, :assertion], &Tests.assertion_name?/1)
    end
  end
end
