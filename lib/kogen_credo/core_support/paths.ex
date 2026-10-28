defmodule KogenCredo.CoreSupport.Paths do
  @moduledoc """
  Filename scoping helpers shared by the KogenCredo checks.

  Paths are matched on segment boundaries, so `"lib/app"` matches
  `lib/app.ex` and `lib/app/x.ex` but not `lib/app_web/x.ex`. A prefix also
  matches below a leading directory (`apps/web/lib/x.ex` matches `"lib/"`),
  so umbrella projects need no extra configuration.
  """

  @doc "Normalises separators and strips a leading `./`."
  @spec normalize(String.t()) :: String.t()
  def normalize(filename) do
    filename
    |> String.replace("\\", "/")
    |> String.replace_leading("./", "")
  end

  @doc "True when `filename` lies at or below one of the path prefixes."
  @spec in_paths?(String.t(), [String.t()]) :: boolean()
  def in_paths?(filename, prefixes) do
    prefixes = strings!(prefixes)
    filename = normalize(filename)

    Enum.any?(prefixes, fn prefix ->
      prefix =
        prefix
        |> normalize()
        |> String.trim_trailing("/")

      filename == prefix or String.starts_with?(filename, prefix <> "/") or
        String.contains?(filename, "/" <> prefix <> "/") or
        String.ends_with?(filename, "/" <> prefix)
    end)
  end

  @doc "True when the file is in `included` (empty means everywhere) and not in `excluded`."
  @spec in_scope?(String.t(), [String.t()], [String.t()]) :: boolean()
  def in_scope?(filename, included, excluded \\ []) do
    (included == [] or in_paths?(filename, included)) and not in_paths?(filename, excluded)
  end

  @doc """
  Matches `filename` against exact paths, path suffixes or `*`/`**` globs.

  A pattern without `*` matches the whole filename or a trailing path suffix.
  """
  @spec matches_any?(String.t(), [String.t()]) :: boolean()
  def matches_any?(filename, patterns) do
    patterns = strings!(patterns)
    filename = normalize(filename)
    Enum.any?(patterns, &matches?(filename, normalize(&1)))
  end

  defp strings!(list) do
    if is_list(list) and Enum.all?(list, &is_binary/1),
      do: list,
      else: raise(ArgumentError, "path settings must be a list of strings, got: #{inspect(list)}")
  end

  defp matches?(filename, pattern) do
    if String.contains?(pattern, "*") do
      regex = glob_regex(pattern)

      Regex.match?(regex, filename) or
        filename
        |> suffixes()
        |> Enum.any?(&Regex.match?(regex, &1))
    else
      filename == pattern or String.ends_with?(filename, "/" <> pattern)
    end
  end

  defp suffixes(filename) do
    parts = String.split(filename, "/")

    for n <- 1..max(length(parts) - 1, 1)//1,
        do:
          parts
          |> Enum.drop(n)
          |> Enum.join("/")
  end

  defp glob_regex(glob) do
    glob
    |> Regex.escape()
    |> String.replace("\\*\\*/", "(.*/)?")
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end
end
