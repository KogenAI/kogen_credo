defmodule KogenCredo.Integrity do
  @moduledoc """
  Pure helpers that keep the quality gates themselves honest.

  Two independent tools live here. Neither runs Credo, touches git or writes
  files; callers pass source text or already-read file contents in.

  ## Suppression scan

  `scan_suppressions/2` finds comments that switch a gate off: Credo pragmas
  (`# credo:disable-for-this-file`, `…-next-line`, `…-previous-line`,
  `…-lines:N`), Sobelow skips, coverage ignores and `# dialyzer`/`# noqa` style comment
  pragmas. Only **comments** are scanned (attributes such as `@dialyzer` or `@tag :skip` are not
  comments; see `KogenCredo.Check.Warning.SkippedTest` and friends for those). Comments are taken from the real tokenizer
  (`Code.string_to_quoted_with_comments/2`), so a pragma-looking line inside a
  string or heredoc is not reported. A file that does not parse yields
  `{:error, reason}`; it is never reported as "no suppressions".

  The default patterns are deliberately generic. Pass `:patterns` as a list of
  `{kind, ~r/regex/}` to change what counts as a suppression.

  ## Golden-config comparison

  `compare_credo_config/3` compares a trusted golden Credo config against the
  one in the working tree and reports what was removed, disabled, loosened or
  excluded. `parse_config/1` reads a `.credo.exs` **without evaluating it**: only
  literal terms, module aliases, `~r` sigils and the `%{}`/list/tuple forms
  Credo configs use are accepted, so a config cannot execute code while being
  compared. Anything else (function calls, variables, `File.read!`, several top-level
  expressions, an invalid regex) returns `{:error, {:unsupported, snippet}}`; a config containing an unsupported expression is therefore never reported as "unchanged". `assert_matches_golden!/3`
  raises on any parse error, and `compare_sources/3` returns it as a value.

  Plugins, `requires` and checks added by code are not evaluated; a config that depends on them
  is reported as unsupported when they appear as non-literals. Literal `requires` files and
  `plugins` that the actual config adds are code Credo would load and run, so they are reported
  (`:requires_added`, `:plugin_added`) and never pass as "unchanged". The comparison also reports
  removed `plugins` and `files.included` entries and removed configs. A config whose `checks`,
  `plugins`, `requires` or `files` have a shape Credo does not accept is
  `{:error, {side, :not_a_credo_config}}`, never an exception. Limits: the comparison is
  structural. Contents of referenced files are outside this comparison. It cannot tell whether a changed
  parameter value is stricter or looser (it reports `:params_changed` and
  leaves the judgement to the reviewer), and checks enabled through plugins
  or `requires` code are visible only if they are listed in `checks`. Other top-level keys
  (for example `parsers`) are not compared.
  """

  alias KogenCredo.CoreSupport.Ast

  defmodule ModuleRef do
    @moduledoc """
    A module written in a Credo config (`Credo.Check.Design.TagTODO`), identified by its name.

    `parse_config/1` reads the text of a config without evaluating it, so the module may not exist
    in the running VM; no atom is created for it. It prints like the module (`inspect/1` shows
    `Credo.Check.Design.TagTODO`) and is a struct, so it can never compare equal to a plain
    string or atom in the config.
    """
    @enforce_keys [:name]
    defstruct [:name]

    @type t :: %__MODULE__{name: KogenCredo.CoreSupport.Ast.module_name()}
  end

  defimpl Inspect, for: ModuleRef do
    @impl Inspect
    @spec inspect(ModuleRef.t(), Inspect.Opts.t()) :: String.t()
    def inspect(%{name: name}, _), do: name
  end

  @typedoc "A module written in the config, by name (see `KogenCredo.Integrity.ModuleRef`)."
  @type module_ref :: ModuleRef.t()

  @type suppression :: %{line: pos_integer(), kind: atom(), text: String.t()}
  @type difference ::
          {:config_removed, config :: String.t()}
          | {:plugin_removed, config :: String.t(), term()}
          | {:plugin_added, config :: String.t(), term()}
          | {:requires_added, config :: String.t(), term()}
          | {:requires_removed, config :: String.t(), term()}
          | {:inclusion_removed, config :: String.t(), term()}
          | {:check_removed, module_ref()}
          | {:check_disabled, module_ref()}
          | {:params_changed, module_ref(), golden :: term(), actual :: term()}
          | {:exclusion_added, config :: String.t(), term() | {module_ref(), term()}}
          | {:strict_disabled, config :: String.t()}

  @default_patterns [
    # Credo's own finder is `#\s*credo\:…` with the `i` flag: the prefix is case-insensitive while
    # the instruction is compared literally, so only `credo` is made case-insensitive here.
    credo_disable:
      ~r/#\s*(?i:credo):disable-for-(this-file|next-line|previous-line|lines:[+-]?\d*)/,
    credo_ignore: ~r/#\s*(?i:credo):disable\b/,
    sobelow_skip: ~r/#\s*sobelow_skip\b/,
    coverage_ignore: ~r/#\s*coveralls-ignore-(start|stop|next-line)/,
    elixir_ls_ignore: ~r/#\s*(dialyzer|noqa|nolint)\b/i
  ]

  @doc "The default suppression patterns, as `{kind, regex}`."
  @spec default_patterns() :: keyword(Regex.t())
  def default_patterns, do: @default_patterns

  @doc """
  Scans one source text for suppression comments.

  Options: `:patterns` (keyword of kind => regex, default `default_patterns/0`).
  Each comment is reported once, under the first matching kind.
  """
  @spec scan_suppressions(String.t(), keyword()) ::
          {:ok, [suppression()]} | {:error, term()}
  def scan_suppressions(source, opts \\ []) when is_binary(source) do
    patterns = Keyword.get(opts, :patterns, @default_patterns)

    case Code.string_to_quoted_with_comments(source, columns: true, emit_warnings: false) do
      {:ok, _, comments} ->
        found =
          for %{line: line, text: text} <- comments,
              {kind, _} <- [first_match(patterns, text)],
              kind != nil do
            %{line: line, kind: kind, text: String.trim(text)}
          end

        {:ok, found}

      {:error, reason} ->
        {:error, {:invalid_source, reason}}
    end
  end

  defp first_match(patterns, text) do
    Enum.find(patterns, {nil, nil}, fn {_, regex} -> Regex.match?(regex, text) end)
  end

  @doc """
  Scans many files given as `%{path => source}`. Returns
  `{suppressions_by_path, errors_by_path}`; files that fail to parse are in
  the second map and are never silently dropped.
  """
  @spec scan_files(%{String.t() => String.t()}, keyword()) ::
          {%{String.t() => [suppression()]}, %{String.t() => term()}}
  def scan_files(files, opts \\ []) when is_map(files) do
    Enum.reduce(files, {%{}, %{}}, fn {path, source}, {found, errors} ->
      case scan_suppressions(source, opts) do
        {:ok, []} -> {found, errors}
        {:ok, hits} -> {Map.put(found, path, hits), errors}
        {:error, reason} -> {found, Map.put(errors, path, reason)}
      end
    end)
  end

  @doc """
  Parses the text of a Credo config file into a term without evaluating code.
  """
  @spec parse_config(String.t()) :: {:ok, term()} | {:error, term()}
  def parse_config(source) when is_binary(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, ast} -> literal(ast)
      {:error, reason} -> {:error, {:invalid_source, reason}}
    end
  end

  defp literal(ast) do
    {:ok, eval_literal(ast)}
  catch
    {:unsupported, snippet} -> {:error, {:unsupported, snippet}}
  end

  defp eval_literal(value) when is_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> _ -> %ModuleRef{name: Ast.atom_name(value)}
      _ -> value
    end
  end

  defp eval_literal(value) when is_number(value) or is_binary(value), do: value

  defp eval_literal(list) when is_list(list), do: Enum.map(list, &eval_literal/1)
  defp eval_literal({a, b}), do: {eval_literal(a), eval_literal(b)}

  defp eval_literal({:{}, _, items}) do
    items
    |> Enum.map(&eval_literal/1)
    |> List.to_tuple()
  end

  defp eval_literal({:%{}, _, pairs}),
    do: Map.new(pairs, fn {k, v} -> {eval_literal(k), eval_literal(v)} end)

  defp eval_literal({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do: %ModuleRef{name: Ast.join_name(parts)},
      else: unsupported(parts)
  end

  defp eval_literal({:sigil_r, _, [{:<<>>, _, [source]}, mods]} = node)
       when is_binary(source) and is_list(mods) do
    case Regex.compile(source, List.to_string(mods)) do
      {:ok, regex} -> regex
      {:error, _} -> unsupported(node)
    end
  end

  defp eval_literal({:-, _, [n]}) when is_number(n), do: -n
  defp eval_literal({:__block__, _, [single]}), do: eval_literal(single)
  defp eval_literal(other), do: unsupported(other)

  defp unsupported(node),
    do:
      throw(
        {:unsupported,
         node
         |> Macro.to_string()
         |> String.slice(0, 80)}
      )

  @doc """
  Compares an actual Credo config against a golden one.

  Both arguments are config terms as returned by `parse_config/1` (the
  `%{configs: [...]}` map, a single config map, or a list of configs).
  Configs are matched by `:name` (default `"default"`). Returns a list of
  `t:difference/0`; `[]` means the actual config keeps everything the golden
  one has. Extra checks in the actual config are fine.

  Reported:

    * `{:config_removed, config}` — a golden config has no counterpart (by name) in actual
    * `{:plugin_removed, config, plugin}` — a golden `plugins` entry is gone
    * `{:inclusion_removed, config, term}` — a golden `files.included` entry is gone
    * `{:check_removed, mod}` — in golden, absent in actual
    * `{:check_disabled, mod}` — enabled in golden, `false` or listed under
      `disabled:` in actual
    * `{:params_changed, mod, golden, actual}` — params differ (either direction)
    * `{:exclusion_added, config, term}` — the config's `files.excluded` grew
    * `{:exclusion_added, config, {mod, term}}` — a check's own `files.excluded` param grew
      (any other change to that check's params is still `:params_changed`)
    * `{:requires_removed, config, path}` — a golden loader is gone (checks it provided could vanish)
    * `{:requires_added, config, path}` — actual `requires` has a file golden does not
      (Credo would load and run it)
    * `{:plugin_added, config, plugin}` — actual `plugins` has an entry golden does not
      (a changed plugin entry is both removed and added)
    * `{:strict_disabled, config}` — golden has `strict: true`, actual does not
  """
  @spec compare_credo_config(term(), term(), keyword()) :: [difference()]
  def compare_credo_config(golden, actual, _ \\ []) do
    golden_configs = configs(golden)
    actual_configs = configs(actual)

    Enum.flat_map(golden_configs, fn {name, golden_config} ->
      case Map.fetch(actual_configs, name) do
        :error ->
          [{:config_removed, name} | removed_checks(golden_config)]

        {:ok, actual_config} ->
          compare_config(name, golden_config, actual_config)
      end
    end)
  end

  defp removed_checks(golden_config) do
    for {mod, params} <- checks(golden_config), params != false, do: {:check_removed, mod}
  end

  @doc """
  Parses both sources and compares them. Returns `{:ok, differences}` or the first parse error
  (`{:error, {:golden | :actual, reason}}`); an unreadable policy is an error, never "no change".
  """
  @spec compare_sources(String.t(), String.t(), keyword()) ::
          {:ok, [difference()]} | {:error, {:golden | :actual, term()}}
  def compare_sources(golden_source, actual_source, opts \\ []) do
    with {:ok, golden} <- parse_side(golden_source, :golden),
         {:ok, actual} <- parse_side(actual_source, :actual),
         :ok <- check_shape(golden, actual) do
      {:ok, compare_credo_config(golden, actual, opts)}
    end
  end

  defp parse_side(source, side) do
    case parse_config(source) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {side, reason}}
    end
  end

  defp check_shape(golden, actual) do
    case valid_shape(golden, actual) do
      :ok -> :ok
      {:error, side, reason} -> {:error, {side, reason}}
    end
  end

  defp valid_shape(golden, actual) do
    cond do
      not config_shape?(golden) -> {:error, :golden, :not_a_credo_config}
      not config_shape?(actual) -> {:error, :actual, :not_a_credo_config}
      true -> :ok
    end
  end

  defp config_shape?(%{configs: list}) when is_list(list), do: valid_configs?(list)

  defp config_shape?(%{} = single),
    do: (Map.has_key?(single, :checks) or Map.has_key?(single, :name)) and valid_config?(single)

  defp config_shape?(list) when is_list(list), do: valid_configs?(list)
  defp config_shape?(_), do: false

  defp valid_configs?(configs) do
    Enum.all?(configs, &valid_config?/1) and
      length(Enum.uniq_by(configs, &Map.get(&1, :name, "default"))) == length(configs)
  end

  defp valid_config?(%{} = config) do
    is_binary(Map.get(config, :name, "default")) and
      valid_checks?(Map.get(config, :checks, [])) and
      list_or_missing?(config, :plugins) and
      list_or_missing?(config, :requires) and
      valid_files?(Map.get(config, :files, %{}))
  end

  defp valid_config?(_), do: false

  defp list_or_missing?(config, key) do
    config
    |> Map.get(key, [])
    |> is_list()
  end

  defp valid_files?(%{} = files) do
    Enum.all?([:included, :excluded], &is_list(Map.get(files, &1, [])))
  end

  defp valid_files?(_), do: false

  defp valid_checks?(%{} = grouped) do
    Enum.all?([:enabled, :extra, :disabled], fn key ->
      list = Map.get(grouped, key, [])
      is_list(list) and Enum.all?(list, &valid_check_entry?/1)
    end)
  end

  defp valid_checks?(list) when is_list(list), do: Enum.all?(list, &valid_check_entry?/1)
  defp valid_checks?(_), do: false

  defp valid_check_entry?({mod, params}),
    do: module_like?(mod) and (params == false or (is_list(params) and Keyword.keyword?(params)))

  defp valid_check_entry?({mod}), do: module_like?(mod)
  defp valid_check_entry?(mod), do: module_like?(mod)

  defp module_like?(%ModuleRef{}), do: true
  defp module_like?(mod), do: is_atom(mod)

  defp compare_config(name, golden, actual) do
    Enum.concat([
      check_diffs(name, checks(golden), checks(actual)),
      exclusion_diffs(name, golden, actual),
      inclusion_diffs(name, golden, actual),
      plugin_diffs(name, golden, actual),
      requires_diffs(name, golden, actual),
      strict_diffs(name, golden, actual)
    ])
  end

  defp check_diffs(name, golden_checks, actual_checks) do
    Enum.flat_map(golden_checks, fn {mod, golden_params} ->
      check_diff(name, mod, golden_params, Map.fetch(actual_checks, mod))
    end)
  end

  defp check_diff(_, _, false, :error), do: []
  defp check_diff(_, mod, _, :error), do: [{:check_removed, mod}]

  defp check_diff(_, mod, golden_params, {:ok, false}) when golden_params != false,
    do: [{:check_disabled, mod}]

  defp check_diff(name, mod, golden_params, {:ok, actual_params}),
    do: compare_params(name, mod, golden_params, actual_params)

  defp exclusion_diffs(name, golden, actual),
    do: for(term <- excluded(actual) -- excluded(golden), do: {:exclusion_added, name, term})

  defp inclusion_diffs(name, golden, actual),
    do: for(term <- included(golden) -- included(actual), do: {:inclusion_removed, name, term})

  defp plugin_diffs(name, golden, actual) do
    for(term <- plugins(golden) -- plugins(actual), do: {:plugin_removed, name, term}) ++
      for term <- plugins(actual) -- plugins(golden), do: {:plugin_added, name, term}
  end

  defp requires_diffs(name, golden, actual) do
    for(term <- requires(actual) -- requires(golden), do: {:requires_added, name, term}) ++
      for term <- requires(golden) -- requires(actual), do: {:requires_removed, name, term}
  end

  defp strict_diffs(name, golden, actual) do
    if Map.get(golden, :strict) == true and Map.get(actual, :strict) != true,
      do: [{:strict_disabled, name}],
      else: []
  end

  # A check's own `files: %{excluded: [...]}` growth is reported as `:exclusion_added`; whatever
  # else differs (including entries removed from that list) stays `:params_changed`.
  defp compare_params(name, mod, golden_params, actual_params) do
    if comparable(actual_params) == comparable(golden_params) do
      []
    else
      {golden_rest, golden_excluded} = split_excluded(golden_params)
      {actual_rest, actual_excluded} = split_excluded(actual_params)
      added = actual_excluded -- golden_excluded
      removed = golden_excluded -- actual_excluded

      exclusion_diffs = for term <- added, do: {:exclusion_added, name, {mod, term}}

      if added != [] and removed == [] and comparable(golden_rest) == comparable(actual_rest),
        do: exclusion_diffs,
        else: Enum.concat(exclusion_diffs, [{:params_changed, mod, golden_params, actual_params}])
    end
  end

  # Returns {params without files.excluded, files.excluded entries}. Non-keyword params pass through.
  defp split_excluded(params) when is_list(params) do
    with true <- Keyword.keyword?(params),
         {:ok, files} when is_list(files) or is_map(files) <- Keyword.fetch(params, :files) do
      extract_excluded(params, Enum.into(files, %{}))
    else
      _ -> {params, []}
    end
  end

  defp split_excluded(params), do: {params, []}

  defp extract_excluded(params, files) do
    excluded =
      files
      |> Map.get(:excluded, [])
      |> List.wrap()
      |> Enum.map(&comparable/1)

    rest =
      case Map.delete(files, :excluded) do
        empty when map_size(empty) == 0 -> Keyword.delete(params, :files)
        others -> Keyword.put(params, :files, others)
      end

    {rest, excluded}
  end

  # Compiled regexes carry a runtime reference on some OTP versions; compare them by source.
  defp comparable(%Regex{source: source, opts: opts}), do: {:regex, source, opts}
  defp comparable(list) when is_list(list), do: Enum.map(list, &comparable/1)

  defp comparable(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> comparable()
    |> List.to_tuple()
  end

  defp comparable(%{__struct__: _} = struct), do: struct

  defp comparable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {comparable(k), comparable(v)} end)

  defp comparable(other), do: other

  defp configs(%{configs: list}) when is_list(list), do: configs(list)
  defp configs(%{} = single), do: configs([single])

  defp configs(list) when is_list(list) do
    Map.new(list, fn config -> {Map.get(config, :name, "default"), config} end)
  end

  defp excluded(config) do
    case config do
      %{files: %{excluded: list}} when is_list(list) -> Enum.map(list, &comparable/1)
      _ -> []
    end
  end

  defp included(config) do
    case config do
      %{files: %{included: list}} when is_list(list) -> Enum.map(list, &comparable/1)
      _ -> []
    end
  end

  defp requires(config) do
    case config do
      %{requires: list} when is_list(list) -> Enum.map(list, &comparable/1)
      _ -> []
    end
  end

  defp plugins(config) do
    case config do
      %{plugins: list} when is_list(list) -> Enum.map(list, &comparable/1)
      _ -> []
    end
  end

  # Normalises both Credo check layouts (`[{Mod, params}]` and `%{enabled: [...], disabled: [...]}`)
  # to %{module => params | false}. A bare `{Mod}` tuple counts as `[]`.
  defp checks(config) do
    case Map.get(config, :checks, []) do
      %{} = grouped ->
        enabled_pairs =
          grouped
          |> Map.get(:enabled, [])
          |> check_pairs()

        extra_pairs =
          grouped
          |> Map.get(:extra, [])
          |> check_pairs()

        enabled = Map.merge(enabled_pairs, extra_pairs)

        disabled =
          grouped
          |> Map.get(:disabled, [])
          |> check_pairs()
          |> Map.new(fn {m, _} -> {m, false} end)

        Map.merge(enabled, disabled)

      list when is_list(list) ->
        check_pairs(list)
    end
  end

  defp check_pairs(list) do
    Map.new(list, fn
      {mod, params} -> {mod, params}
      {mod} -> {mod, []}
      %ModuleRef{} = mod -> {mod, []}
      mod when is_atom(mod) -> {mod, []}
    end)
  end

  @doc """
  Raises `ExUnit.AssertionError`-style failure text when the configs differ.

  Returns `:ok` when `compare_credo_config/3` finds nothing. Meant for a test:

      Integrity.assert_matches_golden!(File.read!("test/golden/credo.exs"), File.read!(".credo.exs"))
  """
  @spec assert_matches_golden!(String.t(), String.t(), keyword()) :: :ok
  def assert_matches_golden!(golden_source, actual_source, opts \\ []) do
    case compare_sources(golden_source, actual_source, opts) do
      {:ok, []} ->
        :ok

      {:ok, diffs} ->
        raise "Credo config drifted from golden:\n" <>
                Enum.map_join(diffs, "\n", &"  #{inspect(&1)}")

      {:error, {side, reason}} ->
        raise "could not read #{side} Credo config: #{inspect(reason)}"
    end
  end
end
