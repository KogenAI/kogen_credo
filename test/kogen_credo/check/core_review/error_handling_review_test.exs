defmodule KogenCredo.Check.CoreReview.ErrorHandlingTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Readability.ErrorReasonString
  alias KogenCredo.Check.Readability.MapGetAtomKey
  alias KogenCredo.Check.Warning.BroadRescue
  alias KogenCredo.Check.Warning.FailOpenWith
  alias KogenCredo.Check.Warning.StringKeyAccess
  alias KogenCredo.Check.Warning.StubBody

  defp run(check, source, params \\ [], filename \\ "lib/app/a.ex") do
    source
    |> to_source_file(filename)
    |> run_check(check, params)
  end

  # Credo runs checks in linked tasks, so a raise would take the caller down; call run/2 directly.
  defp run_direct(check, source, params, filename \\ "lib/app/a.ex") do
    source_file = to_source_file(source, filename)
    check.run(source_file, params)
  end

  describe "BroadRescue" do
    test ":erlang.raise and Kernel.reraise count as re-raises" do
      BroadRescue
      |> run("""
      defmodule A do
        def f do
          risky()
        catch
          kind, reason ->
            log(kind)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

        def g do
          risky()
        rescue
          e -> Kernel.reraise(e, __STACKTRACE__)
        end
      end
      """)
      |> refute_issues()
    end

    test "an unrelated :erlang call is not a re-raise" do
      assert [_] =
               run(BroadRescue, """
               defmodule A do
                 def f do
                   risky()
                 rescue
                   _ -> :erlang.phash2(1)
                 end
               end
               """)
    end

    test "aliases are lexical: an alias in another module does not make Exception narrow" do
      source = """
      defmodule A do
        alias MyApp.Exception

        def narrow do
          risky()
        rescue
          e in Exception -> {:error, e}
        end
      end

      defmodule B do
        def broad do
          risky()
        rescue
          e in Exception -> {:error, e}
        end
      end
      """

      assert [issue] = run(BroadRescue, source)
      assert issue.line_no == 15
    end

    test "rescue with a mix of narrow and broad modules is reported" do
      assert [_] =
               run(BroadRescue, """
               defmodule A do
                 def f do
                   x()
                 rescue
                   e in [File.Error, RuntimeError] -> {:error, e}
                 end
               end
               """)
    end

    test "catch with a literal kind, and one-argument catch, pass" do
      BroadRescue
      |> run("""
      defmodule A do
        def f do
          x()
        catch
          :exit, _ -> :stopped
          :throw, value -> value
          thrown -> thrown
        end
      end
      """)
      |> refute_issues()
    end

    test "multi-clause try reports every broad clause once, in line order" do
      issues =
        run(BroadRescue, """
        defmodule A do
          def f do
            try do
              x()
            rescue
              e in ArgumentError -> {:error, e}
              _ -> :a
            catch
              k, r -> {k, r}
            end
          end
        end
        """)

      assert Enum.map(issues, & &1.line_no) == [7, 9]
    end

    test "malformed broad_exceptions raises" do
      assert_raise ArgumentError, ~r/broad_exceptions must be a list of atoms/, fn ->
        run_direct(BroadRescue, "defmodule A do\nend", broad_exceptions: ["Exception"])
      end
    end

    test "paths: a string instead of a list raises" do
      assert_raise ArgumentError, ~r/list of strings/, fn ->
        run_direct(BroadRescue, "defmodule A do\nend", included_paths: "lib/")
      end
    end
  end

  describe "FailOpenWith" do
    test "case piped into case is inspected" do
      assert [_] =
               run(FailOpenWith, """
               defmodule A do
                 def f(x) do
                   x
                   |> fetch()
                   |> case do
                     {:ok, v} -> v
                     {:error, reason} -> nil
                   end
                 end
               end
               """)
    end

    test "a guarded {:error, reason} clause is still an error-to-default" do
      assert [_] =
               run(FailOpenWith, """
               defmodule A do
                 def f(x) do
                   case x do
                     {:error, reason} when is_atom(reason) -> []
                     {:ok, v} -> v
                   end
                 end
               end
               """)
    end

    test "a boolean predicate with `_ -> false` passes only when the do block ends in true" do
      FailOpenWith
      |> run("""
      defmodule A do
        def ok?(a) do
          with {:ok, _} <- parse(a) do
            true
          else
            _ -> false
          end
        end
      end
      """)
      |> refute_issues()

      assert [_] =
               run(FailOpenWith, """
               defmodule A do
                 def run(a) do
                   with {:ok, v} <- parse(a) do
                     v
                   else
                     _ -> false
                   end
                 end
               end
               """)
    end

    test "a catch-all with a guard is not a catch-all and a translating else passes" do
      FailOpenWith
      |> run("""
      defmodule A do
        def run(a) do
          with {:ok, v} <- parse(a) do
            v
          else
            {:error, :enoent} -> {:error, :missing}
            other when is_tuple(other) -> {:error, other}
            _ -> {:error, :unexpected}
          end
        end
      end
      """)
      |> refute_issues()
    end

    test "{:error, reason} -> {:ok, constant} inside with/else is reported with the line of the clause" do
      [issue] =
        run(FailOpenWith, """
        defmodule A do
          def run(a) do
            with {:ok, v} <- parse(a) do
              v
            else
              {:error, _reason} -> {:ok, []}
            end
          end
        end
        """)

      assert issue.line_no == 6
    end

    test "case on the error can be switched off" do
      source = "defmodule A do\n  def f(x), do: (case x do\n {:error, r} -> nil\n end)\nend"
      assert [_] = run(FailOpenWith, source)

      FailOpenWith
      |> run(source, flag_case: false)
      |> refute_issues()
    end
  end

  describe "StringKeyAccess" do
    test "piped Map.get and get_in with a string key are found" do
      issues =
        run(StringKeyAccess, """
        defmodule A do
          def f(m) do
            a = m |> Map.get("a")
            b = m |> get_in(["b", :c])
            c = Map.take(m, ["x", "y"])
            {a, b, c}
          end
        end
        """)

      assert Enum.map(issues, & &1.line_no) == [3, 4, 5]
    end

    test "aliased Map is resolved, a project Map module is not" do
      assert [_] = run(StringKeyAccess, "alias Map, as: M\nM.get(x, \"k\")")

      StringKeyAccess
      |> run("alias MyApp.Map\nMap.get(x, \"k\")")
      |> refute_issues()
    end

    test "nested module names follow Elixir: Foo.Foo.Codec is not Foo.Codec" do
      source = """
      defmodule Foo do
        defmodule Foo.Codec do
          def a(m), do: m["k"]
        end
      end
      """

      assert [_] = run(StringKeyAccess, source, codec_modules: [Foo.Codec])

      StringKeyAccess
      |> run(source, codec_modules: [Foo.Foo.Codec])
      |> refute_issues()
    end

    test "inner modules of a codec module are exempt, siblings are not" do
      source = """
      defmodule MyApp.Wire do
        defmodule Inner do
          def a(m), do: m["k"]
        end
      end

      defmodule MyApp.Core do
        def b(m), do: m["k"]
      end
      """

      assert [issue] = run(StringKeyAccess, source, codec_modules: [MyApp.Wire])
      assert issue.line_no == 8
    end

    test "codec_modules must be atoms" do
      assert_raise ArgumentError, ~r/codec_modules must be a list of atoms/, fn ->
        run_direct(StringKeyAccess, "x = 1", codec_modules: ["MyApp.Wire"])
      end
    end
  end

  describe "StubBody" do
    test "stub raises in every tail branch of case/cond/with/try are found, non-tail ones are not" do
      issues =
        run(StubBody, """
        defmodule A do
          def f(x) do
            case x do
              1 -> :ok
              _ -> raise "not implemented"
            end
          end

          def g(x) do
            cond do
              x -> {:error, :not_implemented}
              true -> :unimplemented
            end
          end

          def h(x) do
            _ = :not_implemented
            x
          end
        end
        """)

      assert Enum.map(issues, & &1.line_no) == [5, 11, 12]
    end

    test "NotImplementedError resolves through the alias in force" do
      source = """
      defmodule A do
        alias Mine.NotImplementedError
        def f, do: raise(NotImplementedError)
      end

      defmodule B do
        def g, do: raise(NotImplementedError)
      end
      """

      assert [issue] = run(StubBody, source)
      assert issue.line_no == 7
    end

    test "malformed stub_pattern raises" do
      assert_raise ArgumentError, ~r/stub_pattern must be a Regex/, fn ->
        run_direct(StubBody, "defmodule A do\nend", stub_pattern: "todo")
      end
    end
  end

  describe "ErrorReasonString" do
    test "every occurrence gets its own exact line, including repeated messages" do
      issues =
        run(ErrorReasonString, """
        defmodule A do
          def f(x) do
            if x do
              {:error, "boom"}
            else
              {:error, "boom"}
            end
          end

          def g, do: {:error, "boom"}
        end
        """)

      assert Enum.map(issues, & &1.line_no) == [4, 6, 10]
    end

    test "heredoc and escaped strings are located without text search" do
      [issue] =
        run(ErrorReasonString, ~S'''
        defmodule A do
          def f do
            x = 1
            {:error, "line \"quoted\"
        second"}
          end
        end
        ''')

      assert issue.line_no == 4
    end

    test "interpolated strings are located and can be turned off" do
      source = ~S'''
      defmodule A do
        def f(x) do
          y = x

          {:error, "bad #{y}"}
        end
      end
      '''

      assert [%{line_no: 5}] = run(ErrorReasonString, source)

      ErrorReasonString
      |> run(source, flag_interpolated: false)
      |> refute_issues()
    end

    test "patterns, match?/2 patterns and heads are not constructions" do
      ErrorReasonString
      |> run("""
      defmodule A do
        def f({:error, "x"}), do: 1

        def g(r) do
          case r do
            {:error, "boom"} -> match?({:error, "bam"}, r)
          end
        end

        def h(r) do
          {:error, "boom"} = r
          with {:error, "boom"} <- r, do: 1
        end
      end
      """)
      |> refute_issues()
    end
  end

  describe "MapGetAtomKey" do
    test "piped and aliased Map.get, lexical alias" do
      source = """
      defmodule A do
        alias Map, as: M

        def f(state) do
          state |> M.get(:k)
        end
      end

      defmodule B do
        alias MyApp.Map
        def g(state), do: Map.get(state, :k)
      end
      """

      assert [%{line_no: 5}] = run(MapGetAtomKey, source)
    end

    test "ignored receivers can be extended and must be atoms" do
      assert [_] = run(MapGetAtomKey, "def f(state), do: state[:k]")

      MapGetAtomKey
      |> run("def f(state), do: state[:k]", ignored_receivers: [:state])
      |> refute_issues()

      assert_raise ArgumentError, fn ->
        run_direct(MapGetAtomKey, "def f(state), do: state[:k]", ignored_receivers: ["state"])
      end
    end
  end
end
