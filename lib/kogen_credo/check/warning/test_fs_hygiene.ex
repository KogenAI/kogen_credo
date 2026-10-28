defmodule KogenCredo.Check.Warning.TestFsHygiene do
  @moduledoc """
  Flags tests that leave files in the project tree. Applies to `test/` (including
  `test/support/`) by default. Two kinds of finding:

    * `@tag`/`@moduletag`/`@describetag` `:tmp_dir`, `[:tmp_dir]`, `tmp_dir: true` or
      `tmp_dir: "suffix"`. ExUnit creates `tmp/<Module>/<test>` *under the current working
      directory*, i.e. inside the project. `tmp_dir: false`, `tmp_dir: nil`, a dynamic
      value and unrelated tags are not reported;
    * `File` calls that write, delete or create something at a project-relative literal
      path (`File.write!("out.txt", ...)`, `File.mkdir_p("tmp/x")`, `Path.join("fixtures", "a")`)
      or at a path derived from `File.cwd!/0` (also through a variable or module attribute
      bound earlier in the same function). Covered: `write`, `touch`, `mkdir*`, `rm*`,
      `rmdir`, `chmod`/`chown`/`chgrp`, `open`/`stream!` with a `:write`/`:append`/`:exclusive`
      mode, and for `cp`, `cp_r`, `copy`, `rename`, `ln`, `ln_s` the *destination* (second)
      argument. Read-only calls (`File.open(path)`, `File.read`, `File.stream!(path)`) are
      not writes. `File` is resolved through `alias` with lexical scope, so `alias My.File`
      or a nested `defmodule File` is not confused with `File`; pipes are expanded first.

  Absolute paths (`System.tmp_dir!/0`, `/tmp/...`) and injected paths (`tmp_dir`, a
  function argument) are valid and not reported.

  ## Exceptions

  `allow_tmp_dir_paths` and `allow_write_paths` list *test file* paths that are exempt
  from the `:tmp_dir` finding and from the write finding respectively. An entry is a
  directory prefix (`"test/e2e"`), a path suffix (`"support/fixtures.ex"`) or a glob with
  `*` / `**` (`"test/**/golden_*.exs"`), matched on path-segment boundaries.

  ## Limitations

  This is static. Dynamic destinations (`File.write(path, ...)` with `path` from a call or a
  parameter), `import File`, Erlang `:file`, `System.cmd` and paths built in another
  function are not tracked, and the check cannot prove that a test cleans up after itself;
  it finds *project pollution*, not runtime isolation. Variables are tracked linearly
  within a function (no branch analysis); a module attribute bound to `File.cwd!/0` is
  tracked within the enclosing module only.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      included_paths: ["test/"],
      excluded_paths: [],
      allow_tmp_dir_paths: [],
      allow_write_paths: []
    ],
    explanations: [
      check: """
      `@tag :tmp_dir` makes ExUnit create `tmp/<Module>/<test>` under the working directory,
      which is the project tree. Writes to project-relative paths or to `File.cwd!/0` pollute
      it as well, and a polluted tree breaks "clean tree after tests" gates. Build a unique
      directory under `System.tmp_dir!/0` and remove it in `on_exit/1`, or take the path from
      the test's setup.
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked (default `test/`).",
        excluded_paths: "Files under these path prefixes are skipped.",
        allow_tmp_dir_paths:
          "Test files allowed to use `:tmp_dir`: directory prefixes, path suffixes or `*`/`**` globs.",
        allow_write_paths:
          "Test files allowed to write into the project tree: directory prefixes, path suffixes or `*`/`**` globs."
      ]
    ]

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings

  @tag_attrs [:tag, :moduletag, :describetag]
  @function_forms [:def, :defp, :defmacro, :defmacrop, :test, :setup, :setup_all]
  @dest_first ~w(write write! touch touch! mkdir mkdir! mkdir_p mkdir_p! rm rm! rm_rf rm_rf!
                 rmdir rmdir! chmod chmod! chown chown! chgrp chgrp!)a
  @dest_second ~w(cp cp! cp_r cp_r! copy copy! rename rename! ln ln! ln_s ln_s!)a
  @moded ~w(open open! stream!)a
  @write_modes [:write, :append, :exclusive]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> findings(filename, params)
      |> Enum.map(fn {line, trigger, message} ->
        format_issue(issue_meta, message: message, trigger: trigger, line_no: line)
      end)
    else
      []
    end
  end

  defp findings(source_file, filename, params) do
    ctx = %{
      tmp?: not allowed?(filename, params, :allow_tmp_dir_paths),
      write?: not allowed?(filename, params, :allow_write_paths)
    }

    source_file
    |> SourceFile.ast()
    |> without_quotes()
    |> Ast.expand_pipes()
    |> Scope.walk(%{found: [], vars: MapSet.new(), attrs: MapSet.new()}, &step(&1, &2, &3, ctx))
    |> Map.fetch!(:found)
    |> Enum.reverse()
  end

  defp without_quotes(ast) do
    Macro.prewalk(ast, fn
      {:quote, meta, _} -> {:__block__, meta, []}
      node -> node
    end)
  end

  defp allowed?(filename, params, key) do
    patterns =
      params
      |> Params.get(key, __MODULE__)
      |> Settings.strings!(key)

    patterns != [] and
      (Paths.matches_any?(filename, patterns) or Paths.in_paths?(filename, patterns))
  end

  # --- walk ---

  defp step({:defmodule, _, _}, _, acc, _),
    do: %{acc | vars: MapSet.new(), attrs: MapSet.new()}

  defp step({form, _, [_ | _]}, _, acc, _) when form in @function_forms,
    do: %{acc | vars: MapSet.new()}

  defp step({:@, meta, [{tag, _, [arg]}]}, _, acc, %{tmp?: tmp?}) when tag in @tag_attrs do
    if tmp? and tmp_dir?(arg),
      do: report(acc, meta[:line], "@#{tag}", tmp_message(tag)),
      else: acc
  end

  defp step({:@, _, [{name, _, [rhs]}]}, env, acc, _) when is_atom(name) do
    update_taint(acc, :attrs, name, rhs, env)
  end

  defp step({:=, _, [{name, _, c}, rhs]}, env, acc, _) when is_atom(name) and is_atom(c) do
    update_taint(acc, :vars, name, rhs, env)
  end

  defp step({{:., _, [mod, fun]}, meta, args}, env, acc, %{write?: true})
       when is_atom(fun) and is_list(args) do
    with "File" <- Aliases.resolve(mod, env.aliases),
         {:ok, dest} <- destination(fun, args),
         origin when origin != :safe <- origin(dest, env, acc) do
      report(acc, meta[:line], "File.#{fun}", write_message(fun, origin))
    else
      _ -> acc
    end
  end

  defp step(_, _, acc, _), do: acc

  defp report(acc, line, trigger, message),
    do: %{acc | found: [{line, trigger, message} | acc.found]}

  defp update_taint(acc, key, name, rhs, env) do
    set = Map.fetch!(acc, key)

    updated =
      if origin(rhs, env, acc) == :cwd, do: MapSet.put(set, name), else: MapSet.delete(set, name)

    Map.put(acc, key, updated)
  end

  # --- tags ---

  defp tmp_dir?(:tmp_dir), do: true
  defp tmp_dir?(list) when is_list(list), do: Enum.any?(list, &tmp_dir_entry?/1)
  defp tmp_dir?(_), do: false

  defp tmp_dir_entry?(:tmp_dir), do: true
  defp tmp_dir_entry?({:tmp_dir, value}), do: is_binary(value) or value == true
  defp tmp_dir_entry?(_), do: false

  # --- writes ---

  defp destination(fun, [path | _]) when fun in @dest_first, do: {:ok, path}
  defp destination(fun, [_, dest | _]) when fun in @dest_second, do: {:ok, dest}

  defp destination(fun, [path | rest]) when fun in @moded do
    if Enum.any?(rest, &write_modes?/1), do: {:ok, path}, else: :error
  end

  defp destination(_, _), do: :error

  defp write_modes?(modes) when is_list(modes), do: Enum.any?(modes, &(&1 in @write_modes))
  defp write_modes?(_), do: false

  # :relative (project-relative literal), :cwd (derived from the cwd), :safe (absolute or unknown)
  defp origin(path, _, _) when is_binary(path), do: literal_origin(path)

  defp origin({:<<>>, _, [head | _]}, env, acc),
    do: if(is_binary(head), do: literal_origin(head), else: origin(interpolated(head), env, acc))

  defp origin({{:., _, [mod, cwd]}, _, []}, env, _) when cwd in [:cwd, :cwd!] do
    if Aliases.resolve(mod, env.aliases) == "File", do: :cwd, else: :safe
  end

  defp origin({{:., _, [mod, :join]}, _, [parts]}, env, acc) when is_list(parts) do
    if Aliases.resolve(mod, env.aliases) == "Path", do: first_origin(parts, env, acc), else: :safe
  end

  defp origin({{:., _, [mod, fun]}, _, [first | rest]}, env, acc)
       when fun in [:join, :expand, :absname] do
    cond do
      Aliases.resolve(mod, env.aliases) != "Path" -> :safe
      fun == :join -> origin(first, env, acc)
      rest == [] -> origin(first, env, acc)
      origin(first, env, acc) == :safe -> :safe
      true -> origin(hd(rest), env, acc)
    end
  end

  defp origin({:@, _, [{name, _, c}]}, _, acc) when is_atom(name) and is_atom(c),
    do: if(MapSet.member?(acc.attrs, name), do: :cwd, else: :safe)

  defp origin({name, _, c}, _, acc) when is_atom(name) and is_atom(c),
    do: if(MapSet.member?(acc.vars, name), do: :cwd, else: :safe)

  defp origin(_, _, _), do: :safe

  defp first_origin([first | _], env, acc), do: origin(first, env, acc)
  defp first_origin([], _, _), do: :safe

  defp interpolated({:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, _]}), do: expr
  defp interpolated(other), do: other

  defp literal_origin(""), do: :safe

  defp literal_origin(path) do
    if String.starts_with?(path, ["/", "~", "\\"]) or path =~ ~r/^[A-Za-z]:[\/\\]/,
      do: :safe,
      else: :relative
  end

  # --- messages ---

  defp tmp_message(tag) do
    "`@#{tag} :tmp_dir` makes ExUnit create `tmp/<Module>/<test>` under the working directory, " <>
      "which pollutes the project tree. Build a unique directory under `System.tmp_dir!/0` and remove " <>
      "it in `on_exit/1`, or list this file in `allow_tmp_dir_paths`."
  end

  defp write_message(fun, origin) do
    where =
      if origin == :cwd,
        do: "a path derived from `File.cwd!/0`",
        else: "a project-relative path"

    "`File.#{fun}` touches #{where}, which pollutes the project tree. Use a unique directory " <>
      "under `System.tmp_dir!/0` (removed in `on_exit/1`), or list this file in `allow_write_paths`."
  end
end
