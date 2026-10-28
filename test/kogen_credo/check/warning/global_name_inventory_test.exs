defmodule KogenCredo.Check.Warning.GlobalNameInventoryTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.GlobalNameInventory

  defp run(source, params \\ [], file \\ "lib/sample.ex") do
    source
    |> to_source_file(file)
    |> run_check(GlobalNameInventory, params)
  end

  test "reports literal PubSub topics, including via attribute" do
    """
    defmodule Sample do
      @topic "drops"
      def a, do: Phoenix.PubSub.broadcast(MyApp.PubSub, "orders", :x)
      def b, do: Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
    end
    """
    |> run()
    |> assert_issues(fn issues ->
      assert Enum.any?(issues, &(&1.message =~ ~s("orders")))
      assert Enum.any?(issues, &(&1.message =~ ~s("drops")))
    end)
  end

  test "reports a topic attribute built from inspect(__MODULE__)" do
    """
    defmodule Sample do
      @topic inspect(__MODULE__)
      def a, do: Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
    end
    """
    |> run()
    |> assert_issue(fn issue -> assert issue.message =~ "inspect(__MODULE__)" end)
  end

  test "reports named ETS tables and persistent_term keys" do
    """
    defmodule Sample do
      def init do
        :ets.new(:cache, [:named_table, :public])
        :persistent_term.put(:flag, true)
      end
    end
    """
    |> run()
    |> assert_issues(fn issues -> assert length(issues) == 2 end)
  end

  test "reports registered process names and resolves aliases" do
    """
    defmodule Sample do
      alias MyApp.Server
      def a, do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
      def b, do: Agent.start_link(fn -> 1 end, name: Server)
      def c, do: GenServer.start_link(__MODULE__, [], name: {:global, :thing})
    end
    """
    |> run()
    |> assert_issues(fn issues ->
      assert length(issues) == 3
      assert Enum.any?(issues, &(&1.message =~ "MyApp.Server"))
    end)
  end

  test "lookalikes: injectable or dynamic names are quiet" do
    """
    defmodule Sample do
      def a(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
      def b(opts), do: GenServer.start_link(__MODULE__, opts)
      def c(id), do: Phoenix.PubSub.broadcast(MyApp.PubSub, "orders:\#{id}", :x)
      def d(topic), do: Phoenix.PubSub.broadcast(MyApp.PubSub, topic, :x)
      def e, do: :ets.new(:private, [:set])
      def f(name), do: :ets.new(name, [:named_table])
      def g, do: Other.broadcast(MyApp.PubSub, "orders", :x)
    end
    """
    |> run()
    |> refute_issues()
  end

  test "kinds and allowed_names params" do
    src = """
    defmodule Sample do
      def a, do: Phoenix.PubSub.broadcast(MyApp.PubSub, "orders", :x)
      def b, do: :ets.new(:cache, [:named_table])
    end
    """

    assert [issue] = run(src, kinds: [:ets])
    assert issue.message =~ ":cache"
    assert [issue] = run(src, allowed_names: [~s("orders")])
    assert issue.message =~ ":cache"
  end

  test "file scope: tests are not inventoried unless included" do
    src = "defmodule T do\n  def a, do: :ets.new(:cache, [:named_table])\nend\n"

    src
    |> run([], "test/t_test.exs")
    |> refute_issues()

    src
    |> run([included_files: ["test/**"]], "test/t_test.exs")
    |> assert_issue()
  end
end
