defmodule Mix.Tasks.Kogen.DiffCheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Kogen.DiffCheck

  @git_env [{"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}, {"GIT_INDEX_FILE", nil}]

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "an empty range works without relying on the package checkout's git metadata" do
    repo = Path.join(System.tmp_dir!(), "kogen_empty_range_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)
    git!(repo, ["init", "-q", "--initial-branch=main"])

    # Disposable fixture with a lib/ tree; an empty range over a repo that has the default path
    # is a legitimate success, unlike a repo where the path matches nothing.
    repo
    |> Path.join("lib")
    |> File.mkdir_p!()

    repo
    |> Path.join("lib/a.ex")
    |> File.write!("defmodule A do\nend\n")

    git!(repo, ["add", "-A"])

    git!(repo, [
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
      "fixture"
    ])

    out = capture_io(fn -> DiffCheck.run(["HEAD..HEAD", "--repo", repo]) end)
    assert out =~ "0 finding(s), 0 error(s)"
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true, env: @git_env)
    String.trim(out)
  end

  test "usage errors exit with 2 and print to stderr" do
    err =
      capture_io(:stderr, fn ->
        assert {:shutdown, 2} = catch_exit(DiffCheck.run(["--nope", "a..b"]))
      end)

    assert err =~ "invalid option"
  end

  test "an invalid range exits with 2" do
    capture_io(:stderr, fn ->
      assert {:shutdown, 2} = catch_exit(DiffCheck.run(["--output=/tmp/x..HEAD"]))
    end)
  end
end
