defmodule KogenCredo.Diff.GitEnvTest do
  # Mutates the process environment, so it must not run concurrently with other tests.
  use ExUnit.Case, async: false

  alias KogenCredo.Diff.CLI

  @git_env [{"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}, {"GIT_INDEX_FILE", nil}]

  @bounded "defmodule App.Q do\n  def list(n), do: from(p in Post, limit: ^n) |> Repo.all()\nend\n"
  @unbounded "defmodule App.Q do\n  def list(_n), do: from(p in Post) |> Repo.all()\nend\n"

  defp git(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: @git_env)
    String.trim(out)
  end

  defp repo!(name) do
    dir = Path.join(System.tmp_dir!(), "kogen_#{name}_#{System.unique_integer([:positive])}")

    dir
    |> Path.join("lib")
    |> File.mkdir_p!()

    git(dir, ["init", "-q", "-b", "main"])
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
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

  test "inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_CONFIG_PARAMETERS cannot redirect --repo" do
    repo = repo!("env_main")

    repo
    |> Path.join("lib/q.ex")
    |> File.write!(@bounded)

    commit(repo, "base")
    git(repo, ["tag", "base"])

    repo
    |> Path.join("lib/q.ex")
    |> File.write!(@unbounded)

    commit(repo, "head")

    other = repo!("env_other")

    other
    |> Path.join("lib/z.ex")
    |> File.write!("defmodule Z do\nend\n")

    commit(other, "unrelated")

    vars = %{
      "GIT_DIR" => Path.join(other, ".git"),
      "GIT_WORK_TREE" => other,
      "GIT_INDEX_FILE" => Path.join(other, ".git/index"),
      "GIT_CONFIG_PARAMETERS" => "'diff.relative=true'",
      "GIT_LITERAL_PATHSPECS" => "1"
    }

    old = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    System.put_env(vars)

    try do
      assert {out, 0} = CLI.run(["base..HEAD", "--repo", repo])
      assert out =~ "[query-lost-limit]"
    after
      for {k, v} <- old, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end
  end
end
