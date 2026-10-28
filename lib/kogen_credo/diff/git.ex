defmodule KogenCredo.Diff.Git do
  @moduledoc """
  Read-only git access for the diff runner.

  Git is always started with `System.cmd/3` and an argument list, never through a shell. User
  input is validated before it reaches git: revision strings may only contain
  `[A-Za-z0-9_./@{}~^+-]`, must not start with `-`, and must not contain `..` inside a side;
  paths must be relative, free of control characters, `..` segments and leading `-` or `:`.
  Pathspecs are interpreted relative to the `--repo` directory: when `--repo` is a subdirectory
  of the work tree, `lib/` means `<subdirectory>/lib/` (the prefix comes from
  `git rev-parse --show-prefix`) and is then anchored at the repository top (`:(top)`).
  Reported file names are always rooted at the repository top (`--no-relative` is forced, so a
  repository-local `diff.relative` setting cannot change them). A path that matches nothing in
  either the base or the head tree is an error, never an empty success.
  Inherited git routing and pathspec variables (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`,
  `GIT_CONFIG_PARAMETERS`, `GIT_LITERAL_PATHSPECS`, ...) are removed from git's environment, so
  `--repo` is always the repository that is read, also when run from a git hook.
  Revisions are resolved to full object ids first and only those ids are used afterwards.
  Only read-only `rev-parse`, `merge-base`, `diff`, `hash-object` and `cat-file` commands run;
  no Git objects, refs or repository files are written. Temporary files are cleaned up.
  Any git failure is returned as `{:error, message}`; control characters in git's messages are
  escaped so repository content cannot forge extra output lines.

  Standard output and standard error are captured separately (through `sh` when it exists), so a
  git warning can never corrupt a `-z` listing or a file's contents. A revision name that is
  both a branch and a tag resolves by git's own precedence; pass a full ref or a SHA to be
  explicit.
  """

  alias KogenCredo.Diff.Finding

  @type range :: {:two_dot | :three_dot, String.t(), String.t()}
  @type entry :: %{
          status: :added | :modified | :deleted | :renamed,
          base_path: String.t() | nil,
          head_path: String.t() | nil
        }

  # Variables that redirect git to another repository/object store/config or change how
  # pathspecs are parsed. `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` are handled
  # in `git_env/0`.
  @routing_env ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_QUARANTINE_PATH
    GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_REPLACE_REF_BASE GIT_NO_REPLACE_OBJECTS
    GIT_GRAFT_FILE GIT_SHALLOW_FILE GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_LITERAL_PATHSPECS
    GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS)

  @rev_chars ~r/\A[A-Za-z0-9_.\/@{}~^+-]+\z/

  @doc "Parses and validates `A..B` or `A...B`."
  @spec parse_range(term()) :: {:ok, range()} | {:error, String.t()}
  def parse_range(range) when is_binary(range) do
    {kind, parts} = split_range(range)

    with [a, b] <- parts,
         :ok <- validate_rev(a, range),
         :ok <- validate_rev(b, range) do
      {:ok, {kind, a, b}}
    else
      {:error, _} = error -> error
      _ -> {:error, "range must look like BASE..HEAD or BASE...HEAD, got #{inspect(range)}"}
    end
  end

  def parse_range(other), do: {:error, "range must be a string, got #{inspect(other)}"}

  defp split_range(range) do
    case String.split(range, "...", parts: 2) do
      [a, b] -> {:three_dot, [a, b]}
      [_] -> {:two_dot, String.split(range, "..", parts: 2)}
    end
  end

  defp validate_rev(rev, range) do
    cond do
      rev == "" ->
        {:error, "range #{inspect(range)} has an empty side"}

      not Regex.match?(@rev_chars, rev) ->
        {:error, "range #{inspect(range)} has an invalid revision #{inspect(rev)}"}

      String.starts_with?(rev, ["-", "."]) or String.ends_with?(rev, ".") or
          String.contains?(rev, "..") ->
        {:error, "range #{inspect(range)} has an invalid revision #{inspect(rev)}"}

      true ->
        :ok
    end
  end

  @doc "Checks that the repository path is an existing directory."
  @spec validate_repo(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_repo(repo) when is_binary(repo) do
    cond do
      repo == "" or String.contains?(repo, <<0>>) -> {:error, "invalid --repo #{inspect(repo)}"}
      not File.dir?(repo) -> {:error, "--repo #{inspect(repo)} is not a directory"}
      true -> {:ok, repo}
    end
  end

  def validate_repo(other), do: {:error, "invalid --repo #{inspect(other)}"}

  @doc "Validates repo-relative path filters."
  @spec validate_paths([term()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate_paths(paths) do
    case Enum.find(paths, &(not valid_path?(&1))) do
      nil -> {:ok, paths}
      path -> {:error, "invalid --path #{inspect(path)}"}
    end
  end

  defp valid_path?(path) when is_binary(path) do
    path != "" and not String.starts_with?(path, ["/", "-", ":"]) and
      not Regex.match?(~r/[\x00-\x1f\x7f]/, path) and
      ".." not in Path.split(path)
  end

  defp valid_path?(_), do: false

  @doc """
  Resolves a parsed range to `{base_sha, head_sha}`. Three-dot ranges use the merge base.
  """
  @spec resolve(String.t(), range()) :: {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def resolve(repo, {kind, a, b}) do
    with {:ok, a_sha} <- rev_parse(repo, a),
         {:ok, b_sha} <- rev_parse(repo, b) do
      resolve_kind(kind, repo, a_sha, b_sha)
    end
  end

  defp resolve_kind(:two_dot, _, a_sha, b_sha), do: {:ok, {a_sha, b_sha}}

  defp resolve_kind(:three_dot, repo, a_sha, b_sha) do
    with {:ok, out} <- git(repo, ["merge-base", a_sha, b_sha]),
         {:ok, base} <- sha(out) do
      {:ok, {base, b_sha}}
    end
  end

  defp rev_parse(repo, rev) do
    case git(repo, ["rev-parse", "--verify", "--quiet", rev <> "^{commit}"]) do
      {:ok, out} -> sha(out)
      {:error, message} -> {:error, "revision #{inspect(rev)} is not a commit: #{message}"}
    end
  end

  defp sha(out) do
    sha = String.trim(out)

    if Regex.match?(~r/\A[0-9a-f]{40,64}\z/, sha),
      do: {:ok, sha},
      else: {:error, "unexpected git output #{inspect(String.slice(sha, 0, 200))}"}
  end

  @doc """
  Fails unless every path (relative to `repo`) matches at least one file in the base or the
  head tree, so a wrong default (subproject, umbrella root) cannot yield an empty success.
  """
  @spec check_paths(String.t(), String.t(), String.t(), [String.t()]) ::
          :ok | {:error, String.t()}
  def check_paths(repo, base, head, paths) do
    with {:ok, prefix} <- prefix(repo),
         {:ok, empty_out} <- empty_tree(repo),
         {:ok, empty} <- sha(empty_out) do
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        check_path(repo, {empty, base, head}, prefix, path)
      end)
    end
  end

  defp check_path(repo, {empty, base, head}, prefix, path) do
    spec = ":(top)" <> prefix <> path

    with {:ok, in_base} <- tree_matches?(repo, empty, base, spec),
         {:ok, in_head} <- tree_matches?(repo, empty, head, spec) do
      if in_base or in_head,
        do: {:cont, :ok},
        else: {:halt, {:error, unmatched_message(path, prefix)}}
    else
      {:error, _} = error -> {:halt, error}
    end
  end

  defp empty_tree(repo) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen_empty_tree_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)

        try do
          git(repo, ["hash-object", "-t", "tree", path])
        after
          File.rm(path)
        end

      {:error, reason} ->
        {:error, "could not create empty-tree input: #{:file.format_error(reason)}"}
    end
  end

  defp tree_matches?(repo, empty, commit, spec) do
    args = [
      "diff",
      "--name-only",
      "--no-renames",
      "-z",
      "--no-ext-diff",
      empty,
      commit,
      "--",
      spec
    ]

    with {:ok, out} <- git(repo, args), do: {:ok, out != ""}
  end

  defp unmatched_message(path, prefix) do
    searched = if prefix == "", do: "the repository root", else: inspect(prefix)

    "--path #{inspect(path)} matches no file in either the base or the head tree " <>
      "(paths are relative to --repo, searched under #{searched}). " <>
      "Point --repo at the project or pass --path, e.g. --path apps/my_app/lib/ in an umbrella"
  end

  defp prefix(repo) do
    with {:ok, out} <- git(repo, ["rev-parse", "--show-prefix"]) do
      {:ok, String.replace_suffix(out, "\n", "")}
    end
  end

  @doc "Changed `.ex` files between two commits, with renames detected."
  @spec changed_files(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, [entry()]} | {:error, String.t()}
  def changed_files(repo, base, head, paths) do
    with {:ok, prefix} <- prefix(repo),
         args =
           [
             "diff",
             "--name-status",
             "--no-relative",
             "-M",
             "-z",
             "--no-ext-diff",
             "--no-textconv",
             base,
             head,
             "--"
           ] ++ Enum.map(paths, &(":(top)" <> prefix <> &1)),
         {:ok, out} <- git(repo, args),
         {:ok, entries} <- parse_name_status(out) do
      {:ok, Enum.flat_map(entries, &elixir_entry/1)}
    end
  end

  # Only `.ex` paths are analysed. A rename across the `.ex` boundary is an add or a delete as far
  # as Elixir source is concerned (the other side is not Elixir and must not be parsed as such).
  defp elixir_entry(%{status: :renamed, base_path: base, head_path: head} = entry) do
    case {elixir_path?(base), elixir_path?(head)} do
      {true, true} -> [entry]
      {false, true} -> [%{status: :added, base_path: nil, head_path: head}]
      {true, false} -> [%{status: :deleted, base_path: base, head_path: nil}]
      {false, false} -> []
    end
  end

  defp elixir_entry(%{head_path: nil, base_path: path} = entry),
    do: if(elixir_path?(path), do: [entry], else: [])

  defp elixir_entry(%{head_path: path} = entry),
    do: if(elixir_path?(path), do: [entry], else: [])

  defp elixir_path?(path), do: String.ends_with?(path, ".ex")

  @doc false
  @spec parse_name_status(String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse_name_status(out) do
    out
    |> String.split(<<0>>, trim: true)
    |> parse_tokens([])
  end

  defp parse_tokens([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_tokens(["A", path | rest], acc),
    do: parse_tokens(rest, [%{status: :added, base_path: nil, head_path: path} | acc])

  defp parse_tokens([status, path | rest], acc) when status in ["M", "T"],
    do: parse_tokens(rest, [%{status: :modified, base_path: path, head_path: path} | acc])

  defp parse_tokens(["D", path | rest], acc),
    do: parse_tokens(rest, [%{status: :deleted, base_path: path, head_path: nil} | acc])

  defp parse_tokens(["R" <> _, old, new | rest], acc),
    do: parse_tokens(rest, [%{status: :renamed, base_path: old, head_path: new} | acc])

  defp parse_tokens(["C" <> _, _, new | rest], acc),
    do: parse_tokens(rest, [%{status: :added, base_path: nil, head_path: new} | acc])

  defp parse_tokens(tokens, _),
    do: {:error, "unexpected git diff output near #{inspect(Enum.take(tokens, 2))}"}

  @doc "File contents at a commit."
  @spec show(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def show(repo, sha, path), do: git(repo, ["cat-file", "blob", "#{sha}:#{path}"])

  defp git(repo, args) do
    case System.find_executable("git") do
      nil -> {:error, "git executable not found"}
      git -> run(git, ["-C", repo | args], hd(args))
    end
  rescue
    e in ErlangError -> {:error, "could not run git: #{Exception.message(e)}"}
  end

  # stdout is returned alone; stderr goes to a file (read only for the error message).
  defp run(git, args, subcommand) do
    case System.find_executable("sh") do
      nil ->
        result = System.cmd(git, args, env: git_env())
        finish(result, "", subcommand)

      sh ->
        err =
          Path.join(
            System.tmp_dir!(),
            "kogen_git_#{System.pid()}_#{System.unique_integer([:positive])}.err"
          )

        try do
          result =
            System.cmd(sh, ["-c", ~S(exec "$@" 2>"$KOGEN_GIT_STDERR"), "sh", git | args],
              env: [{"KOGEN_GIT_STDERR", err} | git_env()]
            )

          stderr =
            err
            |> File.read()
            |> elem_or("")

          finish(result, stderr, subcommand)
        after
          File.rm(err)
        end
    end
  end

  # Unsets inherited variables that would redirect git away from `--repo`.
  defp git_env do
    numbered =
      for {name, _} <- System.get_env(),
          String.match?(name, ~r/\AGIT_CONFIG_(KEY|VALUE)_\d+\z/),
          do: name

    for name <- @routing_env ++ numbered, do: {name, nil}
  end

  defp elem_or({:ok, text}, _), do: text
  defp elem_or(_, default), do: default

  defp finish({out, 0}, _, _), do: {:ok, out}

  defp finish({out, code}, stderr, subcommand) do
    detail = if String.trim(stderr) == "", do: out, else: stderr
    excerpt = String.slice(detail, 0, 500)
    {:error, "git #{subcommand} failed (exit #{code}): #{Finding.clean(excerpt)}"}
  end
end
