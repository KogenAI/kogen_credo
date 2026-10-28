defmodule KogenCredo.Check.Warning.PathExpandPrivTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.PathExpandPriv

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(PathExpandPriv, params)
  end

  defp fun(body), do: "defmodule A do\n  def f(x), do: #{body}\nend\n"

  describe "positives" do
    test "Path.expand and absname with a priv path" do
      [issue] = run(fun(~S|Path.expand("priv/repo/seeds.exs")|))
      assert issue.message =~ "Path.expand"
      assert [_] = run(fun(~S|Path.absname("priv/data")|))
    end

    test "leading ./priv and the bare directory" do
      assert [_] = run(fun(~S|Path.expand("./priv/x")|))
      assert [_] = run(fun(~S|Path.expand("priv")|))
    end

    test "interpolated priv path" do
      assert [_] = run(fun(~S|Path.expand("priv/#{x}.json")|))
    end

    test "Path.join starting with priv" do
      assert [_] = run(fun(~S|Path.join("priv", "x")|))
      assert [_] = run(fun(~S|Path.join(["priv", "x"])|))
    end

    test "piped Path.join" do
      assert [_] = run(fun(~S{"priv" |> Path.join("x")}))
    end

    test "File.read of a literal priv path" do
      assert [_] = run(fun(~S|File.read!("priv/data.json")|))
    end

    test "aliased Path" do
      source = "defmodule A do\n  alias Path, as: P\n  def f, do: P.expand(\"priv/x\")\nend\n"
      assert [_] = run(source)
    end
  end

  describe "negatives and lookalikes" do
    test "explicit base directory" do
      ~S|Path.expand("priv/x", Application.app_dir(:app))|
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "app_dir based paths" do
      ~S|Path.join(Application.app_dir(:app, "priv"), "x")|
      |> fun()
      |> run()
      |> refute_issues()

      ~S|File.read!(Application.app_dir(:app, "priv/x"))|
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "paths merely containing the word priv" do
      ~S|Path.expand("privileges/x")|
      |> fun()
      |> run()
      |> refute_issues()

      ~S|Path.join("assets/priv", "x")|
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "variable paths" do
      "Path.expand(x)"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "a local module named Path" do
      source = "defmodule A do\n  alias MyApp.Path\n  def f, do: Path.expand(\"priv/x\")\nend\n"

      source
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "check_file_calls false" do
      ~S|File.read!("priv/x")|
      |> fun()
      |> run("lib/a.ex", check_file_calls: false)
      |> refute_issues()
    end

    test "Mix tasks and tests are excluded by default" do
      ~S|Path.expand("priv/x")|
      |> fun()
      |> run("lib/mix/tasks/seed.ex")
      |> refute_issues()

      ~S|Path.expand("priv/x")|
      |> fun()
      |> run("test/a_test.exs")
      |> refute_issues()
    end

    test "config files are in scope by default" do
      assert [_] = run(fun(~S|Path.expand("priv/x")|), "config/runtime.exs")
    end
  end
end
