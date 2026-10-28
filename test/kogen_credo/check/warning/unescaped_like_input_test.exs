defmodule KogenCredo.Check.Warning.UnescapedLikeInputTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.UnescapedLikeInput

  defp run(body, params \\ [], filename \\ "lib/demo/search.ex") do
    """
    defmodule Demo.Search do
      import Ecto.Query
      @prefix "tmp_"

      def search(q, term) do
    #{body}
      end
    end
    """
    |> to_source_file(filename)
    |> run_check(UnescapedLikeInput, params)
  end

  describe "positives" do
    test "ilike with an interpolated wildcard pattern" do
      ~S|where(q, [u], ilike(u.name, ^"%#{term}%"))|
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "ilike"
        assert issue.message =~ "escape"
      end)
    end

    test "like with prefix pattern inside from/2" do
      ~S|from(u in User, where: like(u.name, ^"#{term}%"))|
      |> run()
      |> assert_issue()
    end

    test "concatenated pattern" do
      ~S|where(q, [u], ilike(u.name, ^("%" <> term <> "%")))|
      |> run()
      |> assert_issue()
    end

    test "pattern bound to a variable earlier in the function" do
      ~S"""
      pattern = "%#{term}%"
      where(q, [u], ilike(u.name, ^pattern))
      """
      |> run()
      |> assert_issue()
    end

    test "variable bound through concatenation" do
      ~S"""
      pattern = "%" <> term
      where(q, [u], ilike(u.name, ^pattern))
      """
      |> run()
      |> assert_issue()
    end

    test "piped into where with ilike in a dynamic expression" do
      ~S"""
      q |> where([u], ilike(u.email, ^"%#{String.trim(term)}%"))
      """
      |> run()
      |> assert_issue()
    end

    test "fragment with ILIKE" do
      ~S|where(q, [u], fragment("? ILIKE ?", u.name, ^"%#{term}%"))|
      |> run()
      |> assert_issue(fn issue -> assert issue.trigger == "fragment" end)
    end

    test "an underscore wildcard counts too" do
      ~S|where(q, [u], like(u.code, ^"A_#{term}"))|
      |> run()
      |> assert_issue()
    end
  end

  describe "negatives and lookalikes" do
    test "escaped by a helper (local, remote and piped)" do
      ~S|where(q, [u], ilike(u.name, ^"%#{escape_like(term)}%"))|
      |> run()
      |> refute_issues()

      ~S|where(q, [u], ilike(u.name, ^"%#{Search.escape_like(term)}%"))|
      |> run()
      |> refute_issues()

      ~S'where(q, [u], ilike(u.name, ^"%#{term |> escape_like()}%"))'
      |> run()
      |> refute_issues()
    end

    test "escaped through a bound variable" do
      ~S"""
      safe = escape_like(term)
      pattern = "%#{safe}%"
      where(q, [u], ilike(u.name, ^pattern))
      """
      |> run()
      |> refute_issues()
    end

    test "inline String.replace escaping" do
      ~S"""
      where(q, [u], ilike(u.name, ^"%#{String.replace(term, "%", "\\%")}%"))
      """
      |> run()
      |> refute_issues()
    end

    test "constant patterns and module attributes" do
      ~S|where(q, [u], ilike(u.name, "%admin%"))|
      |> run()
      |> refute_issues()

      ~S|where(q, [u], ilike(u.name, ^"#{@prefix}%"))|
      |> run()
      |> refute_issues()
    end

    test "no author-written wildcard" do
      ~S|where(q, [u], ilike(u.name, ^"#{term}"))|
      |> run()
      |> refute_issues()

      ~S|where(q, [u], ilike(u.name, ^term))|
      |> run()
      |> refute_issues()
    end

    test "interpolation that is not a LIKE pattern" do
      ~S|where(q, [u], u.name == ^"%#{term}%")|
      |> run()
      |> refute_issues()

      ~S|where(q, [u], fragment("lower(?) = ?", u.name, ^"%#{term}%"))|
      |> run()
      |> refute_issues()
    end

    test "a function named like but with another arity or purpose" do
      ~S|Logger.info("like #{term}%")|
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "escape_functions can be extended" do
      body = ~S|where(q, [u], ilike(u.name, ^"%#{my_escape(term)}%"))|

      body
      |> run()
      |> assert_issue()

      body
      |> run(escape_functions: ["my_escape"])
      |> refute_issues()
    end

    test "like_functions can be extended" do
      body = ~S|where(q, [u], similar(u.name, ^"%#{term}%"))|

      body
      |> run()
      |> refute_issues()

      body
      |> run(like_functions: [:similar])
      |> assert_issue()
    end

    test "tests excluded by default; included_paths honoured" do
      body = ~S|where(q, [u], ilike(u.name, ^"%#{term}%"))|

      body
      |> run([], "test/search_test.exs")
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
