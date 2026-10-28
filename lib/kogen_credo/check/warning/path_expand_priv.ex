defmodule KogenCredo.Check.Warning.PathExpandPriv do
  @moduledoc """
  Flags `priv/` paths resolved against the current working directory, which breaks
  in releases (where the cwd is not the project root):

    * `Path.expand("priv/...")` / `Path.absname("priv/...")` / `Path.wildcard("priv/...")` without a
      base directory;
    * `Path.join("priv", ...)` or `Path.join(["priv", ...])` (also `["priv" | rest]`);
    * with `check_file_calls` (default `true`): `File.read/read!/stream!/ls/ls!/exists?/dir?/regular?`
      with a literal `priv/...` path.

  Use `Application.app_dir(:my_app, "priv/...")` or `:code.priv_dir(:my_app)`.

  `Path.expand("priv/x", base)` with an explicit base, and paths built from
  `Application.app_dir/2`, are not reported. Mix tasks run from the project root, so
  `lib/mix/` is excluded by default.

  This check is an independent implementation of the idea popularised by ex_slop's
  check of the same purpose.

  ## Limitations

  Only literal `priv` prefixes are recognised (including the literal head of an
  interpolated string); a `priv` path assembled from variables is not seen.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/", "config/"],
      excluded_paths: ["lib/mix/"],
      check_file_calls: true,
      file_functions: [:read, :read!, :stream!, :ls, :ls!, :exists?, :dir?, :regular?]
    ],
    explanations: [
      check: """
      Relative `priv/...` paths depend on the working directory. They work under `mix` and fail in a
      release. Resolve them with `Application.app_dir(:my_app, "priv/...")` or `:code.priv_dir(:my_app)`.
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped (Mix tasks by default).",
        check_file_calls: "Also report `File.read/1`-style calls with a literal priv path.",
        file_functions: "`File` functions checked when `check_file_calls` is on."
      ]
    ]

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded) do
      issue_meta = IssueMeta.for(source_file, params)
      file_calls? = Params.get(params, :check_file_calls, __MODULE__)

      file_funs =
        params
        |> Params.get(:file_functions, __MODULE__)
        |> Settings.atoms!(:file_functions)

      source_file
      |> SourceFile.ast()
      |> Ast.expand_pipes()
      |> Scope.walk([], &collect_hit(&1, &2, &3, file_calls?, file_funs))
      |> Enum.reverse()
      |> Enum.map(&priv_issue(issue_meta, &1))
    else
      []
    end
  end

  defp collect_hit({{:., _, [mod_ast, fun]}, meta, args}, env, acc, file_calls?, file_funs)
       when is_atom(fun) and is_list(args) do
    mod = Aliases.resolve(mod_ast, env.aliases)

    if hit?(mod, fun, args, file_calls?, file_funs),
      do: [{meta[:line], "#{mod}.#{fun}"} | acc],
      else: acc
  end

  defp collect_hit(_, _, acc, _, _), do: acc

  defp priv_issue(issue_meta, {line, what}) do
    format_issue(issue_meta,
      message:
        "`#{what}` with a relative priv path depends on the working directory and breaks in releases. " <>
          "Use `Application.app_dir(:my_app, \"priv/...\")` or `:code.priv_dir(:my_app)`.",
      trigger: "priv",
      line_no: line
    )
  end

  defp hit?("Path", fun, [path], _, _) when fun in [:expand, :absname, :wildcard],
    do: priv?(path)

  defp hit?("Path", :join, [[first | _]], _, _) do
    first
    |> cons_head()
    |> priv?()
  end

  defp hit?("Path", :join, [first | _], _, _), do: priv?(first)
  defp hit?("File", fun, [path | _], true, funs), do: fun in funs and priv?(path)
  defp hit?(_, _, _, _, _), do: false

  defp cons_head({:|, _, [head, _]}), do: head
  defp cons_head(other), do: other

  defp priv?(path) do
    case literal_head(path) do
      nil ->
        false

      head ->
        head == "priv" or String.starts_with?(head, ["priv/", "./priv/"]) or head == "./priv"
    end
  end

  defp literal_head(s) when is_binary(s), do: s
  defp literal_head({:<<>>, _, [head | _]}) when is_binary(head), do: head
  defp literal_head(_), do: nil
end
