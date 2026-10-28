defmodule KogenCredo.Check.Warning.SharedResourceGroupE2ETest do
  # Runs the check through the real Credo pipeline, so the all-source-files protocol
  # (`run_on_all_source_files/3`) is exercised and not only the pure `analyze/2`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @check KogenCredo.Check.Warning.SharedResourceGroup

  setup do
    dir = Path.join(System.tmp_dir!(), "kogen_e2e_#{System.unique_integer([:positive])}")

    dir
    |> Path.join("test")
    |> File.mkdir_p!()

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp test_file(dir, name, opts, body) do
    [dir, "test", name]
    |> Path.join()
    |> File.write!("""
    defmodule #{Macro.camelize(Path.basename(name, ".exs"))} do
      use ExUnit.Case, #{opts}
      test "t" do
        #{body}
      end
    end
    """)
  end

  defp credo(dir, params \\ []) do
    config = Path.join(dir, ".credo.exs")

    File.write!(config, """
    %{configs: [%{name: "default", files: %{included: ["test/"], excluded: []}, strict: true,
      checks: %{enabled: [{#{inspect(@check)}, #{inspect(params)}}], disabled: []}}]}
    """)

    parent = self()

    capture_io(fn ->
      exec =
        Credo.run([
          "--working-dir",
          dir,
          "--config-file",
          config,
          "--checks",
          "SharedResourceGroup"
        ])

      send(parent, {:issues, Credo.Execution.get_issues(exec)})
    end)

    receive do
      {:issues, issues} -> issues
    after
      0 -> flunk("credo did not finish")
    end
  end

  @put "Application.put_env(:app, :mode, 1)"

  test "reports modules in different files that share a key", %{dir: dir} do
    test_file(dir, "a_test.exs", "async: true", @put)
    test_file(dir, "b_test.exs", "async: true", @put)

    issues = credo(dir)

    basenames =
      issues
      |> Enum.map(&Path.basename(&1.filename))
      |> Enum.sort()

    assert basenames == ["a_test.exs", "b_test.exs"]

    assert Enum.all?(issues, &(&1.check == @check and &1.message =~ "app.mode"))
  end

  test "a shared literal group silences it, and so does a single module", %{dir: dir} do
    test_file(dir, "a_test.exs", "async: true, group: :mode", @put)
    test_file(dir, "b_test.exs", "async: true, group: :mode", @put)
    assert credo(dir) == []
  end

  test "a lone module is quiet", %{dir: dir} do
    test_file(dir, "a_test.exs", "async: true", @put)
    assert credo(dir) == []
  end
end
