defmodule KogenCredo.Diff.PairingTest do
  use ExUnit.Case, async: true

  alias KogenCredo.Diff
  alias KogenCredo.Diff.Rules.QueryLostLimit
  alias KogenCredo.Diff.Rules.WidenedApi

  defp changes!(base, head) do
    {:ok, changes} = Diff.changes("lib/x.ex", base, head)
    changes
  end

  defp lost_limit(base, head) do
    changes = changes!(base, head)
    Diff.check(changes, [QueryLostLimit])
  end

  describe "base/head pairing" do
    test "pairs a single added parameter with the vanished arity" do
      base = "defmodule A do\n  def f(a), do: a\nend\n"
      head = "defmodule A do\n  def f(a, b), do: {a, b}\nend\n"

      assert [%{name: :f, arity: 2, base_arity: 1, base: [_]}] = changes!(base, head)
    end

    test "does not guess when several new arities could replace one base function" do
      base = "defmodule A do\n  def f(a), do: a\nend\n"
      head = "defmodule A do\n  def f(a, b), do: {a, b}\n  def f(a, b, c), do: {a, b, c}\nend\n"

      changes = changes!(base, head)

      arities =
        changes
        |> Enum.map(& &1.arity)
        |> Enum.sort()

      assert arities == [2, 3]
      assert Enum.all?(changes, &(&1.base == nil and &1.base_arity == nil))
    end

    test "does not pair when two base arities vanished" do
      base = "defmodule A do\n  def f(a), do: a\n  def f(a, b), do: {a, b}\nend\n"
      head = "defmodule A do\n  def f(a, b, c), do: {a, b, c}\nend\n"

      assert [%{arity: 3, base: nil}] = changes!(base, head)
    end

    test "never pairs across modules, including nested ones" do
      base = """
      defmodule A do
        def f(x), do: x
        defmodule B do
          def f(x), do: x
        end
      end
      """

      head = String.replace(base, "def f(x), do: x\n  end", "def f(x), do: [x]\n  end")

      assert [%{module: "A.B", name: :f, arity: 1, base: [_]}] = changes!(base, head)
    end

    test "a function moved to another module is new there, not a change of the old one" do
      base = "defmodule A do\n  def f(x), do: x\nend\ndefmodule B do\n  def g, do: 1\nend\n"
      head = "defmodule A do\n  def g, do: 1\nend\ndefmodule B do\n  def f(x), do: x\nend\n"

      changes = changes!(base, head)
      assert Enum.all?(changes, &(&1.base == nil))
    end

    test "__MODULE__.Child nests under the enclosing module" do
      base = "defmodule A do\n  defmodule __MODULE__.C do\n    def f(x), do: x\n  end\nend\n"
      head = String.replace(base, "do: x", "do: [x]")

      assert [%{module: "A.C"}] = changes!(base, head)
    end

    test "unquote heads are not indexed as a function named unquote" do
      head = "defmodule A do\n  def unquote(name)(x), do: x\n  def unquote(:z), do: 1\nend\n"
      assert [] = changes!(nil, head)
    end

    test "a visibility change alone is a change and widened-api sees it" do
      base = "defmodule A do\n  def keep, do: 1\n  defp f(x), do: x\nend\n"
      head = String.replace(base, "defp f", "def f")

      changes = changes!(base, head)
      assert [%{name: :f, base_kind: :defp, head_kind: :def}] = changes
      assert [%{rule: "widened-api"}] = Diff.check(changes, [WidenedApi])
    end

    test "formatting-only edits are still invisible" do
      base = "defmodule A do\n  def f(x), do: x+1\nend\n"
      head = "defmodule A do\n  def f(x) do\n    x + 1\n  end\nend\n"
      assert [] = changes!(base, head)
    end
  end

  describe "invalid sources are errors, never an empty success" do
    test "head" do
      assert {:error, {:invalid_source, :head, msg}} =
               Diff.changes(
                 "lib/x.ex",
                 "defmodule A do\nend\n",
                 "defmodule A do\n  def f(\nend\n"
               )

      assert msg =~ "line"
    end

    test "base" do
      assert {:error, {:invalid_source, :base, _}} =
               Diff.changes("lib/x.ex", "defmodule A do\n  def f(\n", "defmodule A do\nend\n")
    end

    test "invalid UTF-8" do
      assert {:error, {:invalid_source, :head, _}} =
               Diff.changes("lib/x.ex", nil, "defmodule A do\n  @x \"\xFF\"\nend\n")
    end

    test "check_sources propagates the error" do
      assert {:error, {:invalid_source, :head, _}} = Diff.check_sources("lib/x.ex", nil, "def (")
    end
  end

  describe "helper reach is arity aware" do
    @base """
    defmodule A do
      def list(q), do: list(q, 10)
      def list(q, n), do: q |> limit(^n) |> Repo.all()
    end
    """

    test "a lower-arity head that delegated to its bounded sibling and now bypasses it" do
      head = """
      defmodule A do
        def list(q), do: Repo.all(from(p in q))
        def list(q, n), do: q |> limit(^n) |> Repo.all()
      end
      """

      assert [%{name: :list, arity: 1} = change] = changes!(@base, head)
      assert [%{rule: "query-lost-limit"}] = Diff.check([change], [QueryLostLimit])
    end

    test "a bound moved into a piped helper is quiet" do
      base = "defmodule A do\n  def f(q), do: q |> limit(5) |> Repo.all()\nend\n"

      head =
        "defmodule A do\n  def f(q), do: q |> bounded() |> Repo.all()\n  defp bounded(q), do: limit(q, 5)\nend\n"

      assert [] = lost_limit(base, head)
    end

    test "a bound moved into a captured helper is quiet" do
      base =
        "defmodule A do\n  def f(qs), do: Enum.map(qs, &(&1 |> limit(5) |> Repo.all()))\nend\n"

      head =
        "defmodule A do\n  def f(qs), do: Enum.map(qs, &run/1)\n  defp run(q), do: q |> limit(5) |> Repo.all()\nend\n"

      assert [] = lost_limit(base, head)
    end

    test "an unrelated function of the same name and another arity is not followed" do
      base =
        "defmodule A do\n  def f(q), do: q |> limit(5) |> Repo.all()\n  defp helper(a, b, c), do: limit(a, b + c)\nend\n"

      head =
        "defmodule A do\n  def f(q), do: helper(q) |> Repo.all()\n  defp helper(a, b, c), do: limit(a, b + c)\nend\n"

      assert [%{rule: "query-lost-limit"}] = lost_limit(base, head)
    end

    test "a function merely named paginate_* is not itself a bound" do
      base = "defmodule A do\n  def paginate_users(q), do: Repo.all(q)\nend\n"
      head = "defmodule A do\n  def paginate_users(q), do: Repo.all(from(u in q))\nend\n"

      assert [] = lost_limit(base, head)
    end
  end
end
