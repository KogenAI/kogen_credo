defmodule Mix.Tasks.Kogen.UnusedPublicTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kogen.UnusedPublic

  test "matcher/1 treats slashes as a regex and anything else as an exact name" do
    assert %Regex{} = regex = UnusedPublic.matcher("/Worker$/")
    assert Regex.match?(regex, "MyApp.EmailWorker")
    assert "MyApp.Jobs" = UnusedPublic.matcher("MyApp.Jobs")
    assert_raise ArgumentError, ~r/unterminated/, fn -> UnusedPublic.matcher("/Worker") end
  end

  test "analysis_options/1 builds options and leaves defaults when nothing is passed" do
    assert [] = UnusedPublic.analysis_options([])

    opts =
      UnusedPublic.analysis_options(
        entrypoint_module: "/Live$/",
        entrypoint_function: "A.b/1",
        ignore_module: "A"
      )

    assert [%Regex{}] = opts[:entrypoint_modules]
    assert ["A.b/1"] = opts[:entrypoint_functions]
    assert ["A"] = opts[:ignore_modules]
  end

  test "unknown options are an error, not ignored" do
    assert_raise Mix.Error, ~r/unexpected arguments/, fn -> UnusedPublic.run(["--bogus"]) end
    assert_raise Mix.Error, ~r/unexpected arguments/, fn -> UnusedPublic.run(["stray"]) end
  end

  test "an invalid format is an error" do
    assert_raise Mix.Error, ~r/invalid --format/, fn -> UnusedPublic.run(["--format", "xml"]) end
  end
end

defmodule Mix.Tasks.Kogen.UnusedPublicExitTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kogen.UnusedPublic

  test "without --fail the task is advisory whatever it finds" do
    assert UnusedPublic.exit_status([%{}], [], false) == 0
    assert UnusedPublic.exit_status([%{}], [{Foo, :no_debug_info}], false) == 0
  end

  test "--fail: findings give 1, a clean complete run 0" do
    assert UnusedPublic.exit_status([%{}], [], true) == 1
    assert UnusedPublic.exit_status([], [], true) == 0
  end

  test "--fail: skipped modules make the run incomplete (2), even when nothing was found" do
    assert UnusedPublic.exit_status([], [{Foo, :no_debug_info}], true) == 2
    assert UnusedPublic.exit_status([%{}], [{Foo, :no_debug_info}], true) == 2
  end
end

defmodule Mix.Tasks.Kogen.UnusedPublicCorruptBeamTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "corrupt beams remain advisory skips and fail with incomplete status", %{tmp_dir: dir} do
    mixfile = Path.join(dir, "mix.exs")

    File.write!(mixfile, """
    defmodule UnusedPublicCorruptFixture.MixProject do
      use Mix.Project
      def project, do: [app: :unused_public_corrupt_fixture, version: "0.0.0", deps: []]
    end
    """)

    script = Path.join(dir, "check.exs")

    File.write!(script, """
    Mix.start()
    Code.ensure_loaded!(KogenCredo.UnusedPublic)
    Code.ensure_loaded!(Mix.Tasks.Kogen.UnusedPublic)

    Mix.Project.in_project(:unused_public_corrupt_fixture, #{inspect(dir)}, fn _ ->
      Mix.Task.run("compile")
      path = Mix.Project.compile_path()
      File.mkdir_p!(path)
      File.write!(Path.join(path, "Elixir.Corrupt.beam"), "garbage")
      :ok = Mix.Tasks.Kogen.UnusedPublic.run([])

      status =
        try do
          Mix.Tasks.Kogen.UnusedPublic.run(["--fail"])
          :unexpected_success
        catch
          :exit, reason -> reason
        end

      unless status == {:shutdown, 2}, do: raise("incorrect incomplete-analysis status")
      IO.puts("INCOMPLETE_STATUS=2")
    end)
    """)

    args =
      :code.get_path()
      |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)
      |> Enum.concat([script])

    env =
      System.get_env()
      |> Map.drop(
        ~w(PATH HOME TMPDIR LANG ERL_FLAGS MIX_ARCHIVES MIX_HOME MIX_ENV MIX_BUILD_PATH)
      )
      |> Enum.map(fn {name, _} -> {name, nil} end)
      |> Enum.concat([{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", Path.join(dir, "_build")}])

    executable = System.find_executable("elixir")
    {output, status} = System.cmd(executable, args, cd: dir, env: env, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "Corrupt ("
    assert output =~ "skipped"
    assert output =~ "INCOMPLETE_STATUS=2"
  end
end
