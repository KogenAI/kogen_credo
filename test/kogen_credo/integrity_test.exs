defmodule KogenCredo.IntegrityTest do
  use ExUnit.Case, async: true

  alias KogenCredo.Integrity
  alias KogenCredo.Integrity.ModuleRef

  # A module written in a config *source* is read as a name, never as an atom.
  defp ref(name), do: %ModuleRef{name: name}

  describe "scan_suppressions/2" do
    test "finds credo, sobelow and coverage pragmas with line numbers" do
      source = """
      defmodule A do
        # credo:disable-for-next-line Credo.Check.Warning.IoInspect
        def a, do: IO.inspect(1)

        # sobelow_skip ["SQL.Query"]
        def b, do: 2

        # coveralls-ignore-start
        def c, do: 3
        # coveralls-ignore-stop
      end
      """

      assert {:ok, hits} = Integrity.scan_suppressions(source)

      assert [
               {2, :credo_disable},
               {5, :sobelow_skip},
               {8, :coverage_ignore},
               {10, :coverage_ignore}
             ] = Enum.map(hits, &{&1.line, &1.kind})
    end

    test "ignores pragma-looking text inside strings and heredocs" do
      source = ~S'''
      defmodule A do
        @doc """
        Explains `# credo:disable-for-this-file` to readers.
        """
        def a, do: "# sobelow_skip"
      end
      '''

      assert {:ok, []} = Integrity.scan_suppressions(source)
    end

    test "ordinary comments are not suppressions" do
      assert {:ok, []} = Integrity.scan_suppressions("# nothing to see\nx = 1\n")
    end

    test "invalid source is an error, not an empty result" do
      assert {:error, {:invalid_source, _}} = Integrity.scan_suppressions("def (")
    end

    test "custom patterns replace the defaults" do
      source = "# nolint-custom\n# credo:disable-for-this-file\n"

      assert {:ok, [%{kind: :custom, line: 1}]} =
               Integrity.scan_suppressions(source, patterns: [custom: ~r/nolint-custom/])
    end
  end

  describe "scan_suppressions/2 and Credo's case-insensitive prefix" do
    test "reports CREDO:/Credo: variants Credo itself honours" do
      for prefix <- ["CREDO", "Credo", "cReDo"] do
        source = "defmodule A do\n  # #{prefix}:disable-for-next-line\n  def f, do: 1\nend\n"

        assert {:ok, [%{line: 2, kind: :credo_disable}]} = Integrity.scan_suppressions(source)
      end

      assert {:ok, [%{line: 1, kind: :credo_disable}]} =
               Integrity.scan_suppressions("# CREDO:disable-for-this-file\ndefmodule A do\nend\n")

      assert {:ok, [%{kind: :credo_disable}]} =
               Integrity.scan_suppressions("# Credo:disable-for-lines:+2\ndefmodule A do\nend\n")
    end

    test "the instruction stays case-sensitive and strings are not comments" do
      assert {:ok, []} =
               Integrity.scan_suppressions("# credo:DISABLE-FOR-THIS-FILE\ndefmodule A do\nend\n")

      assert {:ok, []} =
               Integrity.scan_suppressions(~S'x = "# CREDO:disable-for-this-file"' <> "\n")
    end
  end

  describe "scan_files/2" do
    test "separates hits, clean files and parse errors" do
      files = %{
        "lib/a.ex" => "# credo:disable-for-this-file\n",
        "lib/b.ex" => "x = 1\n",
        "lib/c.ex" => "def ("
      }

      assert {found, errors} = Integrity.scan_files(files)
      assert Map.keys(found) == ["lib/a.ex"]
      assert Map.keys(errors) == ["lib/c.ex"]
    end
  end

  describe "parse_config/1" do
    test "reads a credo-style config without evaluating code" do
      source = """
      %{configs: [%{name: "default", strict: true,
        files: %{included: ["lib/"], excluded: [~r"/_build/"]},
        checks: [{Credo.Check.Warning.IoInspect, []}, {Credo.Check.Design.TagTODO, false}]}]}
      """

      assert {:ok, %{configs: [config]}} = Integrity.parse_config(source)

      assert config.checks == [
               {ref("Credo.Check.Warning.IoInspect"), []},
               {ref("Credo.Check.Design.TagTODO"), false}
             ]

      assert [%Regex{}] = config.files.excluded
    end

    test "rejects code it would have to execute" do
      assert {:error, {:unsupported, snippet}} =
               Integrity.parse_config(~s|%{a: System.cmd("ls", [])}|)

      assert snippet =~ "System.cmd"
    end

    test "invalid source is an error" do
      assert {:error, {:invalid_source, _}} = Integrity.parse_config("%{")
    end
  end

  describe "compare_credo_config/3" do
    defp config(checks, extra \\ %{}) do
      %{configs: [Map.merge(%{name: "default", checks: checks}, extra)]}
    end

    test "identical configs and added checks are fine" do
      golden = config([{A, []}, {B, [max: 1]}])
      actual = config([{A, []}, {B, [max: 1]}, {C, []}])
      assert [] = Integrity.compare_credo_config(golden, actual)
    end

    test "reports removed, disabled and changed checks" do
      golden = config([{A, []}, {B, [max: 1]}, {C, []}])
      actual = config([{B, [max: 9]}, {C, false}])

      diffs = Integrity.compare_credo_config(golden, actual)

      assert Enum.sort(diffs) ==
               Enum.sort([
                 {:check_removed, A},
                 {:check_disabled, C},
                 {:params_changed, B, [max: 1], [max: 9]}
               ])
    end

    test "understands the enabled/disabled layout" do
      golden = config(%{enabled: [{A, []}], disabled: []})
      actual = config(%{enabled: [], disabled: [{A, []}]})
      assert [{:check_disabled, A}] = Integrity.compare_credo_config(golden, actual)
    end

    test "reports new exclusions and lost strict mode" do
      golden = config([], %{strict: true, files: %{excluded: ["a/"]}})
      actual = config([], %{strict: false, files: %{excluded: ["a/", "lib/secret/"]}})

      assert [{:exclusion_added, "default", "lib/secret/"}, {:strict_disabled, "default"}] =
               Integrity.compare_credo_config(golden, actual)
    end

    test "a golden config missing from actual reports every check removed" do
      golden = config([{A, []}])
      actual = %{configs: [%{name: "other", checks: []}]}

      assert [{:config_removed, "default"}, {:check_removed, A}] =
               Integrity.compare_credo_config(golden, actual)
    end

    test "a golden config with no checks that vanishes is still reported" do
      golden = %{configs: [%{name: "ci", checks: []}]}
      actual = %{configs: [%{name: "default", checks: []}]}
      assert [{:config_removed, "ci"}] = Integrity.compare_credo_config(golden, actual)
    end

    test "checks under `extra:` count as enabled on both sides" do
      golden = %{configs: [%{name: "default", checks: %{enabled: [], extra: [{A, [max: 1]}]}}]}
      same = golden
      moved = %{configs: [%{name: "default", checks: %{enabled: [{A, [max: 1]}]}}]}
      gone = %{configs: [%{name: "default", checks: %{enabled: []}}]}

      assert [] = Integrity.compare_credo_config(golden, same)
      assert [] = Integrity.compare_credo_config(golden, moved)
      assert [{:check_removed, A}] = Integrity.compare_credo_config(golden, gone)
    end

    test "a check disabled in golden and absent in actual is not drift" do
      golden = config([{A, false}])
      actual = config([])
      assert [] = Integrity.compare_credo_config(golden, actual)
    end

    test "removed files.included entries and plugins are reported" do
      golden = %{
        configs: [
          %{
            name: "default",
            files: %{included: ["lib/", "src/"]},
            plugins: [{P, []}],
            checks: []
          }
        ]
      }

      actual = %{
        configs: [%{name: "default", files: %{included: ["lib/"]}, plugins: [], checks: []}]
      }

      assert [{:inclusion_removed, "default", "src/"}, {:plugin_removed, "default", {P, []}}] =
               Integrity.compare_credo_config(golden, actual)
    end

    test "equal regexes in params are equal however they were compiled" do
      golden = config([{A, [pattern: ~r/foo/i]}])
      actual = config([{A, [pattern: Regex.compile!("foo", "i")]}])
      assert [] = Integrity.compare_credo_config(golden, actual)

      other = config([{A, [pattern: ~r/bar/i]}])
      assert [{:params_changed, A, _, _}] = Integrity.compare_credo_config(golden, other)
    end
  end

  describe "added requires, plugins and per-check exclusions" do
    test "added requires files and plugins are reported" do
      golden = config([], %{plugins: [{P, []}], requires: ["a.exs"]})

      actual =
        config([], %{
          plugins: [{P, []}, {Evil.Plugin, []}],
          requires: ["a.exs", "lib/evil.exs"]
        })

      diffs = Integrity.compare_credo_config(golden, actual)

      assert Enum.sort(diffs) ==
               Enum.sort([
                 {:plugin_added, "default", {Evil.Plugin, []}},
                 {:requires_added, "default", "lib/evil.exs"}
               ])

      assert [] = Integrity.compare_credo_config(actual, actual)
    end

    test "a changed plugin entry is both removed and added" do
      golden = config([], %{plugins: [{P, [a: 1]}]})
      actual = config([], %{plugins: [{P, [a: 2]}]})

      assert [{:plugin_removed, "default", {P, [a: 1]}}, {:plugin_added, "default", {P, [a: 2]}}] =
               Integrity.compare_credo_config(golden, actual)
    end

    test "requires and plugins added from source never execute and are reported" do
      golden = ~S'%{configs: [%{name: "default", checks: []}]}'

      actual =
        ~S'%{configs: [%{name: "default", requires: ["lib/evil.exs"], plugins: [{Evil.Plugin, []}], checks: []}]}'

      assert {:ok, diffs} = Integrity.compare_sources(golden, actual)

      assert Enum.sort(diffs) ==
               Enum.sort([
                 {:plugin_added, "default", {ref("Evil.Plugin"), []}},
                 {:requires_added, "default", "lib/evil.exs"}
               ])

      assert_raise RuntimeError, ~r/drifted/, fn ->
        Integrity.assert_matches_golden!(golden, actual)
      end
    end

    test "a requires entry that is code is unsupported, not executed" do
      actual =
        ~S'%{configs: [%{name: "default", requires: [File.read!("/etc/passwd")], checks: []}]}'

      assert {:error, {:actual, {:unsupported, _}}} =
               Integrity.compare_sources(~S'%{configs: [%{name: "default", checks: []}]}', actual)
    end

    test "growth of a check's files.excluded is exclusion_added" do
      golden = config([{A, [files: %{excluded: ["a/"]}, max: 1]}])
      actual = config([{A, [files: %{excluded: ["a/", "lib/"]}, max: 1]}])

      assert [{:exclusion_added, "default", {A, "lib/"}}] =
               Integrity.compare_credo_config(golden, actual)
    end

    test "per-check exclusion growth from source, with a check that had no params" do
      golden = ~S'%{configs: [%{name: "default", checks: [{A, []}]}]}'
      actual = ~S'%{configs: [%{name: "default", checks: [{A, [files: %{excluded: ["lib/"]}]}]}]}'

      assert Integrity.compare_sources(golden, actual) ==
               {:ok, [{:exclusion_added, "default", {ref("A"), "lib/"}}]}
    end

    test "exclusion growth alongside another param change also reports params_changed" do
      golden = config([{A, [max: 1]}])
      actual = config([{A, [max: 9, files: %{excluded: ["lib/"]}]}])

      assert [{:exclusion_added, "default", {A, "lib/"}}, {:params_changed, A, _, _}] =
               Integrity.compare_credo_config(golden, actual)
    end

    test "a shrunk per-check exclusion list is still a change, not an addition" do
      golden = config([{A, [files: %{excluded: ["a/", "b/"]}]}])
      actual = config([{A, [files: %{excluded: ["a/"]}]}])

      assert [{:params_changed, A, _, _}] = Integrity.compare_credo_config(golden, actual)
    end
  end

  describe "compare_sources/3 returns an error for malformed config shapes" do
    @golden ~S'%{configs: [%{name: "default", checks: [{A, []}]}]}'

    for {label, src} <- [
          {"checks is a list of strings", ~S'%{configs: [%{name: "default", checks: ["x"]}]}'},
          {"checks is an atom", ~S'%{configs: [%{name: "default", checks: :all}]}'},
          {"a three-tuple check", ~S'%{configs: [%{name: "default", checks: [{A, [], :x}]}]}'},
          {"check params are not a list", ~S'%{configs: [%{name: "default", checks: [{A, 1}]}]}'},
          {"grouped enabled is not a list",
           ~S'%{configs: [%{name: "default", checks: %{enabled: :x}}]}'},
          {"grouped disabled has a bad entry",
           ~S'%{configs: [%{name: "default", checks: %{disabled: ["x"]}}]}'},
          {"plugins is not a list",
           ~S'%{configs: [%{name: "default", plugins: :x, checks: []}]}'},
          {"requires is not a list",
           ~S'%{configs: [%{name: "default", requires: "x", checks: []}]}'},
          {"files is not a map", ~S'%{configs: [%{name: "default", files: :x, checks: []}]}'},
          {"files.excluded is not a list",
           ~S'%{configs: [%{name: "default", files: %{excluded: "lib/"}, checks: []}]}'},
          {"a single config with bad checks", ~S'%{name: "default", checks: ["x"]}'}
        ] do
      test "actual: #{label}" do
        assert {:error, {:actual, :not_a_credo_config}} =
                 Integrity.compare_sources(@golden, unquote(src))
      end

      test "golden: #{label}" do
        assert {:error, {:golden, :not_a_credo_config}} =
                 Integrity.compare_sources(unquote(src), @golden)
      end
    end
  end

  describe "parse_config/1 never executes or half-reads a config" do
    test "several top-level expressions are unsupported, not 'the last one'" do
      source = """
      File.write!("/tmp/kogen_integrity_must_not_exist", "x")
      %{configs: [%{name: "default", checks: []}]}
      """

      assert {:error, {:unsupported, _}} = Integrity.parse_config(source)
      refute File.exists?("/tmp/kogen_integrity_must_not_exist")
    end

    test "a binding followed by a literal that uses it is unsupported" do
      assert {:error, {:unsupported, _}} =
               Integrity.parse_config("checks = []\n%{configs: [%{name: \"d\", checks: checks}]}")
    end

    test "function calls, captures, System.get_env and sigils other than ~r are unsupported" do
      for source <- [
            "%{configs: System.get_env(\"X\")}",
            "%{a: System.cmd(\"touch\", [\"x\"])}",
            "%{a: fn -> 1 end}",
            "%{a: &IO.puts/1}",
            "%{a: ~w(a b)}",
            "%{a: \"x\#{1 + 1}\"}",
            "%{a: __MODULE__}",
            "%{a: %Foo{}}",
            "%{a: ~r/x\#{y}/}",
            "[1 | tail]"
          ] do
        assert {:error, {:unsupported, _}} = Integrity.parse_config(source), source
      end
    end

    test "an invalid regex is an unsupported value, not a crash" do
      assert {:error, {:unsupported, _}} = Integrity.parse_config("%{a: ~r/(/}")
    end

    test "a syntax error is an invalid_source error" do
      assert {:error, {:invalid_source, _}} = Integrity.parse_config("%{configs: [")
    end

    test "literal configs with modules, regexes, negative numbers and tuples parse" do
      source = ~S"""
      %{configs: [%{name: "default", strict: true, checks: [{Credo.Check.Design.TagTODO, [exit_status: 2, n: -1, r: ~r/a.b/i, t: {1, :x, 3}]}]}]}
      """

      assert {:ok,
              %{configs: [%{checks: [{%ModuleRef{name: "Credo.Check.Design.TagTODO"}, params}]}]}} =
               Integrity.parse_config(source)

      assert params[:n] == -1
      assert params[:t] == {1, :x, 3}
    end
  end

  describe "compare_sources/3 and assert_matches_golden!/3 never treat unreadable policy as unchanged" do
    @good ~S|%{configs: [%{name: "default", checks: [{A, []}]}]}|

    test "an unparseable actual is an error value" do
      assert {:error, {:actual, {:invalid_source, _}}} =
               Integrity.compare_sources(@good, "%{configs: [")

      assert {:error, {:actual, {:unsupported, _}}} =
               Integrity.compare_sources(@good, "IO.puts(1)")
    end

    test "an unparseable golden is an error value" do
      assert {:error, {:golden, {:unsupported, _}}} =
               Integrity.compare_sources("IO.puts(1)", @good)
    end

    test "a literal that is not a config at all is an error, not an empty comparison" do
      assert {:error, {:actual, :not_a_credo_config}} = Integrity.compare_sources(@good, "nil")
      assert {:error, {:actual, :not_a_credo_config}} = Integrity.compare_sources(@good, ":ok")
      assert {:error, {:actual, :not_a_credo_config}} = Integrity.compare_sources(@good, "42")
    end

    test "assert_matches_golden! raises on each of them" do
      assert_raise RuntimeError, ~r/could not read actual/, fn ->
        Integrity.assert_matches_golden!(@good, "%{configs: [")
      end

      assert_raise RuntimeError, ~r/could not read actual/, fn ->
        Integrity.assert_matches_golden!(@good, "System.halt(0)")
      end

      assert_raise RuntimeError, ~r/could not read golden/, fn ->
        Integrity.assert_matches_golden!("nil", @good)
      end
    end

    test "a config that drops every check is drift" do
      assert Integrity.compare_sources(@good, ~S|%{configs: [%{name: "default", checks: []}]}|) ==
               {:ok, [{:check_removed, ref("A")}]}
    end
  end

  describe "assert_matches_golden!/3" do
    test "ok when equal, raises with the differences otherwise" do
      golden = ~s|%{configs: [%{name: "default", checks: [{Foo.Bar, []}]}]}|
      assert :ok = Integrity.assert_matches_golden!(golden, golden)

      assert_raise RuntimeError, ~r/check_removed/, fn ->
        Integrity.assert_matches_golden!(golden, ~s|%{configs: [%{name: "default", checks: []}]}|)
      end
    end

    test "raises on unreadable config" do
      assert_raise RuntimeError, ~r/could not read/, fn ->
        Integrity.assert_matches_golden!("%{", "%{}")
      end
    end
  end

  test "removing a required source cannot silently remove the checks it defines" do
    golden =
      ~s|%{configs: [%{name: "default", requires: ["checks/custom.exs"], checks: [{A, []}]}]}|

    actual = ~s|%{configs: [%{name: "default", requires: [], checks: [{A, []}]}]}|

    assert {:ok, [{:requires_removed, "default", "checks/custom.exs"}]} =
             Integrity.compare_sources(golden, actual)
  end

  test "non-keyword check parameters return an error instead of raising" do
    golden = ~s|%{configs: [%{name: "default", checks: [{A, []}]}]}|
    actual = ~s|%{configs: [%{name: "default", checks: [{A, [1]}]}]}|
    assert {:error, {:actual, :not_a_credo_config}} = Integrity.compare_sources(golden, actual)
  end

  test "duplicate configuration names cannot hide a weakened first configuration" do
    golden = ~s|%{configs: [%{name: "default", checks: [{A, []}]}]}|

    actual =
      ~s|%{configs: [%{name: "default", checks: []}, %{name: "default", checks: [{A, []}]}]}|

    assert {:error, {:actual, :not_a_credo_config}} = Integrity.compare_sources(golden, actual)
  end

  test "invalid configuration names are structured errors on either side" do
    valid = ~s|%{configs: [%{name: "default", checks: []}]}|
    invalid = ~s|%{configs: [%{name: %{bad: true}, checks: []}]}|
    assert {:error, {:actual, :not_a_credo_config}} = Integrity.compare_sources(valid, invalid)
    assert {:error, {:golden, :not_a_credo_config}} = Integrity.compare_sources(invalid, valid)
  end
end
