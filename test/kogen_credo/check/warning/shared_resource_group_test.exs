defmodule KogenCredo.Check.Warning.SharedResourceGroupTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.SharedResourceGroup

  defp mod(name, opts, body) do
    """
    defmodule #{name} do
      use ExUnit.Case, #{opts}
      test "a" do
    #{body}
      end
    end
    """
  end

  defp file(name, opts, body, path \\ nil) do
    name
    |> mod(opts, body)
    |> to_source_file(path || "test/#{Macro.underscore(name)}.exs")
  end

  @put "    Application.put_env(:app, :mode, 1)"

  defp custom_case_file(name, path) do
    source = mod(name, "async: true", @put)
    custom = String.replace(source, "ExUnit.Case", "My.Case")
    to_source_file(custom, path)
  end

  describe "analyze/2 (pure)" do
    test "flags async modules sharing an env key without a group" do
      files = [file("ATest", "async: true", @put), file("BTest", "async: true", @put)]
      findings = SharedResourceGroup.analyze(files)

      modules =
        findings
        |> Enum.map(& &1.module)
        |> Enum.sort()

      assert modules == ["ATest", "BTest"]
      assert hd(findings).message =~ "app.mode"
      assert hd(findings).message =~ "group"
    end

    test "flags when groups differ or only one has a group" do
      differ = [
        file("ATest", "async: true, group: :a", @put),
        file("BTest", "async: true, group: :b", @put)
      ]

      assert length(SharedResourceGroup.analyze(differ)) == 2

      partial = [
        file("ATest", "async: true, group: :a", @put),
        file("BTest", "async: true", @put)
      ]

      assert length(SharedResourceGroup.analyze(partial)) == 2
    end

    test "quiet when all share one group" do
      files = [
        file("ATest", "async: true, group: :m", @put),
        file("BTest", "async: true, group: :m", @put)
      ]

      assert SharedResourceGroup.analyze(files) == []
    end

    test "serial modules do not race with async ones" do
      files = [file("ATest", "async: true", @put), file("BTest", "async: false", @put)]
      assert SharedResourceGroup.analyze(files) == []
    end

    test "different keys, and read-only sharing, are quiet" do
      other = "    Application.put_env(:app, :other, 1)"
      read = "    Application.get_env(:app, :mode)"

      assert SharedResourceGroup.analyze([
               file("ATest", "async: true", @put),
               file("BTest", "async: true", other)
             ]) == []

      assert SharedResourceGroup.analyze([
               file("ATest", "async: true", read),
               file("BTest", "async: true", read)
             ]) == []
    end

    test "a writer and an async reader of the same key are flagged" do
      read = "    Application.get_env(:app, :mode)"

      assert length(
               SharedResourceGroup.analyze([
                 file("ATest", "async: true", @put),
                 file("BTest", "async: true", read)
               ])
             ) == 2
    end

    test "detects ETS tables, file paths, topics and persistent_term keys" do
      bodies = [
        {"    :ets.insert(:shared, {1, 2})", "ets"},
        {"    File.write!(\"priv/out.txt\", \"x\")", "file"},
        {"    Phoenix.PubSub.broadcast(PS, \"topic\", 1)", "topic"},
        {"    :persistent_term.put(:k, 1)", "persistent_term"}
      ]

      for {body, kind} <- bodies do
        files = [file("ATest", "async: true", body), file("BTest", "async: true", body)]
        assert [%{message: message} | _] = SharedResourceGroup.analyze(files)
        assert message =~ kind
      end
    end

    test "two modules in one file are compared" do
      source = mod("ATest", "async: true", @put) <> mod("BTest", "async: true", @put)

      assert length(SharedResourceGroup.analyze([to_source_file(source, "test/both_test.exs")])) ==
               2
    end

    test "lookalikes: dynamic keys and non-test files are ignored" do
      dyn = "    Application.put_env(:app, key, 1)"

      assert SharedResourceGroup.analyze([
               file("ATest", "async: true", dyn),
               file("BTest", "async: true", dyn)
             ]) == []

      lib = [
        file("ATest", "async: true", @put, "lib/a.ex"),
        file("BTest", "async: true", @put, "lib/b.ex")
      ]

      assert SharedResourceGroup.analyze(lib) == []
    end

    test "kinds param and case_templates" do
      files = [file("ATest", "async: true", @put), file("BTest", "async: true", @put)]
      assert SharedResourceGroup.analyze(files, kinds: [:ets]) == []

      tpl = [
        custom_case_file("ATest", "test/a_test.exs"),
        custom_case_file("BTest", "test/b_test.exs")
      ]

      assert SharedResourceGroup.analyze(tpl) == []

      assert length(SharedResourceGroup.analyze(tpl, case_templates: %{"My.Case" => :inherit})) ==
               2
    end
  end

  describe "through Credo's all-files protocol" do
    test "run_check issues land on the offending files" do
      files = [file("ATest", "async: true", @put), file("BTest", "async: true", @put)]
      issues = run_check(files, SharedResourceGroup)
      assert length(issues) == 2

      filenames =
        issues
        |> Enum.map(& &1.filename)
        |> Enum.sort()

      assert filenames == ["test/a_test.exs", "test/b_test.exs"]

      assert Enum.all?(issues, &(&1.check == SharedResourceGroup and &1.line_no == 4))
    end

    test "run_check is quiet with a shared group" do
      files = [
        file("ATest", "async: true, group: :m", @put),
        file("BTest", "async: true, group: :m", @put)
      ]

      assert [] = run_check(files, SharedResourceGroup)
    end

    test "a single file alone has nothing to compare" do
      assert [] = run_check([file("ATest", "async: true", @put)], SharedResourceGroup)
    end
  end
end
