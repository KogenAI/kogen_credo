defmodule Mix.Tasks.Kogen.UnusedPublic do
  @shortdoc "Advisory: list public functions that nothing in the project calls"

  @moduledoc """
  Lists public functions with no caller in the project's compiled modules.

      mix kogen.unused_public [--format text|json] [--fail]
        [--entrypoint-module REGEX_OR_NAME]... [--entrypoint-function Mod.fun/arity]...
        [--ignore-module REGEX_OR_NAME]...

  This is **advisory**: it exits 0 unless `--fail` is passed. With `--fail` it exits 1 when there
  are findings and 2 when the analysis was incomplete (some modules had no debug info or could
  not be read), because skipped modules hide callers and an incomplete run must not pass.
  The analysis is described, with its limits, in `KogenCredo.UnusedPublic`. It
  is not whole-program proof; read that moduledoc before acting on a finding.

  ## Compile-state requirements

    * The task runs `mix compile` first (without `--force`), in the current
      `MIX_ENV`, so the analysed beams match the sources. It reads
      `Mix.Project.compile_path/0` (`_build/<env>/lib/<app>/ebin`); in an umbrella
      it reads every child app so cross-app calls are seen.
    * Beams need debug info (the default). Modules compiled with
      `debug_info: false` are listed as skipped and are not counted as callers,
      which can produce false findings; the task says so on stderr.
    * Only the modules compiled for this `MIX_ENV` are callers. Test code is not
      (it is compiled in memory by `mix test`), so a function used only by tests
      is reported, on purpose: "no plumbing without a caller".
    * Do not run it on a library whose public functions are API for other
      projects, or list those modules with `--ignore-module`.

  ## Option values

  `--entrypoint-module`, `--ignore-module`: a module name such as `MyApp.Jobs`
  matches exactly; a value wrapped in slashes, e.g. `/Worker$/`, is a regex.
  Passing `--entrypoint-module` replaces the default patterns (controllers,
  routers, channels, sockets and `Mix.Tasks.*`).
  """

  use Mix.Task

  alias KogenCredo.UnusedPublic

  @switches [
    format: :string,
    fail: :boolean,
    entrypoint_module: :keep,
    entrypoint_function: :keep,
    ignore_module: :keep
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or rest != [] do
      Mix.raise("unexpected arguments: #{inspect(invalid ++ rest)}\n\n#{usage()}")
    end

    format =
      opts
      |> Keyword.get(:format, "text")
      |> validate_format()

    analysis_opts = analysis_options(opts)

    Mix.Task.run("compile")

    {infos, skipped} = collect_modules()
    findings = UnusedPublic.analyze(infos, analysis_opts)

    report_skipped(skipped)
    print(findings, format)

    case exit_status(findings, skipped, Keyword.get(opts, :fail, false)) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end

  defp collect_modules do
    beams = project_beams()
    {infos, skipped} = UnusedPublic.collect(beams)

    if infos == [] and skipped == [] do
      Mix.raise(
        "kogen.unused_public: no compiled modules found under #{inspect(Mix.Project.compile_path())}; " <>
          "nothing was analysed (wrong MIX_ENV, or the project has no modules)"
      )
    end

    {infos, skipped}
  end

  defp report_skipped([]), do: :ok

  defp report_skipped(skipped) do
    Mix.shell().error(
      "kogen.unused_public: #{length(skipped)} module(s) skipped (no debug info or unreadable): " <>
        Enum.map_join(skipped, ", ", fn {module, reason} ->
          "#{module_label(module)} (#{inspect(reason)})"
        end) <>
        ". Their calls are not counted, so the findings below can include false positives, " <>
        "and their own functions were not analysed."
    )
  end

  @doc false
  # 0 clean (or advisory run), 1 findings under --fail, 2 under --fail when the analysis was
  # incomplete (modules without debug info): an incomplete run must not look like a pass.
  @spec exit_status([map()], [term()], boolean()) :: 0 | 1 | 2
  def exit_status(_, _, false), do: 0
  def exit_status(_, [_ | _], true), do: 2
  def exit_status([_ | _], [], true), do: 1
  def exit_status([], [], true), do: 0

  defp usage do
    "usage: mix kogen.unused_public [--format text|json] [--fail] [--entrypoint-module X]... " <>
      "[--entrypoint-function Mod.fun/arity]... [--ignore-module X]..."
  end

  defp validate_format(format) when format in ["text", "json"], do: format

  defp validate_format(other),
    do: Mix.raise("invalid --format #{inspect(other)}; use text or json")

  @doc false
  @spec analysis_options(keyword()) :: keyword()
  def analysis_options(opts) do
    modules = values(opts, :entrypoint_module)
    functions = values(opts, :entrypoint_function)
    ignored = values(opts, :ignore_module)

    Enum.reject(
      [
        entrypoint_modules: if(modules == [], do: nil, else: Enum.map(modules, &matcher/1)),
        entrypoint_functions: functions,
        ignore_modules: Enum.map(ignored, &matcher/1)
      ],
      fn {_, value} -> value in [nil, []] end
    )
  end

  defp values(opts, key), do: for({^key, value} <- opts, do: value)

  @doc false
  @spec matcher(String.t()) :: Regex.t() | String.t()
  def matcher("/" <> rest = raw) do
    case String.split_at(rest, -1) do
      {source, "/"} -> Regex.compile!(source)
      _ -> raise ArgumentError, "unterminated regex #{inspect(raw)}; write it as /source/"
    end
  end

  def matcher(name), do: name

  defp project_beams do
    paths =
      if Mix.Project.umbrella?() do
        for {app, _} <- Mix.Project.apps_paths(),
            do: Path.join([Mix.Project.build_path(), "lib", Atom.to_string(app), "ebin"])
      else
        [Mix.Project.compile_path()]
      end

    for path <- paths,
        beam <- beam_files(path),
        do: {beam_module(beam), String.to_charlist(beam)}
  end

  defp beam_files(path) do
    pattern = Path.join(path, "*.beam")
    Path.wildcard(pattern)
  end

  # The module name is read from the beam itself, so no atom is built from a file name.
  defp beam_module(beam) do
    # On OTP 27, beam_lib.info/1 interns path arguments (and fails for paths over 255
    # characters). Reading bytes also avoids creating atoms for file names.
    with {:ok, contents} <- File.read(beam),
         info when is_list(info) <- :beam_lib.info(contents) do
      Keyword.fetch!(info, :module)
    else
      _ -> beam_label(beam)
    end
  end

  defp beam_label(beam) do
    beam
    |> Path.basename(".beam")
    |> String.replace_prefix("Elixir.", "")
  end

  defp module_label(module) when is_atom(module), do: inspect(module)
  defp module_label(label), do: label

  defp print(findings, "json") do
    json =
      for f <- findings do
        %{
          "module" => inspect(f.module),
          "function" => "#{f.name}/#{f.arity}",
          "file" => f.file,
          "line" => f.line,
          "kind" => Atom.to_string(f.kind)
        }
      end

    encoded = encode_json(json)
    Mix.shell().info(encoded)
  end

  defp print(findings, "text") do
    case UnusedPublic.format(findings) do
      [] -> Mix.shell().info("kogen.unused_public: no findings")
      lines -> Enum.each(lines, fn line -> Mix.shell().info(line) end)
    end
  end

  # Elixir 1.17 has no built-in JSON; Jason is not a dependency. The shapes here are flat.
  defp encode_json(list) do
    "[" <> Enum.map_join(list, ",", &encode_object/1) <> "]"
  end

  defp encode_object(map) do
    "{" <>
      Enum.map_join(map, ",", fn {k, v} -> encode_string(k) <> ":" <> encode_value(v) end) <> "}"
  end

  defp encode_value(nil), do: "null"
  defp encode_value(n) when is_integer(n), do: Integer.to_string(n)
  defp encode_value(s) when is_binary(s), do: encode_string(s)

  defp encode_string(s) do
    escaped =
      for <<c <- s>>, into: "" do
        case c do
          ?" -> "\\\""
          ?\\ -> "\\\\"
          ?\n -> "\\n"
          ?\r -> "\\r"
          ?\t -> "\\t"
          c when c < 0x20 -> "\\u" <> hex(c)
          c -> <<c>>
        end
      end

    "\"" <> escaped <> "\""
  end

  defp hex(code) do
    code
    |> Integer.to_string(16)
    |> String.pad_leading(4, "0")
  end
end
