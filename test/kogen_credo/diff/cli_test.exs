defmodule KogenCredo.Diff.CLITest do
  use ExUnit.Case, async: true

  alias KogenCredo.Diff.CLI
  alias KogenCredo.Diff.Finding
  alias KogenCredo.Diff.Git
  alias KogenCredo.Diff.Json

  @git_env [{"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}, {"GIT_INDEX_FILE", nil}]

  @bounded "defmodule App.Q do\n  def list(n), do: from(p in Post, limit: ^n) |> Repo.all()\nend\n"
  @unbounded "defmodule App.Q do\n  def list(_n), do: from(p in Post) |> Repo.all()\nend\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "kogen_diff_#{System.unique_integer([:positive])}")

    dir
    |> Path.join("lib")
    |> File.mkdir_p!()

    git(dir, ["init", "-q", "-b", "main"])
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, repo: dir}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: @git_env)
    String.trim(out)
  end

  defp write(dir, path, content) do
    full = Path.join(dir, path)

    full
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(full, content)
  end

  defp commit(dir, message) do
    git(dir, ["add", "-A"])

    git(dir, [
      "-c",
      "user.name=T",
      "-c",
      "user.email=t@example.com",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "-q",
      "-m",
      message
    ])
  end

  defp regress(repo) do
    write(repo, "lib/q.ex", @bounded)
    commit(repo, "base")
    git(repo, ["tag", "base"])
    write(repo, "lib/q.ex", @unbounded)
    commit(repo, "head")
  end

  test "two-dot range finds a regression; advisory does not fail by default", %{repo: repo} do
    regress(repo)
    assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo])
    assert out =~ "lib/q.ex:2 App.Q.list/1 [query-lost-limit] (advisory)"
    assert out =~ "1 finding(s), 0 error(s), 1 file(s) analysed"
  end

  test "--fail-on and --error-rules control the exit code", %{repo: repo} do
    regress(repo)
    assert {_, 1} = CLI.run(["base..HEAD", "--repo", repo, "--fail-on", "advisory"])
    assert {out, 1} = CLI.run(["base..HEAD", "--repo", repo, "--error-rules", "query-lost-limit"])
    assert out =~ "(error)"

    assert {_, 0} =
             CLI.run([
               "base..HEAD",
               "--repo",
               repo,
               "--error-rules",
               "query-lost-limit",
               "--fail-on",
               "none"
             ])
  end

  test "three-dot range uses the merge base", %{repo: repo} do
    write(repo, "lib/q.ex", @bounded)
    commit(repo, "base")
    git(repo, ["checkout", "-q", "-b", "feature"])
    write(repo, "lib/q.ex", @unbounded)
    commit(repo, "feature")
    git(repo, ["checkout", "-q", "main"])
    write(repo, "lib/other.ex", "defmodule Other do\nend\n")
    commit(repo, "main moves on")

    assert {out, 0} = CLI.run(["main...feature", "--repo", repo])
    assert out =~ "[query-lost-limit]"
    refute out =~ "other.ex"
    # two-dot sees main's own new file as a change too, but no regression on it
    assert {out2, 0} = CLI.run(["main..feature", "--repo", repo, "--rules", "query-lost-limit"])
    assert out2 =~ "[query-lost-limit]"
  end

  test "--path filters, --rules filters", %{repo: repo} do
    regress(repo)
    write(repo, "other/x.ex", "defmodule X do\nend\n")
    commit(repo, "other")
    assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo, "--path", "other/"])
    assert out =~ "0 finding(s)"
    assert {out, 2} = CLI.run(["base..HEAD", "--repo", repo, "--path", "nothing_here/"])
    assert out =~ "matches no file"
    assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo, "--rules", "widened-api"])
    assert out =~ "0 finding(s)"
  end

  test "deleted files are listed and not analysed", %{repo: repo} do
    write(repo, "lib/q.ex", @bounded)
    write(repo, "lib/gone.ex", "defmodule Gone do\nend\n")
    commit(repo, "base")
    git(repo, ["tag", "base"])

    repo
    |> Path.join("lib/gone.ex")
    |> File.rm!()

    commit(repo, "head")

    assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo])
    assert out =~ "lib/gone.ex: deleted, not analysed"
    assert out =~ "0 finding(s), 0 error(s), 0 file(s) analysed"
  end

  test "a renamed and edited file is compared with its old path", %{repo: repo} do
    filler = for i <- 1..30, into: "", do: "  def f#{i}, do: #{i}\n"
    bounded = String.replace(@bounded, "end\n", filler <> "end\n")
    write(repo, "lib/q.ex", bounded)
    commit(repo, "base")
    git(repo, ["tag", "base"])
    git(repo, ["mv", "lib/q.ex", "lib/moved.ex"])

    write(
      repo,
      "lib/moved.ex",
      String.replace(bounded, "from(p in Post, limit: ^n)", "from(p in Post)")
    )

    commit(repo, "rename with edit")

    assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo, "--rules", "query-lost-limit"])
    assert out =~ "lib/moved.ex:2 App.Q.list/1 [query-lost-limit]"
  end

  test "paths are relative to a --repo subdirectory; the default lib/ follows it", %{repo: repo} do
    write(repo, "app/lib/q.ex", @bounded)
    commit(repo, "base")
    git(repo, ["tag", "base"])
    write(repo, "app/lib/q.ex", @unbounded)
    commit(repo, "head")
    sub = Path.join(repo, "app")

    assert {out, 0} = CLI.run(["base..HEAD", "--repo", sub])
    assert out =~ "app/lib/q.ex:2 App.Q.list/1 [query-lost-limit]"
    assert out =~ "1 file(s) analysed"
    assert {gh, 0} = CLI.run(["base..HEAD", "--repo", sub, "--format", "github"])
    assert gh =~ "file=app/lib/q.ex"
    assert {out, 0} = CLI.run(["base..HEAD", "--repo", sub, "--path", "lib/q.ex"])
    assert out =~ "[query-lost-limit]"
    # at the top, the same file needs the explicit path
    assert {out, 2} = CLI.run(["base..HEAD", "--repo", repo])
    assert out =~ "matches no file"
    assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo, "--path", "app/lib/"])
    assert out =~ "[query-lost-limit]"
    # --repo lib has no lib/lib: an error, not a silent empty scan
    assert {out, 2} = CLI.run(["base..HEAD", "--repo", Path.join(sub, "lib")])
    assert out =~ "matches no file"
  end

  test "umbrella layouts need explicit paths; wrong paths are never a silent green",
       %{repo: repo} do
    for app <- ~w(a b), do: write(repo, "apps/#{app}/lib/q.ex", @bounded)
    commit(repo, "base")
    git(repo, ["tag", "base"])
    for app <- ~w(a b), do: write(repo, "apps/#{app}/lib/q.ex", @unbounded)
    commit(repo, "head")

    repo
    |> Path.join("lib")
    |> File.rm_rf!()

    assert {out, 2} = CLI.run(["base..HEAD", "--repo", repo])
    assert out =~ "matches no file" and out =~ "umbrella"
    assert {gh, 2} = CLI.run(["base..HEAD", "--repo", repo, "--format", "github"])
    assert gh =~ "matches no file"

    assert {out, 0} =
             CLI.run([
               "base..HEAD",
               "--repo",
               repo,
               "--path",
               "apps/a/lib/",
               "--path",
               "apps/b/lib/"
             ])

    assert out =~ "2 finding(s), 0 error(s), 2 file(s) analysed"

    assert {out, 2} =
             CLI.run([
               "base..HEAD",
               "--repo",
               repo,
               "--path",
               "apps/a/lib/",
               "--path",
               "apps/c/lib/"
             ])

    assert out =~ "apps/c/lib/"
  end

  test "an unchanged range of a repo with matching paths still exits 0", %{repo: repo} do
    regress(repo)
    assert {out, 0} = CLI.run(["HEAD..HEAD", "--repo", repo])
    assert out =~ "0 finding(s), 0 error(s), 0 file(s) analysed"
  end

  test "a path only present in the base (deleted dir) is accepted", %{repo: repo} do
    write(repo, "lib/q.ex", @bounded)
    write(repo, "old/z.ex", "defmodule Z do\nend\n")
    commit(repo, "base")
    git(repo, ["tag", "base"])

    repo
    |> Path.join("old")
    |> File.rm_rf!()

    commit(repo, "head")
    assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo, "--path", "old/"])
    assert out =~ "old/z.ex: deleted, not analysed"
  end

  test "a repository-local diff.relative=true does not break a subdirectory --repo",
       %{repo: repo} do
    write(repo, "app/lib/q.ex", @bounded)
    commit(repo, "base")
    git(repo, ["tag", "base"])
    write(repo, "app/lib/q.ex", @unbounded)
    commit(repo, "head")
    git(repo, ["config", "diff.relative", "true"])

    assert {out, 0} = CLI.run(["base..HEAD", "--repo", Path.join(repo, "app")])
    assert out =~ "app/lib/q.ex:2 App.Q.list/1 [query-lost-limit]"
    assert out =~ "0 error(s), 1 file(s) analysed"
  end

  test "invalid head source is an explicit error with exit 2", %{repo: repo} do
    write(repo, "lib/q.ex", @bounded)
    commit(repo, "base")
    git(repo, ["tag", "base"])
    write(repo, "lib/q.ex", "defmodule App.Q do\n  def list(\nend\n")
    commit(repo, "broken")
    assert {out, 2} = CLI.run(["base..HEAD", "--repo", repo])
    assert out =~ "lib/q.ex: ERROR invalid head source"
    assert {json, 2} = CLI.run(["base..HEAD", "--repo", repo, "--format", "json"])
    assert json =~ ~s("errors":[{"file":"lib/q.ex")
  end

  test "json and github formats", %{repo: repo} do
    regress(repo)
    assert {json, 0} = CLI.run(["base..HEAD", "--repo", repo, "--format", "json"])
    assert json =~ ~s("rule":"query-lost-limit")
    assert json =~ ~s("severity":"advisory")

    assert {gh, 0} = CLI.run(["base..HEAD", "--repo", repo, "--format", "github"])

    assert gh =~
             "::warning file=lib/q.ex,line=2,title=kogen.diff_check query-lost-limit::App.Q.list/1: "
  end

  test "git failures are explicit", %{repo: repo} do
    regress(repo)
    assert {out, 2} = CLI.run(["nosuchrev..HEAD", "--repo", repo])
    assert out =~ ~s(kogen.diff_check: revision "nosuchrev" is not a commit)
    assert {out, 2} = CLI.run(["base..HEAD", "--repo", Path.join(repo, "missing")])
    assert out =~ "not a directory"
    plain = Path.join(System.tmp_dir!(), "kogen_plain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    assert {out, 2} = CLI.run(["base..HEAD", "--repo", plain])
    assert out =~ "not a git repository"
  end

  describe "hostile repositories" do
    @tab_name "lib/a\tb.ex"
    @nl_name "lib/x\n::error::forged.ex"

    test "paths with tabs and newlines round-trip and cannot forge output lines", %{repo: repo} do
      for name <- [@tab_name, @nl_name], do: write(repo, name, @bounded)
      commit(repo, "base")
      git(repo, ["tag", "base"])
      for name <- [@tab_name, @nl_name], do: write(repo, name, @unbounded)
      commit(repo, "head")

      assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo, "--rules", "query-lost-limit"])
      assert out =~ "2 finding(s), 0 error(s), 2 file(s) analysed"
      refute out =~ "\t"

      for line <- String.split(out, "\n") do
        refute String.starts_with?(line, "::")
      end

      assert {gh, 0} = CLI.run(["base..HEAD", "--repo", repo, "--format", "github"])
      assert length(String.split(gh, "\n")) == 2
      assert gh =~ "x%0A%3A%3Aerror%3A%3Aforged.ex"

      assert {json, 0} = CLI.run(["base..HEAD", "--repo", repo, "--format", "json"])
      assert json =~ ~s("file":"lib/a\\tb.ex")
      assert json =~ ~s(x\\n::error::forged.ex)
    end

    test "an unparsable file with a hostile name is an error line that cannot forge a command",
         %{repo: repo} do
      write(repo, @nl_name, @bounded)
      commit(repo, "base")
      git(repo, ["tag", "base"])
      write(repo, @nl_name, "defmodule A do\n  def (\nend\n")
      commit(repo, "broken")

      assert {out, 2} = CLI.run(["base..HEAD", "--repo", repo])
      assert out =~ "ERROR invalid head source"

      for line <- String.split(out, "\n") do
        refute String.starts_with?(line, "::")
      end
    end

    test "an ambiguous ref (branch and tag with one name) does not corrupt git output",
         %{repo: repo} do
      regress(repo)
      git(repo, ["branch", "amb", "base"])
      git(repo, ["tag", "amb", "base"])

      assert {out, 0} = CLI.run(["amb..HEAD", "--repo", repo])
      assert out =~ "[query-lost-limit]"
    end

    test "renames across the .ex boundary are an add or a delete, never parsed as the other kind",
         %{repo: repo} do
      body = @bounded <> String.duplicate("# filler line to keep similarity high\n", 20)
      write(repo, "lib/to_txt.ex", body)
      write(repo, "lib/from_txt.txt", "this is { not elixir (\n" <> String.duplicate("# x\n", 20))
      commit(repo, "base")
      git(repo, ["tag", "base"])
      git(repo, ["mv", "lib/to_txt.ex", "lib/to_txt.txt"])
      git(repo, ["mv", "lib/from_txt.txt", "lib/from_txt.ex"])
      write(repo, "lib/from_txt.ex", "defmodule FromTxt do\n  def a, do: 1\nend\n")
      commit(repo, "head")

      assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo])
      assert out =~ "lib/to_txt.ex: deleted, not analysed"
      assert out =~ "0 error(s)"
    end

    test "only .ex files are analysed; .exs is ignored", %{repo: repo} do
      write(repo, "lib/s.exs", "defmodule S do\n  def a, do: 1\nend\n")
      commit(repo, "base")
      git(repo, ["tag", "base"])
      write(repo, "lib/s.exs", "defmodule S do\n  def (\nend\n")
      commit(repo, "head")

      assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo])
      assert out =~ "0 file(s) analysed"
    end

    test "a base that does not parse is an error even when the head is fine", %{repo: repo} do
      write(repo, "lib/q.ex", "defmodule App.Q do\n  def list(\nend\n")
      commit(repo, "base")
      git(repo, ["tag", "base"])
      write(repo, "lib/q.ex", @bounded)
      commit(repo, "head")

      assert {out, 2} = CLI.run(["base..HEAD", "--repo", repo])
      assert out =~ "invalid base source"
    end

    test "a revision that is a file name or looks like an option cannot be misread as a path",
         %{repo: repo} do
      regress(repo)
      write(repo, "lib/--output", "x")
      assert {out, 2} = CLI.run(["--output..HEAD", "--repo", repo])
      assert out =~ "kogen.diff_check:"
      assert {out, 2} = CLI.run(["lib/q.ex..HEAD", "--repo", repo])
      assert out =~ "is not a commit"
    end

    test "three-dot compares against the merge base, not the base tip", %{repo: repo} do
      write(repo, "lib/q.ex", @bounded)
      commit(repo, "root")
      git(repo, ["tag", "root"])
      git(repo, ["checkout", "-q", "-b", "feature"])
      write(repo, "lib/q.ex", @unbounded)
      commit(repo, "feature")
      git(repo, ["checkout", "-q", "main"])
      write(repo, "lib/other.ex", "defmodule Other do\n  def a, do: 1\nend\n")
      commit(repo, "main moved on")

      assert {out, 0} = CLI.run(["main...feature", "--repo", repo])
      assert out =~ "1 finding(s)"
      assert out =~ "lib/q.ex"
      refute out =~ "lib/other.ex"
    end
  end

  test "injection-looking input is rejected before git runs", %{repo: repo} do
    out_file = Path.join(repo, "injected")

    for range <- [
          "--output=#{out_file}",
          "--output=#{out_file}..HEAD",
          "main;rm -rf ..HEAD",
          "a b..c",
          "..HEAD",
          "base..",
          "a..b..c",
          "a....b",
          "$(touch x)..HEAD",
          "x\n..HEAD",
          "-h...HEAD"
        ] do
      assert {out, 2} = CLI.run([range, "--repo", repo])
      assert out =~ "kogen.diff_check:"
    end

    refute File.exists?(out_file)
    assert {_, 2} = CLI.run(["base..HEAD", "--repo", repo, "--path", "-x"])
    assert {_, 2} = CLI.run(["base..HEAD", "--repo", repo, "--path", "../etc"])
    assert {_, 2} = CLI.run(["base..HEAD", "--repo", repo, "--path", "/abs"])
    assert {_, 2} = CLI.run(["base..HEAD", "--repo", repo, "--path", ":(glob)x"])
  end

  test "usage errors" do
    assert {out, 2} = CLI.run(["--bogus", "a..b"])
    assert out =~ "invalid option"
    assert {out, 2} = CLI.run([])
    assert out =~ "exactly one RANGE"
    assert {_, 2} = CLI.run(["a..b", "--format", "xml"])
    assert {_, 2} = CLI.run(["a..b", "--rules", "nope"])

    for flag <- ["--rules", "--error-rules"], value <- ["", ",", ",,"] do
      assert {out, 2} = CLI.run(["a..b", flag, value])
      assert out =~ "#{flag} needs at least one rule id"
    end

    assert {_, 2} = CLI.run(["a..b", "--fail-on", "sometimes"])
    assert {_, 2} = CLI.run(["a..b", "--sensitive-field", "Bad Field"])
  end

  test "empty --rules/--error-rules are errors, omitted options keep every rule", %{repo: repo} do
    regress(repo)
    assert {out, 2} = CLI.run(["base..HEAD", "--repo", repo, "--rules", ""])
    assert out =~ "needs at least one rule id"
    assert {out, 2} = CLI.run(["base..HEAD", "--repo", repo, "--error-rules", ","])
    assert out =~ "needs at least one rule id"
    assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo])
    assert out =~ "[query-lost-limit]"
  end

  test "parse_range" do
    assert {:ok, {:two_dot, "a", "b"}} = Git.parse_range("a..b")
    assert {:ok, {:three_dot, "origin/main", "HEAD~1"}} = Git.parse_range("origin/main...HEAD~1")
    assert {:error, _} = Git.parse_range("single")
    assert {:error, _} = Git.parse_range(nil)
  end

  test "parse_name_status handles renames, copies and unknown statuses" do
    out = "M\0lib/a.ex\0R090\0lib/b.ex\0lib/c.ex\0D\0lib/d.ex\0A\0lib/e.ex\0"
    assert {:ok, [m, r, d, a]} = Git.parse_name_status(out)
    assert {m.status, r.status, d.status, a.status} == {:modified, :renamed, :deleted, :added}
    assert r.base_path == "lib/b.ex" and r.head_path == "lib/c.ex"
    assert {:error, _} = Git.parse_name_status("U\0lib/a.ex\0")
  end

  describe "GitHub escaping and JSON" do
    test "message escapes %, CR, LF; properties also escape : and ," do
      f = %Finding{
        rule: "r",
        file: "a,b:c.ex",
        line: 3,
        function: "M.f/0",
        message: "50%\r\nnext"
      }

      line = Finding.to_github(f)
      assert line =~ "file=a%2Cb%3Ac.ex,"
      assert line =~ "::M.f/0: 50%25%0D%0Anext"
      refute String.contains?(line, "\n")
      assert Finding.escape_message("a:b,c") == "a:b,c"
      assert Finding.to_github(%{f | severity: :error}) =~ "::error "
    end

    test "json escapes control characters and quotes" do
      assert Json.encode(%{"a" => "q\"\\\n\t\u0001", "b" => [1, nil, true]}) ==
               ~s({"a":"q\\"\\\\\\n\\t\\u0001","b":[1,null,true]})
    end
  end
end
