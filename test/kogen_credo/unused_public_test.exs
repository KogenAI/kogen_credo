defmodule KogenCredo.UnusedPublicTest do
  # Not async: `mix test` compiles with debug_info off, and the fixtures need it on,
  # which is a global compiler option.
  use ExUnit.Case, async: false

  alias KogenCredo.UnusedPublic

  setup_all do
    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    on_exit(fn -> Code.put_compiler_option(:debug_info, previous) end)
  end

  # Compiles synthetic modules in memory (unique names per test) and analyses them.
  defp analyze(source, opts \\ []) do
    {infos, skipped} =
      source
      |> compile()
      |> UnusedPublic.collect()

    assert skipped == []
    UnusedPublic.analyze(infos, opts)
  end

  defp compile(source) do
    # Compiler warnings from deliberately odd fixtures are noise here.
    {beams, _} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)

    for {module, _} <- beams do
      :code.purge(module)
      :code.delete(module)
    end

    beams
  end

  defp names(findings), do: Enum.map(findings, &{&1.name, &1.arity, &1.kind})

  test "reports a public function nobody calls, and one only its own module calls" do
    findings =
      analyze("""
      defmodule UnusedPublicFixture.Plain do
        def used, do: :ok
        def orphan, do: :ok
        def local_only, do: :ok
        def entry, do: local_only()
      end

      defmodule UnusedPublicFixture.Caller do
        def run, do: UnusedPublicFixture.Plain.used()
      end
      """)

    assert {:orphan, 0, :no_callers} in names(findings)
    assert {:local_only, 0, :only_local} in names(findings)
    refute Enum.any?(findings, &(&1.name == :used))
    # `entry/0` and `run/0` are never called either.
    assert {:entry, 0, :no_callers} in names(findings)
  end

  test "remote captures, literal apply and MFA tuples count as callers" do
    findings =
      analyze("""
      defmodule UnusedPublicFixture.Target do
        def captured(_), do: :ok
        def applied(_a, _b), do: :ok
        def in_tuple(_), do: :ok
        def dead(_), do: :ok
      end

      defmodule UnusedPublicFixture.User do
        def run(list) do
          Enum.map(list, &UnusedPublicFixture.Target.captured/1)
          apply(UnusedPublicFixture.Target, :applied, [1, 2])
          {UnusedPublicFixture.Target, :in_tuple, [1]}
        end
      end
      """)

    target = Enum.filter(findings, &(&1.module == UnusedPublicFixture.Target))
    assert [{:dead, 1, :no_callers}] = names(target)
  end

  test "an MFA tuple or literal apply aimed at the own module is public dispatch" do
    findings =
      analyze("""
      defmodule UnusedPublicFixture.Server do
        use GenServer

        def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
        def dispatched(_), do: :ok
        def applied(_), do: :ok
        def private_candidate, do: :ok
        def entry, do: private_candidate()
        def run, do: apply(__MODULE__, :applied, [1])
        def spec, do: {__MODULE__, :dispatched, [1]}

        @impl true
        def init(arg), do: {:ok, arg}
      end
      """)

    kinds = Map.new(findings, &{{&1.name, &1.arity}, &1.kind})
    refute Map.has_key?(kinds, {:start_link, 1})
    refute Map.has_key?(kinds, {:dispatched, 1})
    refute Map.has_key?(kinds, {:applied, 1})
    assert kinds[{:private_candidate, 0}] == :only_local
  end

  test "behaviour callbacks and @impl functions are not reported" do
    findings =
      analyze("""
      defmodule UnusedPublicFixture.Impl do
        @behaviour GenServer
        @impl true
        def init(s), do: {:ok, s}
        def handle_call(_m, _f, s), do: {:reply, :ok, s}
        def extra, do: :ok
      end
      """)

    assert [{:extra, 0, :no_callers}] = names(findings)
  end

  test "default-argument heads are one function" do
    findings =
      analyze("""
      defmodule UnusedPublicFixture.Defaults do
        def with_default(a, b \\\\ 1), do: {a, b}
        def unused_default(a, b \\\\ 1), do: {a, b}
      end

      defmodule UnusedPublicFixture.DefaultsCaller do
        def run, do: UnusedPublicFixture.Defaults.with_default(1)
      end
      """)

    defaults = Enum.filter(findings, &(&1.module == UnusedPublicFixture.Defaults))
    assert [{:unused_default, 2, :no_callers}] = names(defaults)
  end

  test "macros, __functions__, child_spec and module_info are excluded" do
    findings =
      analyze("""
      defmodule UnusedPublicFixture.Skipped do
        defmacro m, do: :ok
        def __custom__, do: :ok
        def child_spec(_), do: %{}
      end
      """)

    assert findings == []
  end

  test "entrypoint and ignored modules, and entrypoint functions" do
    source = """
    defmodule UnusedPublicFixture.ThingController do
      def index, do: :ok
    end

    defmodule UnusedPublicFixture.Jobs do
      def perform, do: :ok
      def other, do: :ok
    end
    """

    assert [] = analyze(source, entrypoint_modules: [~r/Controller$/, "UnusedPublicFixture.Jobs"])

    with_entrypoint =
      analyze(source, entrypoint_functions: ["UnusedPublicFixture.Jobs.perform/0"])

    jobs_findings =
      with_entrypoint
      |> Enum.filter(&(&1.module == UnusedPublicFixture.Jobs))
      |> names()

    assert [{:other, 0, :no_callers}] = jobs_findings

    ignoring_jobs = analyze(source, ignore_modules: [~r/Jobs$/])
    assert Enum.all?(ignoring_jobs, &(&1.module != UnusedPublicFixture.Jobs))
  end

  test "an entrypoint function nothing mentions is ignored without minting atoms" do
    source = "defmodule UnusedPublicFixture.Solo do\n  def lonely, do: :ok\nend\n"
    unique = System.unique_integer([:positive])
    unknown = "Never.Mentioned#{unique}.missing/0"
    module_name = "Elixir.Never.Mentioned#{unique}"

    findings = analyze(source, entrypoint_functions: [unknown])

    assert [{:lonely, 0, :no_callers}] = names(findings)
    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
  end

  test "an invalid entrypoint function string raises" do
    assert_raise ArgumentError, ~r/Mod.fun\/arity/, fn ->
      analyze("defmodule UnusedPublicFixture.Empty do\nend\n", entrypoint_functions: ["nonsense"])
    end
  end

  test "beams without debug info are reported as skipped, not silently analysed" do
    {:ok, module, binary} = compile_without_debug_info()
    assert {[], [{^module, :no_debug_info}]} = UnusedPublic.collect([{module, binary}])
  end

  defp compile_without_debug_info do
    forms = [
      {:attribute, 1, :module, UnusedPublicFixture.NoDebug},
      {:attribute, 2, :export, [{:a, 0}]},
      {:function, 3, :a, 0, [{:clause, 3, [], [], [{:atom, 3, :ok}]}]}
    ]

    {:ok, module, binary} = :compile.forms(forms, [:no_debug_info, :return_errors])
    {:ok, module, binary}
  end

  test "format/1 renders location, function and a reason" do
    [line] =
      UnusedPublic.format([
        %{
          module: Foo.Bar,
          name: :baz,
          arity: 2,
          line: 7,
          file: "lib/foo/bar.ex",
          kind: :only_local
        }
      ])

    assert line =~ "lib/foo/bar.ex:7 Foo.Bar.baz/2"
    assert line =~ "defp"
  end
end
