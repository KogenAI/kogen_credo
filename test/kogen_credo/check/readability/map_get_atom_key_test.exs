defmodule KogenCredo.Check.Readability.MapGetAtomKeyTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Readability.MapGetAtomKey

  defp run(source, filename \\ "lib/app/a.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(MapGetAtomKey, params)
  end

  defp fun(body), do: "defmodule A do\n  def f(state, opts), do: #{body}\nend\n"

  describe "configuration and framework keyword lists" do
    test "variables bound from Application env are configuration, not internal maps" do
      """
      defmodule A do
        def f do
          s3 = Application.fetch_env!(:app, :s3)
          {s3[:bucket], Map.get(s3, :region), Keyword.get(s3, :key)}
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "a variable not bound from Application env is still reported" do
      assert [_] =
               run("""
               defmodule A do
                 def f(other) do
                   s3 = Application.fetch_env!(:app, :s3)
                   {s3[:bucket], other[:bucket]}
                 end
               end
               """)
    end

    test "binding in another function does not leak" do
      assert [_] =
               run("""
               defmodule A do
                 def f, do: (s3 = Application.get_env(:app, :s3); s3)
                 def g(s3), do: s3[:bucket]
               end
               """)
    end

    test "changeset.errors and conn.private are keyword/container lookups" do
      "{changeset.errors[:name], conn.private[:head_request]}"
      |> fun()
      |> run()
      |> refute_issues()
    end
  end

  describe "positives" do
    test "Map.get with an atom key" do
      [issue] = run(fun("Map.get(state, :name)"))
      assert issue.message =~ "Map.get(x, :name)"
    end

    test "Map.get with a default" do
      [issue] = run(fun("Map.get(state, :name, \"x\")"))
      assert issue.message =~ "default"
    end

    test "bracket access on a variable and on a field" do
      assert [_] = run(fun("state[:name]"))
      assert [_] = run(fun("state.inner[:name]"))
    end

    test "piped Map.get" do
      assert [_] = run(fun("state |> Map.get(:name)"))
    end
  end

  describe "negatives and lookalikes" do
    test "keyword-list style receivers are ignored" do
      "{Map.get(opts, :a), opts[:b], options[:c], socket.assigns[:d], params[:e]}"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "string keys, variable keys and booleans pass" do
      "{Map.get(state, \"a\"), Map.get(state, key), Map.get(state, true)}"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "Keyword.get and Access on calls" do
      "{Keyword.get(state, :a), compute()[:b], %{a: 1}[:c]}"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "required keys by pattern or dot access" do
      "{state.name, (fn %{name: n} -> n end).(state)}"
      |> fun()
      |> run()
      |> refute_issues()
    end

    test "a local Map module is not Elixir's" do
      "defmodule A do\n  alias MyApp.Map\n  def f(s), do: Map.get(s, :a)\nend\n"
      |> run()
      |> refute_issues()
    end
  end

  describe "params and scope" do
    test "flag_with_default false only reports the two-argument form" do
      assert [_] = run(fun("Map.get(state, :a)"), "lib/a.ex", flag_with_default: false)

      "Map.get(state, :a, 1)"
      |> fun()
      |> run("lib/a.ex", flag_with_default: false)
      |> refute_issues()
    end

    test "ignored_receivers is configurable" do
      "state[:a]"
      |> fun()
      |> run("lib/a.ex", ignored_receivers: [:state])
      |> refute_issues()
    end

    test "tests are skipped by default" do
      "Map.get(state, :a)"
      |> fun()
      |> run("test/a_test.exs")
      |> refute_issues()
    end
  end
end
