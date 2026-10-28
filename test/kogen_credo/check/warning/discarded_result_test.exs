defmodule KogenCredo.Check.Warning.DiscardedResultTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.DiscardedResult

  defp run(body, params \\ [], filename \\ "lib/demo/posts.ex") do
    """
    defmodule Demo.Posts do
      alias Demo.Repo

      def run(attrs, cs) do
    #{body}
      end
    end
    """
    |> to_source_file(filename)
    |> run_check(DiscardedResult, params)
  end

  describe "positives" do
    test "underscore assignment of a Repo write" do
      """
      _ = Repo.update(cs)
      :ok
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "Repo.update"
        assert issue.message =~ "assigned to `_`"
      end)
    end

    test "underscore-prefixed variable counts as discard" do
      """
      _ignored = Repo.insert(cs)
      :ok
      """
      |> run()
      |> assert_issue()
    end

    test "bare statement and piped statement" do
      """
      Repo.insert(cs)
      cs |> Repo.delete()
      :ok
      """
      |> run()
      |> assert_issues(2)
    end

    test "bare local create_* call" do
      """
      create_post(attrs)
      :ok
      """
      |> run()
      |> assert_issue(fn issue -> assert issue.trigger == "create_post" end)
    end

    test "remote Context.update_* call" do
      """
      Blog.update_post(post, attrs)
      :ok
      """
      |> run()
      |> assert_issue()
    end

    test "Enum.each over create_* in an fn" do
      "Enum.each(attrs, fn a -> create_post(a) end)"
      |> run()
      |> assert_issue()
    end

    test "Enum.each with Repo write as last expression of a block" do
      """
      Enum.each(attrs, fn a ->
        cs = change(a)
        Repo.insert(cs)
      end)
      """
      |> run()
      |> assert_issue()
    end

    test "Enum.each with `_ =` as last expression" do
      "Enum.each(attrs, fn a -> _ = Repo.insert(a) end)"
      |> run()
      |> assert_issue()
    end

    test "Enum.each with captures" do
      """
      Enum.each(attrs, &create_post/1)
      Enum.each(attrs, &Repo.insert/1)
      Enum.each(attrs, &Repo.insert(&1))
      """
      |> run()
      |> assert_issues(3)
    end

    test "aliased repo" do
      """
      defmodule Demo do
        alias Demo.Repo, as: R
        def run(cs) do
          R.update(cs)
          :ok
        end
      end
      """
      |> to_source_file("lib/demo.ex")
      |> run_check(DiscardedResult)
      |> assert_issue()
    end
  end

  describe "negatives and lookalikes" do
    test "result matched, returned or used" do
      """
      {:ok, post} = Repo.insert(cs)
      case Repo.update(cs) do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end
      """
      |> run()
      |> refute_issues()
    end

    test "last expression of a function is returned" do
      """
      :ok
      Repo.insert(cs)
      """
      |> run()
      |> refute_issues()
    end

    test "bang variants raise, so they are not flagged" do
      """
      Repo.insert!(cs)
      create_post!(attrs)
      :ok
      """
      |> run()
      |> refute_issues()
    end

    test "Enum.each that matches the result" do
      "Enum.each(attrs, fn a -> {:ok, _} = create_post(a) end)"
      |> run()
      |> refute_issues()
    end

    test "Enum.each over a non-fallible function" do
      "Enum.each(attrs, fn a -> IO.puts(a) end)"
      |> run()
      |> refute_issues()

      "Enum.each(attrs, &IO.puts/1)"
      |> run()
      |> refute_issues()
    end

    test "Kernel/Ecto.Changeset/Map names that look like update_* are ignored" do
      """
      update_in(data, [:a], & &1)
      Ecto.Changeset.update_change(cs, :a, & &1)
      Map.update(m, :a, 1, & &1)
      :ok
      """
      |> run()
      |> refute_issues()
    end

    test "non-Repo receivers with insert/update" do
      """
      Cache.insert(cs)
      Multi.insert(multi, :a, cs)
      :ok
      """
      |> run()
      |> refute_issues()
    end

    test "Repo.insert_all and update_all are not result tuples" do
      """
      Repo.insert_all(Post, rows)
      Repo.update_all(Post, set: [a: 1])
      :ok
      """
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "fallible_name_patterns can be changed" do
      body = """
      send_email(user)
      :ok
      """

      body
      |> run()
      |> refute_issues()

      body
      |> run(fallible_name_patterns: ["send_*"])
      |> assert_issue()
    end

    test "Plug helpers matching the name patterns do not return a result tuple" do
      body = """
      delete_csrf_token()
      conn = delete_session(conn, :user)
      Plug.Conn.delete_resp_cookie(conn, "remember")
      :ok
      """

      body
      |> run()
      |> refute_issues()
    end

    test "a bare local delete_ call outside the Plug set is still reported" do
      "delete_comment(id)\n:ok"
      |> run()
      |> assert_issue()
    end

    test "ignored_names exempts a helper" do
      body = """
      update_cache(key)
      :ok
      """

      body
      |> run()
      |> assert_issue()

      body
      |> run(ignored_names: ["update_cache"])
      |> refute_issues()
    end

    test "flag toggles" do
      body = """
      _ = Repo.update(cs)
      Repo.insert(cs)
      :ok
      """

      body
      |> run(flag_underscore_assignment: false)
      |> assert_issue()

      body
      |> run(flag_bare_statement: false)
      |> assert_issue()
    end

    test "repo_functions narrows" do
      "Repo.insert(cs)\n:ok"
      |> run(repo_functions: [:update])
      |> refute_issues()
    end

    test "tests excluded by default; included_paths honoured" do
      body = "Repo.insert(cs)\n:ok"

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

  test "default and configured ignored module names still suppress discarded-result advice" do
    """
    Map.update_existing(attrs, :a, & &1)
    Keyword.delete_first([], :a)
    :ok
    """
    |> run()
    |> refute_issues()

    source = """
    alias MyApp.Users, as: U
    U.update_user(attrs)
    :ok
    """

    source
    |> run(ignored_modules: [:Users])
    |> refute_issues()

    source
    |> run(ignored_modules: [])
    |> assert_issue()
  end
end
