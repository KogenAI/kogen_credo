defmodule KogenCredo.Diff.Json do
  @moduledoc false
  # Minimal deterministic JSON encoder (the package declares no JSON dependency).

  @spec encode(term()) :: String.t()
  def encode(term) do
    term
    |> to_iodata()
    |> IO.iodata_to_binary()
  end

  defp to_iodata(nil), do: "null"
  defp to_iodata(true), do: "true"
  defp to_iodata(false), do: "false"
  defp to_iodata(n) when is_integer(n) or is_float(n), do: to_string(n)

  defp to_iodata(a) when is_atom(a) do
    a
    |> Atom.to_string()
    |> string()
  end

  defp to_iodata(s) when is_binary(s), do: string(s)

  defp to_iodata(list) when is_list(list),
    do: [
      "[",
      list
      |> Enum.map(&to_iodata/1)
      |> Enum.intersperse(","),
      "]"
    ]

  defp to_iodata(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [string(k), ":", to_iodata(v)] end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  defp to_iodata(other) do
    other
    |> inspect()
    |> string()
  end

  defp string(s) do
    text = if String.valid?(s), do: s, else: inspect(s)
    escaped = for <<c::utf8 <- text>>, into: "", do: escape(c)
    ["\"", escaped, "\""]
  end

  defp escape(?"), do: "\\\""
  defp escape(?\\), do: "\\\\"
  defp escape(?\n), do: "\\n"
  defp escape(?\r), do: "\\r"
  defp escape(?\t), do: "\\t"
  defp escape(c) when c < 0x20, do: "\\u" <> hex(c, 4)
  defp escape(c), do: <<c::utf8>>

  defp hex(code, width) do
    code
    |> Integer.to_string(16)
    |> String.pad_leading(width, "0")
  end
end
