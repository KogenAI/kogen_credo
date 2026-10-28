defmodule KogenCredo.Check.Refactor.DuplicateHelperTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Refactor.DuplicateHelper

  defp helper(module, var \\ "data", extra \\ "") do
    """
    defmodule #{module} do
      def run(x), do: sha(x)

      defp sha(#{var}) do
        #{var}
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)#{extra}
      end
    end
    """
  end

  defp files(sources) do
    sources
    |> Enum.with_index(1)
    |> Enum.map(fn {src, i} -> to_source_file(src, "lib/app/m#{i}.ex") end)
  end

  defp run(files, params \\ []), do: run_check(files, DuplicateHelper, params)

  describe "positives" do
    test "same helper in three files, with renamed variables" do
      issues = run(files([helper("A"), helper("B", "payload"), helper("C", "input")]))
      assert length(issues) == 3
      assert Enum.all?(issues, &(&1.message =~ "`defp sha/1` is duplicated in 3 files"))

      filenames =
        issues
        |> Enum.map(& &1.filename)
        |> Enum.sort()

      assert filenames == ["lib/app/m1.ex", "lib/app/m2.ex", "lib/app/m3.ex"]
    end

    test "min_files param" do
      assert length(run(files([helper("A"), helper("B")]), min_files: 2)) == 2
    end
  end

  describe "negatives and lookalikes" do
    test "two copies are below the default" do
      refute_issues(run(files([helper("A"), helper("B")])))
    end

    test "helpers differing in one expression are different" do
      refute_issues(
        run(
          files([
            helper("A"),
            helper("B", "data", " |> String.upcase()"),
            helper("C", "data", " |> String.downcase()")
          ])
        )
      )
    end

    test "tiny helpers are ignored" do
      tiny = fn m -> "defmodule #{m} do\n  defp id(x), do: x\nend\n" end

      [tiny.("A"), tiny.("B"), tiny.("C")]
      |> files()
      |> run()
      |> refute_issues()
    end

    test "the same helper repeated in one file counts once" do
      source = helper("A") <> helper("A2")
      refute_issues(run(files([source, helper("B")])))
    end

    test "public functions are not helpers" do
      pub =
        "A"
        |> helper()
        |> String.replace("defp sha", "def sha")

      [pub, pub, pub]
      |> files()
      |> run()
      |> refute_issues()
    end

    test "ignored_names" do
      refute_issues(run(files([helper("A"), helper("B"), helper("C")]), ignored_names: [:sha]))
    end
  end

  describe "scope" do
    test "files outside included_paths are ignored" do
      sources = [helper("A"), helper("B"), helper("C")]

      test_files =
        sources
        |> Enum.with_index(1)
        |> Enum.map(fn {s, i} -> to_source_file(s, "test/m#{i}.exs") end)

      test_files
      |> run()
      |> refute_issues()

      assert length(run(test_files, included_paths: ["test/"])) == 3
    end
  end
end
