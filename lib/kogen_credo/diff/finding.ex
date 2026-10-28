defmodule KogenCredo.Diff.Finding do
  @moduledoc """
  One rule hit, with text, JSON and GitHub workflow-command renderings.

  Severity is `:advisory` (printed, never fails by default) or `:error`.

  GitHub escaping follows the workflow-command rules: in the message `%`, `\\r` and `\\n` are
  escaped; in properties (`file`, `title`) `:` and `,` are escaped as well.
  """

  alias KogenCredo.Diff.Change
  alias KogenCredo.Diff.Json

  @enforce_keys [:rule, :file, :line, :function, :message]
  defstruct [:rule, :file, :line, :function, :message, severity: :advisory]

  @type severity :: :advisory | :error
  @type t :: %__MODULE__{}

  @doc "Builds a finding anchored at the changed function."
  @spec for_change(String.t(), Change.t(), String.t()) :: t()
  def for_change(rule, %Change{} = change, message) do
    %__MODULE__{
      rule: rule,
      file: change.file,
      line: change.line,
      function: Change.label(change),
      message: message
    }
  end

  @doc "One-line text form."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = f),
    do: clean("#{f.file}:#{f.line} #{f.function} [#{f.rule}] (#{f.severity}) #{f.message}")

  @doc """
  Makes text safe to print as one line: control characters (newlines, escapes, NUL) become
  `\\xNN`, and surrounding whitespace is trimmed. CI log processors act on lines that start with
  `::`, so repository-controlled text (paths, parser messages, git stderr) must not be able to
  start a line of its own.
  """
  @spec clean(String.t()) :: String.t()
  def clean(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[\x00-\x1f\x7f]/, fn <<c>> -> "\\x" <> hex(c) end)
  end

  defp hex(code) do
    code
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
  end

  @doc "Map with string keys, ready for JSON."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = f) do
    %{
      "rule" => f.rule,
      "severity" => Atom.to_string(f.severity),
      "file" => f.file,
      "line" => f.line,
      "function" => f.function,
      "message" => f.message
    }
  end

  @doc "JSON object for one finding."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = f) do
    f
    |> to_map()
    |> Json.encode()
  end

  @doc "GitHub annotation line (`::warning file=...,line=...,title=...::message`)."
  @spec to_github(t()) :: String.t()
  def to_github(%__MODULE__{} = f) do
    level = if f.severity == :error, do: "error", else: "warning"

    github_line(
      level,
      f.file,
      f.line,
      "kogen.diff_check #{f.rule}",
      "#{f.function}: #{f.message}"
    )
  end

  @doc "Builds an annotation line from raw parts, escaping each part."
  @spec github_line(String.t(), String.t() | nil, integer() | nil, String.t(), String.t()) ::
          String.t()
  def github_line(level, file, line, title, message) do
    props =
      [file && "file=" <> escape_property(file), line && "line=#{line}"]
      |> Enum.filter(& &1)
      |> Kernel.++(["title=" <> escape_property(title)])
      |> Enum.join(",")

    "::#{level} #{props}::#{escape_message(message)}"
  end

  @doc false
  @spec escape_message(String.t()) :: String.t()
  def escape_message(text) do
    text
    |> String.replace("%", "%25")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
  end

  @doc false
  @spec escape_property(String.t()) :: String.t()
  def escape_property(text) do
    text
    |> escape_message()
    |> String.replace(":", "%3A")
    |> String.replace(",", "%2C")
  end
end
