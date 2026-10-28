defmodule KogenCredo.Check.Refactor.SizeLimits do
  @moduledoc """
  Hard ceilings on size: lines per file (`max_file_lines`, default 400), lines per
  `defmodule` (`max_module_lines`, default 400) and lines per `def`/`defp`/`defmacro`
  clause (`max_function_lines`, default 40).

  Lines are counted as the span from the first to the last line of the construct.
  Each clause of a multi-clause function counts separately. A keyword-style clause
  (`def f(x), do: ...`) has no `end`; its last line is the last line any of its
  expressions or closing brackets sits on. Set
  `count_blank_and_comment_lines: false` to count only lines with code.

  The body of a heredoc `~H` (HEEx) template is markup, not logic, so it is not counted
  toward a *function's* length (the `~H\"""` and closing `\"""` lines still are); the file
  and module counts stay raw. Set `count_template_lines: true` to count the markup too.

  ## Limitations

  Line counts are a proxy for complexity. Generated files, large data tables and
  schema modules legitimately exceed them: list those in `excluded_paths`. The last
  line of a keyword-style clause ends at its last token with line metadata, so a
  trailing multi-line string without code after it is not counted.
  """

  use Credo.Check,
    category: :refactor,
    base_priority: :low,
    param_defaults: [
      max_file_lines: 400,
      max_module_lines: 400,
      max_function_lines: 40,
      count_blank_and_comment_lines: true,
      count_template_lines: false,
      included_paths: ["lib/"],
      excluded_paths: []
    ],
    explanations: [
      check: """
      Split instead of growing. A module past a few hundred lines has more than one reason to
      change; a function past forty lines hides branches. Extract smaller functions or modules.
      """,
      params: [
        max_file_lines: "Maximum lines per file.",
        max_module_lines: "Maximum lines per module.",
        max_function_lines: "Maximum lines per function clause.",
        count_blank_and_comment_lines: "When false only lines with code are counted.",
        count_template_lines:
          "When true the body of heredoc `~H` templates counts toward function length.",
        included_paths: "Only files under these path prefixes are checked.",
        excluded_paths: "Files under these path prefixes are skipped."
      ]
    ]

  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Settings

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    included = Params.get(params, :included_paths, __MODULE__)
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Paths.in_scope?(filename, included, excluded), do: check(source_file, params), else: []
  end

  defp check(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    max_file =
      params
      |> Params.get(:max_file_lines, __MODULE__)
      |> Settings.integer!(:max_file_lines, 1)

    max_mod =
      params
      |> Params.get(:max_module_lines, __MODULE__)
      |> Settings.integer!(:max_module_lines, 1)

    max_fun =
      params
      |> Params.get(:max_function_lines, __MODULE__)
      |> Settings.integer!(:max_function_lines, 1)

    all? = Params.get(params, :count_blank_and_comment_lines, __MODULE__)
    templates? = Params.get(params, :count_template_lines, __MODULE__)

    raw_lines =
      source_file
      |> SourceFile.source()
      |> String.split("\n")

    lines = if List.last(raw_lines) == "", do: Enum.drop(raw_lines, -1), else: raw_lines
    counter = line_counter(lines, all?)
    total = counter.(1, length(lines))

    file_issues =
      if total > max_file do
        [
          format_issue(issue_meta,
            message: "File has #{total} lines (max #{max_file}). Split it into smaller modules.",
            line_no: 1,
            trigger: Path.basename(source_file.filename)
          )
        ]
      else
        []
      end

    file_issues ++
      Credo.Code.prewalk(
        source_file,
        &walk(&1, &2, issue_meta, {counter, templates?}, max_mod, max_fun)
      )
  end

  defp line_counter(_, true), do: fn from, to -> max(to - from + 1, 0) end

  defp line_counter(lines, false) do
    code? =
      Enum.map(lines, fn l ->
        t = String.trim(l)
        t != "" and not String.starts_with?(t, "#")
      end)

    prefix = Enum.scan(code?, 0, fn c, acc -> if c, do: acc + 1, else: acc end)
    tuple = List.to_tuple([0 | prefix])
    fn from, to -> elem(tuple, min(to, tuple_size(tuple) - 1)) - elem(tuple, from - 1) end
  end

  defp walk(
         {:defmodule, meta, [name | _]} = ast,
         acc,
         issue_meta,
         {counter, _},
         max_mod,
         _
       ) do
    {ast,
     span_issue(
       acc,
       issue_meta,
       meta,
       ast,
       counter,
       {"module #{Macro.to_string(name)}", Macro.to_string(name)},
       max_mod
     )}
  end

  defp walk(
         {kind, meta, [head | _]} = ast,
         acc,
         issue_meta,
         {counter, templates?},
         _,
         max_fun
       )
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    counter = if templates?, do: counter, else: without_templates(counter, ast)

    {ast,
     span_issue(
       acc,
       issue_meta,
       meta,
       ast,
       counter,
       {"#{kind} #{fun_name(head)}", fun_atom(head)},
       max_fun
     )}
  end

  defp walk(ast, acc, _, _, _, _), do: {ast, acc}

  # Counter that discounts the body lines of heredoc `~H` sigils inside `ast`.
  defp without_templates(counter, ast) do
    {_, bodies} = Macro.prewalk(ast, [], &collect_template/2)

    fn from, to ->
      discounted =
        for {first, last} <- bodies, first >= from, last <= to, reduce: 0 do
          sum -> sum + counter.(first, last)
        end

      counter.(from, to) - discounted
    end
  end

  defp collect_template({:sigil_H, meta, [{:<<>>, _, [text]} | _]} = node, acc)
       when is_binary(text),
       do: {node, template_body(meta, text) ++ acc}

  defp collect_template(node, acc), do: {node, acc}

  defp template_body(meta, text) do
    delimiter = meta[:delimiter] || ""

    newlines =
      text
      |> String.graphemes()
      |> Enum.count(&(&1 == "\n"))

    if String.starts_with?(delimiter, ~s(""")) and is_integer(meta[:line]) and newlines > 0,
      do: [{meta[:line] + 1, meta[:line] + newlines}],
      else: []
  end

  defp span_issue(acc, issue_meta, meta, ast, counter, {what, trigger}, max) do
    with line when is_integer(line) <- meta[:line],
         end_line when is_integer(end_line) <- end_line(meta, ast),
         span when span > max <- counter.(line, end_line) do
      [
        format_issue(issue_meta,
          message: "#{what} spans #{span} lines (max #{max}). Extract smaller functions/modules.",
          line_no: line,
          trigger: trigger
        )
        | acc
      ]
    else
      _ -> acc
    end
  end

  defp end_line(meta, ast) do
    get_in(meta, [:end, :line]) || last_line(ast)
  end

  defp last_line(ast) do
    {_, max} =
      Macro.prewalk(ast, 0, fn
        {_, meta, _} = node, max when is_list(meta) ->
          lines = [meta[:line], get_in(meta, [:closing, :line]), get_in(meta, [:end, :line])]
          {node, Enum.reduce(lines, max, &if(is_integer(&1) and &1 > &2, do: &1, else: &2))}

        node, max ->
          {node, max}
      end)

    max
  end

  defp fun_atom({:when, _, [head | _]}), do: fun_atom(head)
  defp fun_atom({name, _, _}) when is_atom(name), do: Atom.to_string(name)
  defp fun_atom(_), do: "def"

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, args}) when is_atom(name), do: "#{name}/#{length(List.wrap(args))}"
  defp fun_name(_), do: "?"
end
