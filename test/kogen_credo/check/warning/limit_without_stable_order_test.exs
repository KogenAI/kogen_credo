defmodule KogenCredo.Check.Warning.LimitWithoutStableOrderTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.LimitWithoutStableOrder

  defp run(body, params \\ [], filename \\ "lib/demo/posts.ex") do
    """
    defmodule Demo.Posts do
      import Ecto.Query

      def list(n) do
    #{body}
      end
    end
    """
    |> to_source_file(filename)
    |> run_check(LimitWithoutStableOrder, params)
  end

  describe "positives" do
    test "from with limit and no order" do
      "from(p in Post, where: p.ok, limit: ^n)"
      |> run()
      |> assert_issue(fn issue -> assert issue.message =~ "without any order_by" end)
    end

    test "from with order on a non-unique field" do
      "from(p in Post, order_by: [desc: p.inserted_at], limit: 20)"
      |> run()
      |> assert_issue(fn issue -> assert issue.message =~ ":inserted_at" end)
    end

    test "pipeline: limit without order" do
      "Post |> where([p], p.ok) |> limit(^n) |> Repo.all()"
      |> run()
      |> assert_issue()
    end

    test "pipeline: order_by non-unique, listed with a binding" do
      "Post |> order_by([p], desc: p.inserted_at) |> limit(10)"
      |> run()
      |> assert_issue()
    end

    test "order_by after limit is still seen" do
      "Post |> limit(10) |> order_by([p], asc: p.name)"
      |> run()
      |> assert_issue()
    end

    test "atom and field/2 order forms" do
      "Post |> order_by(:inserted_at) |> limit(5)"
      |> run()
      |> assert_issue()

      "Post |> order_by([p], field(p, :name)) |> limit(5)"
      |> run()
      |> assert_issue()
    end

    test "fully qualified Ecto.Query.limit" do
      "Post |> Ecto.Query.limit(5)"
      |> run()
      |> assert_issue()
    end

    test "string table source" do
      ~s|from(r in "posts", limit: 5)|
      |> run()
      |> assert_issue()
    end
  end

  describe "negatives and lookalikes" do
    test "unique tiebreaker present (keyword and pipeline)" do
      "from(p in Post, order_by: [desc: p.inserted_at, desc: p.id], limit: 20)"
      |> run()
      |> refute_issues()

      "Post |> order_by([p], [desc: p.inserted_at, asc: p.id]) |> limit(5)"
      |> run()
      |> refute_issues()
    end

    test "limit 1 is ignored by default" do
      "from(p in Post, limit: 1)"
      |> run()
      |> refute_issues()

      "Post |> limit(1)"
      |> run()
      |> refute_issues()
    end

    test "variable base: ordering may be added elsewhere" do
      "query |> limit(5)"
      |> run()
      |> refute_issues()

      "from(p in query, limit: 5)"
      |> run()
      |> refute_issues()
    end

    test "dynamic order is not guessed" do
      "Post |> order_by(^order) |> limit(5)"
      |> run()
      |> refute_issues()

      "from(p in Post, order_by: ^order, limit: 5)"
      |> run()
      |> refute_issues()
    end

    test "no limit at all" do
      "from(p in Post, order_by: [desc: p.inserted_at])"
      |> run()
      |> refute_issues()
    end

    test "non-query limit/2 on a variable or option list" do
      "Keyword.put(opts, :limit, 5)"
      |> run()
      |> refute_issues()

      "Plug.Parsers.parse(conn, limit: 5)"
      |> run()
      |> refute_issues()
    end

    test "each chain is judged on its own" do
      """
      a = from(p in Post, order_by: p.id, limit: 5)
      b = from(p in Post, order_by: p.id)
      {a, b}
      """
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "unique_fields extends the tiebreaker set" do
      body = "from(p in Post, order_by: [desc: p.uuid], limit: 5)"

      body
      |> run()
      |> assert_issue()

      body
      |> run(unique_fields: [:id, "uuid"])
      |> refute_issues()
    end

    test "ignore_limit_one can be disabled" do
      "from(p in Post, limit: 1)"
      |> run(ignore_limit_one: false)
      |> assert_issue()
    end

    test "tests excluded by default; included_paths honoured" do
      body = "from(p in Post, limit: 5)"

      body
      |> run([], "test/posts_test.exs")
      |> refute_issues()

      body
      |> run(included_paths: ["lib/web/**"])
      |> refute_issues()

      body
      |> run(included_paths: ["lib/demo/**"])
      |> assert_issue()
    end
  end
end
