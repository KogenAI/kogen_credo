defmodule KogenCredo.Check.CoreReview.CredoDispatchTest do
  # Runs the checks through the real `Credo.run/1` pipeline (config file, file discovery,
  # all-files protocol, inline suppression). Not async: Credo prints to the shared console.
  use ExUnit.Case, async: false

  alias KogenCredo.Check.Refactor.DomainSize
  alias KogenCredo.Check.Refactor.DuplicateHelper
  alias KogenCredo.Check.Warning.BroadRescue
  alias KogenCredo.Check.Warning.DomainReach
  alias KogenCredo.Check.Warning.ForbiddenCall
  alias KogenCredo.Check.Warning.NoCredoDisable

  @helper """
  defmodule M<%= n %> do
    defp sha(data) do
      data
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)
    end

    def run(x), do: sha(x)
  end
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "kogen_dispatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write!(dir, path, content) do
    full = Path.join(dir, path)

    full
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(full, content)
  end

  defp credo(dir, checks, files \\ ["lib/", "test/"]) do
    write!(
      dir,
      ".credo.exs",
      inspect(
        %{
          configs: [
            %{
              name: "default",
              files: %{included: files, excluded: []},
              checks: %{enabled: checks, disabled: []}
            }
          ]
        },
        limit: :infinity
      )
    )

    {:ok, sink} = StringIO.open("")
    original = Process.group_leader()
    Process.group_leader(self(), sink)

    exec =
      try do
        Credo.run([
          "--strict",
          "--working-dir",
          dir,
          "--config-file",
          Path.join(dir, ".credo.exs"),
          "--format",
          "json",
          "--mute-exit-status"
        ])
      after
        Process.group_leader(self(), original)
      end

    exec
    |> Credo.Execution.get_issues()
    |> Enum.sort_by(&{&1.filename, &1.line_no})
  end

  test "DuplicateHelper emits its cross-file issues, and honours inline disables", %{dir: dir} do
    for n <- 1..3, do: write!(dir, "lib/m#{n}.ex", String.replace(@helper, "<%= n %>", "#{n}"))

    issues = credo(dir, [{DuplicateHelper, []}])
    assert length(issues) == 3
    assert Enum.all?(issues, &(&1.check == DuplicateHelper))

    # An inline disable on the helper's line silences that file's issue only.
    first =
      dir
      |> Path.join("lib/m1.ex")
      |> File.read!()

    write!(
      dir,
      "lib/m1.ex",
      String.replace(first, "  defp sha", "  # credo:disable-for-next-line\n  defp sha")
    )

    assert length(credo(dir, [{DuplicateHelper, []}])) == 2
  end

  test "DuplicateHelper reports nothing below min_files", %{dir: dir} do
    for n <- 1..2, do: write!(dir, "lib/m#{n}.ex", String.replace(@helper, "<%= n %>", "#{n}"))
    assert [] == credo(dir, [{DuplicateHelper, []}])
  end

  test "DomainSize emits one issue for an oversized domain", %{dir: dir} do
    write!(dir, "lib/a/one.ex", String.duplicate("x = 1\n", 20))
    write!(dir, "lib/a/two.ex", String.duplicate("y = 1\n", 20))

    checks = [{DomainSize, [domains: [[name: "a", paths: ["lib/a"]]], max_lines: 30]}]
    assert [%{check: DomainSize}] = credo(dir, checks)

    assert [] ==
             credo(dir, [{DomainSize, [domains: [[name: "a", paths: ["lib/a"]]], max_lines: 50]}])
  end

  test "DomainReach and ForbiddenCall are silent unconfigured and report when configured", %{
    dir: dir
  } do
    write!(
      dir,
      "lib/my_app/accounts/user.ex",
      "defmodule MyApp.Accounts.User do\n  alias MyApp.Billing.Invoice\nend\n"
    )

    write!(
      dir,
      "test/a_test.exs",
      "defmodule ATest do\n  use ExUnit.Case, async: true\n  def f, do: System.put_env(\"A\", \"b\")\nend\n"
    )

    assert [] == credo(dir, [{DomainReach, []}, {ForbiddenCall, []}])

    checks = [
      {DomainReach,
       [
         domains: [
           [name: "accounts", namespace: MyApp.Accounts, paths: ["lib/my_app/accounts"]],
           [name: "billing", namespace: MyApp.Billing, paths: ["lib/my_app/billing"]]
         ]
       ]},
      {ForbiddenCall, [presets: [:async_safe_tests]]}
    ]

    assert [DomainReach, ForbiddenCall] ==
             dir
             |> credo(checks)
             |> Enum.map(& &1.check)
             |> Enum.sort()
  end

  test "NoCredoDisable is advisory: a file-wide disable silences it and every other check", %{
    dir: dir
  } do
    write!(dir, "lib/a.ex", """
    defmodule A do
      # credo:disable-for-next-line Credo.Check.Readability.Specs
      def f do
        risky()
      rescue
        _ -> :error
      end
    end
    """)

    checks = [{NoCredoDisable, []}, {BroadRescue, []}]

    assert [BroadRescue, NoCredoDisable] ==
             dir
             |> credo(checks)
             |> Enum.map(& &1.check)
             |> Enum.sort()

    original =
      dir
      |> Path.join("lib/a.ex")
      |> File.read!()

    write!(dir, "lib/a.ex", "# credo:disable-for-this-file\n" <> original)

    assert [] == credo(dir, checks)
  end

  test "a crashing configuration fails the run instead of passing silently", %{dir: dir} do
    write!(dir, "lib/a.ex", "defmodule A do\nend\n")
    bad = [{DomainSize, [domains: [[name: "a"]]]}]

    {pid, ref} = spawn_monitor(fn -> credo(dir, bad) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 20_000
    assert inspect(reason) =~ "DomainSize domain needs"
  end
end
