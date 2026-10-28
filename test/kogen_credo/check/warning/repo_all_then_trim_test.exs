defmodule KogenCredo.Check.Warning.RepoAllThenTrimTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.RepoAllThenTrim

  defp run(body, params \\ [], filename \\ "lib/demo/search.ex") do
    """
    defmodule Demo.Search do
      alias Demo.Repo
      import Ecto.Query

      def run(q, n) do
    #{body}
      end
    end
    """
    |> to_source_file(filename)
    |> run_check(RepoAllThenTrim, params)
  end

  describe "positives" do
    test "pipeline with uniq_by and take (the regression shape)" do
      """
      q |> Repo.all() |> Enum.uniq_by(& &1.query) |> Enum.take(n)
      """
      |> run()
      |> assert_issues(2)
    end

    test "chained pipeline with an intermediate Enum.map" do
      "q |> Repo.all() |> Enum.map(& &1.id) |> Enum.take(5)"
      |> run()
      |> assert_issue(fn issue -> assert issue.trigger == "Enum.take" end)
    end

    test "nested call form" do
      "Enum.take(Repo.all(q), n)"
      |> run()
      |> assert_issue()
    end

    test "slice, filter and at" do
      """
      rows = Repo.all(q)
      a = Enum.slice(rows, 0, 3)
      b = Enum.filter(rows, & &1.ok)
      c = rows |> Enum.at(0)
      {a, b, c}
      """
      |> run()
      |> assert_issues(3)
    end

    test "variable bound from Repo.all and trimmed later" do
      """
      rows = Repo.all(q)
      Enum.take(rows, n)
      """
      |> run()
      |> assert_issue()
    end

    test "variable bound from a derived pipeline" do
      """
      rows = q |> Repo.all() |> Enum.map(& &1.id)
      Enum.take(rows, n)
      """
      |> run()
      |> assert_issue()
    end

    test "resolves an aliased repo" do
      """
      defmodule Demo do
        alias MyApp.Repo, as: R
        def run(q), do: q |> R.all() |> Enum.take(3)
      end
      """
      |> to_source_file("lib/demo.ex")
      |> run_check(RepoAllThenTrim, repo_modules: ["MyApp.Repo"], repo_names: [])
      |> assert_issue()
    end

    test "grouped alias expands to the real repo" do
      """
      defmodule Demo do
        alias MyApp.{Repo, Other}
        def run(q), do: Repo.all(q) |> Enum.take(3)
      end
      """
      |> to_source_file("lib/demo.ex")
      |> run_check(RepoAllThenTrim)
      |> assert_issue()
    end
  end

  describe "negatives and lookalikes" do
    test "limit in SQL" do
      "q |> limit(^n) |> Repo.all()"
      |> run()
      |> refute_issues()
    end

    test "Enum.take on a plain list" do
      "Enum.take(q, n)"
      |> run()
      |> refute_issues()
    end

    test "Repo.all result only mapped" do
      "q |> Repo.all() |> Enum.map(& &1.id)"
      |> run()
      |> refute_issues()
    end

    test "take happens before Repo.all (on the input list)" do
      "q |> Enum.take(n) |> Repo.all()"
      |> run()
      |> refute_issues()
    end

    test "a module merely named like Repo-ish things is not a repo" do
      """
      defmodule Demo do
        def run(q), do: q |> Cache.all() |> Enum.take(3)
        def other(q), do: q |> Repository.all() |> Enum.take(3)
      end
      """
      |> to_source_file("lib/demo.ex")
      |> run_check(RepoAllThenTrim)
      |> refute_issues()
    end

    test "Repo.one then Enum.take on another list" do
      """
      x = Repo.one(q)
      Enum.take(list(x), n)
      """
      |> run()
      |> refute_issues()
    end

    test "variable from a non-Repo source" do
      """
      rows = other(q)
      Enum.take(rows, n)
      """
      |> run()
      |> refute_issues()
    end

    test "Stream.take over Repo.stream is not Enum trimming" do
      "q |> Repo.stream() |> Stream.take(3) |> Enum.to_list()"
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "trimmer_functions can narrow the set" do
      body = "q |> Repo.all() |> Enum.filter(& &1.ok)"

      body
      |> run(trimmer_functions: [:take])
      |> refute_issues()

      body
      |> run(trimmer_functions: [:filter])
      |> assert_issue()
    end

    test "trimmer_functions can be extended" do
      "q |> Repo.all() |> Enum.drop(2)"
      |> run()
      |> refute_issues()

      "q |> Repo.all() |> Enum.drop(2)"
      |> run(trimmer_functions: [:drop])
      |> assert_issue()
    end

    test "tests are excluded by default" do
      "Enum.take(Repo.all(q), n)"
      |> run([], "test/demo/search_test.exs")
      |> refute_issues()
    end

    test "included_paths restricts the scope" do
      body = "Enum.take(Repo.all(q), n)"

      body
      |> run([included_paths: ["lib/web/**"]], "lib/demo/search.ex")
      |> refute_issues()

      body
      |> run([included_paths: ["lib/demo/**"]], "lib/demo/search.ex")
      |> assert_issue()
    end

    test "custom repo_names" do
      body = "Enum.take(Store.all(q), n)"

      body
      |> run()
      |> refute_issues()

      body
      |> run(repo_names: ["Store"])
      |> assert_issue()
    end
  end
end
