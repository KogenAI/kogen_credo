defmodule KogenCredo.Check.Warning.TestFsHygieneTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.TestFsHygiene

  defp run(source, filename \\ "test/app/a_test.exs", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(TestFsHygiene, params)
  end

  defp body(code),
    do: "defmodule ATest do\n  use ExUnit.Case\n  test \"t\" do\n    #{code}\n  end\nend\n"

  describe ":tmp_dir tags" do
    test "tag forms" do
      for tag <- [
            "@tag :tmp_dir",
            "@moduletag :tmp_dir",
            "@describetag :tmp_dir",
            "@tag [:tmp_dir, :slow]",
            "@tag tmp_dir: true",
            ~s|@tag tmp_dir: "suffix"|,
            "@tag [slow: true, tmp_dir: true]"
          ] do
        assert [issue] =
                 run(
                   "defmodule ATest do\n  use ExUnit.Case\n  #{tag}\n  test \"t\", do: :ok\nend\n"
                 ),
               tag

        assert issue.line_no == 3
        assert issue.message =~ "System.tmp_dir!"
      end
    end

    test "reports one issue per tag with its own line" do
      source = """
      defmodule ATest do
        @moduletag :tmp_dir
        @tag :tmp_dir
        test "t", do: :ok
      end
      """

      assert [%{line_no: 2}, %{line_no: 3}] = run(source)
    end

    test "false, nil, dynamic values, unrelated tags, strings and comments are ignored" do
      source = ~S'''
      defmodule ATest do
        @moduletag tmp_dir: false
        @tag tmp_dir: nil
        @tag tmp_dir: some_value
        @tag :slow
        @tag [:tmp_dir_like]
        @tag tmp: true
        # @tag :tmp_dir
        @doc "@tag :tmp_dir"
        def x, do: "@tag :tmp_dir"
        test "uses ctx", %{tmp_dir: dir}, do: dir
      end
      '''

      assert [] = run(source)
    end

    test "allow_tmp_dir_paths by prefix, suffix and glob" do
      source = "defmodule ATest do\n  @tag :tmp_dir\nend\n"
      file = "test/e2e/deep/a_test.exs"

      for pattern <- ["test/e2e", "deep/a_test.exs", "test/**/a_*.exs"] do
        assert [] = run(source, file, allow_tmp_dir_paths: [pattern]), pattern
      end

      assert [_] = run(source, file, allow_tmp_dir_paths: ["test/other"])
      assert [_] = run(source, file, allow_write_paths: ["test/e2e"])
    end
  end

  describe "File writes" do
    test "project-relative literal destinations" do
      for call <- [
            ~s|File.write("out.txt", "x")|,
            ~s|File.write!("./out.txt", "x")|,
            ~s|File.mkdir_p!("tmp/x")|,
            ~s|File.touch("a")|,
            ~s|File.rm_rf("tmp")|,
            ~s|File.rm("a")|,
            ~s|File.rmdir("a")|,
            ~s|File.chmod("a", 0o644)|,
            ~s|File.write("tmp/\#{name}.txt", "x")|,
            ~s|File.write(Path.join("tmp", "a.txt"), "x")|,
            ~s|File.write(Path.join(["tmp", "a.txt"]), "x")|,
            ~s|File.write(Path.expand("a.txt"), "x")|,
            ~s|File.open("a", [:write])|,
            ~s|File.open!("a", [:read, :append])|,
            ~s|File.open("a", [:write], fn f -> f end)|,
            ~s|File.stream!("a", [:write])|
          ] do
        assert [issue] = run(body(call)), call
        assert issue.line_no == 4
        assert issue.message =~ "project-relative"
      end
    end

    test "destination argument of cp, cp_r, copy and rename" do
      assert [_] = run(body(~s|File.cp("/etc/hosts", "copy")|))
      assert [_] = run(body(~s|File.cp_r(src, "copy")|))
      assert [_] = run(body(~s|File.copy(src, "copy")|))
      assert [_] = run(body(~s|File.rename(src, "moved")|))
      assert [_] = run(body(~s|File.ln_s(src, "link")|))
      assert [] = run(body(~s|File.cp("fixtures/a", "/tmp/copy")|))
      assert [] = run(body(~s|File.cp_r("fixtures", Path.join(tmp, "x"))|))
      assert [] = run(body(~s|File.rename("a", dest)|))
    end

    test "cwd-based destinations" do
      for call <- [
            ~s|File.write(Path.join(File.cwd!(), "a"), "x")|,
            ~s|File.write("\#{File.cwd!()}/a", "x")|,
            ~s|File.write(Path.expand("a", File.cwd!()), "x")|,
            ~s{File.cwd!() |> Path.join("a") |> File.write("x")},
            ~s|root = File.cwd!()\n    File.write(Path.join(root, "a"), "x")|,
            ~s|root = File.cwd!()\n    path = Path.join(root, "a")\n    File.write(path, "x")|,
            ~s{root = File.cwd!()\n    root |> Path.join("a") |> File.mkdir_p()}
          ] do
        assert [issue] = run(body(call)), call
        assert issue.message =~ "File.cwd!"
      end
    end

    test "piped calls use the real destination" do
      assert [%{line_no: 4}] = run(body(~s{"out.txt" |> File.write("x")}))
      assert [%{line_no: 4}] = run(body(~s{"x" |> File.cp("dest")}))
      assert [] = run(body(~s{"out.txt" |> File.cp("/tmp/dest")}))
      assert [] = run(body(~s{System.tmp_dir!() |> Path.join("a") |> File.write("x")}))
    end

    test "module attribute bound to the cwd" do
      source = """
      defmodule ATest do
        @root File.cwd!()
        test "t", do: File.write(Path.join(@root, "a"), "x")
        test "u", do: File.write(Path.join(@other, "a"), "x")
      end
      """

      assert [%{line_no: 3}] = run(source)
    end

    test "valid destinations: absolute, tmp_dir, injected, dynamic" do
      for call <- [
            ~s|File.write("/tmp/x", "x")|,
            ~s|File.write("~/x", "x")|,
            ~s|File.write(Path.join(System.tmp_dir!(), "a"), "x")|,
            ~s|File.write(Path.join([System.tmp_dir!(), "a"]), "x")|,
            ~s|File.write(Path.expand("a", System.tmp_dir!()), "x")|,
            ~s|File.write(Path.expand("/abs/a", File.cwd!()), "x")|,
            ~s|File.write("\#{dir}/a", "x")|,
            ~s|File.write(path, "x")|,
            ~s|File.write(Path.join(tmp_dir, "a"), "x")|,
            ~s|File.mkdir_p!(make_path())|,
            ~s|root = File.cwd!()\n    root = System.tmp_dir!()\n    File.write(Path.join(root, "a"), "x")|
          ] do
        assert [] = run(body(call)), call
      end
    end

    test "reads and read-only opens are not writes" do
      for call <- [
            ~s|File.read!("a")|,
            ~s|File.open("a")|,
            ~s|File.open("a", [:read])|,
            ~s|File.open("a", fn f -> f end)|,
            ~s|File.open!("a", [:read], fn f -> f end)|,
            ~s|File.stream!("a")|,
            ~s|File.stream!("a", :line)|,
            ~s|File.exists?("a")|,
            ~s|File.ls!("a")|,
            ~s|File.cwd!()|,
            ~s|File.cp("a")|
          ] do
        assert [] = run(body(call)), call
      end
    end

    test "strings, comments and quoted code are not calls" do
      source = ~S'''
      defmodule ATest do
        # File.write("out.txt", "x")
        @doc "File.write(\"out.txt\", \"x\")"
        def x, do: "File.write(\"out.txt\", \"x\")"
      end
      '''

      assert [] = run(source)
    end
  end

  describe "aliases and lexical scope" do
    test "alias as: resolves to File" do
      source =
        "defmodule ATest do\n  alias File, as: F\n  def f, do: F.write(\"a\", \"x\")\nend\n"

      assert [%{line_no: 3}] = run(source)
    end

    test "unrelated aliased File modules are ignored" do
      source = """
      defmodule ATest do
        alias My.Other.File
        def f, do: File.write("a", "x")
      end
      """

      assert [] = run(source)

      renamed_source = """
      defmodule ATest do
        alias My.Store, as: File
        def f, do: File.write("a", "x")
      end
      """

      assert [] = run(renamed_source)
    end

    test "a nested defmodule File shadows File after its definition, Elixir.File does not" do
      source = """
      defmodule ATest do
        defmodule File do
          def write(_, _), do: :ok
        end

        def g, do: File.write("b", "x")
        def h, do: Elixir.File.write("c", "x")
      end
      """

      assert [%{line_no: 7}] = run(source)
    end

    test "alias in one function does not leak into the next" do
      source = """
      defmodule ATest do
        def f do
          alias My.Other.File
          File.write("a", "x")
        end

        def g, do: File.write("b", "x")
      end
      """

      assert [%{line_no: 7}] = run(source)
    end

    test "cwd variables do not leak between functions" do
      source = """
      defmodule ATest do
        def f do
          root = File.cwd!()
          File.write(Path.join(root, "a"), "x")
        end

        def g(root), do: File.write(Path.join(root, "a"), "x")
      end
      """

      assert [%{line_no: 4}] = run(source)
    end

    test "a local File.cwd! lookalike does not taint variables" do
      source = """
      defmodule ATest do
        alias My.Other.File
        def f do
          root = File.cwd!()
          Elixir.File.write(Path.join(root, "a"), "x")
        end
      end
      """

      assert [] = run(source)
    end

    test "Path alias to another module is not Path.join" do
      source =
        "defmodule ATest do\n  alias My.Path\n  def f, do: File.write(Path.join(\"a\", \"b\"), \"x\")\nend\n"

      assert [] = run(source)
    end
  end

  describe "params and scope" do
    test "only test files are scanned by default, test/support included" do
      source = body(~s|File.write("a", "x")|)
      assert [] = run(source, "lib/app/a.ex")
      assert [_] = run(source, "test/support/helper.ex")
      assert [_] = run(source, "apps/web/test/a_test.exs")
    end

    test "included_paths and excluded_paths" do
      source = body(~s|File.write("a", "x")|)
      assert [_] = run(source, "spec/a_test.exs", included_paths: ["spec/"])
      assert [] = run(source, "test/legacy/a_test.exs", excluded_paths: ["test/legacy"])
    end

    test "allow_write_paths exempts writes but not tags" do
      source = """
      defmodule ATest do
        @tag :tmp_dir
        test "t", do: File.write("a", "x")
      end
      """

      assert [%{line_no: 2}] = run(source, "test/e2e/a_test.exs", allow_write_paths: ["test/e2e"])

      assert [%{line_no: 3}] =
               run(source, "test/e2e/a_test.exs", allow_tmp_dir_paths: ["test/**/a_test.exs"])
    end

    test "invalid params raise" do
      source_file = to_source_file("defmodule A do\nend\n", "test/a_test.exs")

      assert_raise ArgumentError, ~r/allow_write_paths must be a list of strings/, fn ->
        TestFsHygiene.run(source_file, allow_write_paths: "test")
      end
    end

    test "issues are ordered by source line" do
      source = """
      defmodule ATest do
        @tag :tmp_dir
        test "a", do: File.write("a", "x")
        test "b", do: File.rm_rf("tmp")
      end
      """

      assert [%{line_no: 2}, %{line_no: 3}, %{line_no: 4}] = run(source)
    end
  end

  test "does not treat quoted test templates as executed filesystem operations" do
    source = ~S'''
    defmodule TemplateTest do
      def template do
        quote do
          @tag :tmp_dir
          File.write!("generated.txt", "example")
        end
      end
    end
    '''

    assert [] = run(source)
  end
end
