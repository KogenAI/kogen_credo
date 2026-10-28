defmodule KogenCredo.Check.Warning.RepoInLoopTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.RepoInLoop

  defp run(source, params \\ [], filename \\ "lib/demo/posts.ex") do
    source
    |> to_source_file(filename)
    |> run_check(RepoInLoop, params)
  end

  defp wrap(body, extra \\ "") do
    """
    defmodule Demo.Posts do
      alias Demo.Repo

      def run(posts) do
    #{body}
      end

    #{extra}
    end
    """
  end

  describe "positives" do
    test "Enum.map with an anonymous function" do
      "Enum.map(posts, fn p -> Repo.get(User, p.user_id) end)"
      |> wrap()
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "Enum.map"
        assert issue.message =~ "N+1"
      end)
    end

    test "piped Enum.each with a write" do
      "posts |> Enum.each(fn p -> Repo.update(change(p)) end)"
      |> wrap()
      |> run()
      |> assert_issue()
    end

    test "Stream.map and Enum.flat_map and reduce" do
      """
      a = Stream.map(posts, fn p -> Repo.one(q(p)) end)
      b = Enum.flat_map(posts, fn p -> Repo.all(q(p)) end)
      c = Enum.reduce(posts, [], fn p, acc -> [Repo.get(U, p.id) | acc] end)
      {a, b, c}
      """
      |> wrap()
      |> run()
      |> assert_issues(3)
    end

    test "for comprehension body, filter and later generator" do
      """
      a = for p <- posts, do: Repo.get(User, p.user_id)
      b = for p <- posts, Repo.exists?(q(p)), do: p
      c = for p <- posts, u <- Repo.all(q(p)), do: {p, u}
      {a, b, c}
      """
      |> wrap()
      |> run()
      |> assert_issues(3)
    end

    test "capture with Repo call and Repo function capture" do
      """
      a = Enum.map(posts, &Repo.get(User, &1.user_id))
      b = Enum.map(ids, &Repo.get!/1)
      {a, b}
      """
      |> wrap()
      |> run()
      |> assert_issues(2)
    end

    test "local helper capture reaches Repo, including two hops" do
      "Enum.map(posts, &load/1)"
      |> wrap("""
        defp load(p), do: fetch(p)
        defp fetch(p), do: Repo.get(User, p.id)
      """)
      |> run()
      |> assert_issue(fn issue -> assert issue.message =~ "load" end)
    end

    test "__MODULE__ and own-module remote captures" do
      """
      a = Enum.map(posts, &__MODULE__.load/1)
      b = Enum.map(posts, &Demo.Posts.load/1)
      {a, b}
      """
      |> wrap("  def load(p), do: Repo.get(User, p.id)")
      |> run()
      |> assert_issues(2)
    end

    test "local helper called inside an fn" do
      "Enum.map(posts, fn p -> load(p) end)"
      |> wrap("  defp load(p), do: Repo.one(q(p))")
      |> run()
      |> assert_issue()
    end

    test "aliased repo" do
      """
      defmodule Demo do
        alias Demo.Repo, as: R
        def run(xs), do: Enum.map(xs, fn x -> R.get(U, x) end)
      end
      """
      |> run()
      |> assert_issue()
    end

    test "nested loops are reported once" do
      """
      Enum.each(posts, fn p ->
        Enum.each(p.items, fn i -> Repo.update(i) end)
      end)
      """
      |> wrap()
      |> run()
      |> assert_issue()
    end
  end

  describe "negatives and lookalikes" do
    test "Repo call in the collection argument, not in the loop" do
      "Repo.all(q) |> Enum.map(& &1.id)"
      |> wrap()
      |> run()
      |> refute_issues()

      "Enum.map(Repo.all(q), fn x -> x.id end)"
      |> wrap()
      |> run()
      |> refute_issues()
    end

    test "first generator of a for is not the loop" do
      "for p <- Repo.all(q), do: p.id"
      |> wrap()
      |> run()
      |> refute_issues()
    end

    test "a helper that does no Repo work" do
      "Enum.map(posts, &title/1)"
      |> wrap("  defp title(p), do: p.title")
      |> run()
      |> refute_issues()
    end

    test "non-Repo receivers named get/all" do
      "Enum.map(posts, fn p -> Cache.get(p.id) end)"
      |> wrap()
      |> run()
      |> refute_issues()

      "Enum.map(posts, fn p -> Repository.get(p.id) end)"
      |> wrap()
      |> run()
      |> refute_issues()
    end

    test "Enum functions that are not loops by default" do
      "Enum.take_while(posts, fn p -> Repo.exists?(q(p)) end)"
      |> wrap()
      |> run()
      |> refute_issues()
    end

    test "helper chain deeper than max_depth is not followed" do
      extra = """
        defp a(p), do: b(p)
        defp b(p), do: c(p)
        defp c(p), do: d(p)
        defp d(p), do: e(p)
        defp e(p), do: Repo.get(U, p)
      """

      "Enum.map(posts, &a/1)"
      |> wrap(extra)
      |> run()
      |> refute_issues()

      "Enum.map(posts, &a/1)"
      |> wrap(extra)
      |> run(max_depth: 4)
      |> assert_issue()
    end

    test "recursive helpers terminate" do
      "Enum.map(posts, &a/1)"
      |> wrap("  defp a(p), do: a(p)")
      |> run()
      |> refute_issues()
    end

    test "same helper name with a different arity is not matched" do
      "Enum.map(posts, &load/1)"
      |> wrap("  defp load(p, _opts), do: Repo.get(U, p)")
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "loop_functions narrows and extends" do
      body = "Enum.map(posts, fn p -> Repo.get(U, p) end)"

      body
      |> wrap()
      |> run(loop_functions: [:each])
      |> refute_issues()

      "Enum.zip_with(posts, posts, fn p, _ -> Repo.get(U, p) end)"
      |> wrap()
      |> run(loop_functions: [:zip_with])
      |> assert_issue()
    end

    test "repo_functions narrows to reads" do
      "Enum.each(posts, fn p -> Repo.update(p) end)"
      |> wrap()
      |> run(repo_functions: [:get])
      |> refute_issues()
    end

    test "tests excluded by default and included_paths honoured" do
      body = wrap("Enum.map(posts, fn p -> Repo.get(U, p) end)")

      body
      |> run([], "test/demo/posts_test.exs")
      |> refute_issues()

      body
      |> run(included_paths: ["lib/web/**"])
      |> refute_issues()

      body
      |> run(included_paths: ["lib/demo/**"])
      |> assert_issue()
    end

    test "custom repo module" do
      body = wrap("Enum.map(posts, fn p -> Store.get(U, p) end)")

      body
      |> run()
      |> refute_issues()

      body
      |> run(repo_names: ["Store"])
      |> assert_issue()
    end
  end
end

defmodule KogenCredo.Check.Warning.RepoInLoopScopeTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.RepoInLoop

  defp run(source) do
    source
    |> to_source_file("lib/a.ex")
    |> run_check(RepoInLoop)
  end

  test "a helper with the same name in another module of the file is not followed" do
    """
    defmodule A do
      def go(ids), do: Enum.map(ids, &fetch/1)
      defp fetch(id), do: id
    end

    defmodule B do
      def other(id), do: Repo.get(User, id)
      defp fetch(id), do: Repo.get(User, id)
    end
    """
    |> run()
    |> refute_issues()
  end

  test "a qualified call into a sibling module follows that module's helper" do
    """
    defmodule A do
      def go(ids), do: Enum.map(ids, &B.fetch/1)
    end

    defmodule B do
      def fetch(id), do: Repo.get(User, id)
    end
    """
    |> run()
    |> assert_issue(fn issue -> assert issue.message =~ "fetch" end)
  end

  test "a helper inside a nested module is resolved in that nested module" do
    """
    defmodule Outer do
      defmodule Inner do
        def go(ids), do: Enum.each(ids, &load/1)
        defp load(id), do: Repo.get(User, id)
      end

      def go(ids), do: Enum.each(ids, &load/1)
      defp load(id), do: id
    end
    """
    |> run()
    |> assert_issue(fn issue -> assert issue.line_no == 3 end)
  end

  test "a helper with a default argument is found by its lower arity" do
    """
    defmodule A do
      def go(ids), do: Enum.map(ids, fn id -> load(id) end)
      defp load(id, _opts \\\\ []), do: Repo.get(User, id)
    end
    """
    |> run()
    |> assert_issue()
  end

  test "a local function named like a repo helper in the module outside any loop is quiet" do
    """
    defmodule A do
      def go(id), do: load(id)
      defp load(id), do: Repo.get(User, id)
    end
    """
    |> run()
    |> refute_issues()
  end
end
