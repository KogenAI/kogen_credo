defmodule KogenCredo.Check.Warning.StubBody do
  @moduledoc """
  Flags function bodies that compile but are placeholders. Inside `def`/`defp`/
  `defmacro`, the value returned from a *tail position* (the last expression,
  including branches of `if`/`case`/`cond`/`with`/`try`) is reported when it is:

    * a stub atom (`:not_implemented`, `:unimplemented`, `:not_yet_implemented`;
      configurable via `stub_atoms`) or `{:error, stub_atom}`;
    * a `raise`/`throw`/`exit` whose message matches `stub_pattern`
      (default: "not implemented", "unimplemented", "TODO", "stub", "placeholder",
      "not supported yet");
    * a `raise` of an exception module named in `stub_exceptions`
      (default `NotImplementedError`, `UnimplementedError`).

  Comments (`# TODO`) are not inspected; Credo's `Design.TagTODO` covers them.

  ## Limitations

  Only tail positions are inspected. Calls report their own line; a bare atom is placed at
  its `->` clause (or the function head when it ends a plain body). A stub raise followed by more code is missed
  and a deliberate "feature not supported" error whose text matches the pattern is a
  false positive. Tune `stub_pattern`/`stub_atoms` for your code base.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      included_paths: ["lib/"],
      excluded_paths: [],
      stub_atoms: [:not_implemented, :unimplemented, :not_yet_implemented],
      stub_exceptions: [NotImplementedError, UnimplementedError],
      stub_pattern:
        ~r/\b(not (yet )?implemented|unimplemented|todo|stub(bed)?|placeholder|not supported yet)\b/i
    ],
    explanations: [
      check: """
      A function that returns `:not_implemented` or raises "TODO" passes compilation and type
      checks while doing nothing. Implement the behaviour now, or leave the function out so the
      missing capability is a compile-time error rather than a runtime surprise.
      """,
      params: [
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped.",
        stub_atoms: "Atoms that mark a placeholder return value.",
        stub_exceptions: "Exception modules that mark a placeholder raise.",
        stub_pattern: "Regex matched against raise/throw/exit messages."
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

      cfg = settings(params)

      source_file
      |> SourceFile.ast()
      |> Scope.walk([], &collect_stubs(&1, &2, &3, cfg))
      |> Enum.map(fn {node, what, hint} -> issue(issue_meta, node, what, hint) end)
      |> Enum.sort_by(& &1.line_no)
    else
      []
    end
  end

  defp settings(params) do
    %{
      atoms:
        params
        |> Params.get(:stub_atoms, __MODULE__)
        |> Settings.atoms!(:stub_atoms),
      exceptions:
        params
        |> Params.get(:stub_exceptions, __MODULE__)
        |> Settings.modules!(:stub_exceptions),
      pattern: pattern(Params.get(params, :stub_pattern, __MODULE__))
    }
  end

  defp collect_stubs({kind, dmeta, [_, kw]}, %{aliases: aliases}, acc, cfg)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(kw) do
    for(
      b <- [Keyword.get(kw, :do) | rescue_bodies(kw)],
      b != nil,
      {tail, hint} <- tails(b),
      stub = stub(tail, cfg, aliases),
      do: {tail, stub, hint || dmeta[:line]}
    ) ++ acc
  end

  defp collect_stubs(_, _, acc, _), do: acc

  defp rescue_bodies(kw), do: for({:rescue, cl} <- kw, {:->, _, [_, b]} <- List.wrap(cl), do: b)

  defp pattern(%Regex{} = regex), do: regex
  defp pattern(other), do: Settings.raise_bad(:stub_pattern, other, "a Regex")

  # Expressions whose value becomes the function's result, each with the best line hint:
  # the line of the enclosing `->` clause (atoms and tuples carry no line of their own).
  defp tails(node, hint \\ nil)

  defp tails({:__block__, _, [_ | _] = xs}, hint) do
    xs
    |> List.last()
    |> tails(hint)
  end

  defp tails({:if, _, [_, kw]}, hint) when is_list(kw), do: branch_tails(kw, hint)
  defp tails({:unless, _, [_, kw]}, hint) when is_list(kw), do: branch_tails(kw, hint)
  defp tails({:case, _, [_, kw]}, hint) when is_list(kw), do: branch_tails(kw, hint)
  defp tails({:cond, _, [kw]}, hint) when is_list(kw), do: branch_tails(kw, hint)

  defp tails({:with, _, args}, hint) when is_list(args),
    do: if(is_list(List.last(args)), do: branch_tails(List.last(args), hint), else: [])

  defp tails({:try, _, [kw]}, hint) when is_list(kw), do: branch_tails(kw, hint)
  defp tails(other, hint), do: [{other, hint}]

  defp branch_tails(kw, hint) do
    for {key, v} <- kw,
        key in [:do, :else, :rescue, :catch],
        tail <- clause_tails(v, hint),
        do: tail
  end

  defp clause_tails(clauses, hint) when is_list(clauses),
    do: for({:->, meta, [_, b]} <- clauses, t <- tails(b, meta[:line] || hint), do: t)

  defp clause_tails(body, hint), do: tails(body, hint)

  defp stub(atom, cfg, _) when is_atom(atom), do: if(atom in cfg.atoms, do: inspect(atom))

  defp stub({:error, atom}, cfg, _) when is_atom(atom),
    do: if(atom in cfg.atoms, do: "{:error, #{inspect(atom)}}")

  defp stub({f, _, args}, cfg, aliases) when f in [:raise, :throw, :exit] and is_list(args) do
    cond do
      match?([{:__aliases__, _, _} | _], args) and resolved_head(args, aliases) in cfg.exceptions ->
        "raise #{resolved_head(args, aliases)}"

      placeholder_message?(args, cfg.pattern) ->
        "#{f} with a placeholder message"

      true ->
        nil
    end
  end

  defp stub(_, _, _), do: nil

  defp resolved_head([head | _], aliases), do: Aliases.resolve(head, aliases)

  defp placeholder_message?(args, pattern) do
    texts = message_texts(args)
    Enum.any?(texts, &Regex.match?(pattern, &1))
  end

  defp message_texts(args) do
    Enum.flat_map(args, fn
      kw when is_list(kw) -> for {_, v} <- kw, t = Ast.string_text(v), do: t
      other -> List.wrap(Ast.string_text(other))
    end)
  end

  defp issue(issue_meta, node, what, hint) do
    line =
      case node do
        {_, meta, _} when is_list(meta) -> meta[:line]
        _ -> nil
      end

    format_issue(issue_meta,
      message: "Placeholder body (#{what}). Implement the behaviour now or remove the function.",
      trigger: "def",
      line_no: line || hint || 1
    )
  end
end
