defmodule KogenCredo.Check.Warning.DomainReach do
  @moduledoc """
  Keeps domains from reaching into each other. Configure `domains`; without it the
  check does nothing.

      {KogenCredo.Check.Warning.DomainReach,
       domains: [
         [name: "billing", namespace: MyApp.Billing,
          paths: ["lib/my_app/billing", "test/billing"], allow: [MyApp.Testkit]],
         [name: "accounts", namespace: MyApp.Accounts, paths: ["lib/my_app/accounts"]]
       ],
       shared: [MyApp.Contracts]}

  A file under a domain's `paths` may reference its own `namespace`, any `shared`
  module, the domain's `allow` modules and anything outside every configured
  namespace. A reference (alias, call, struct, multi-alias member) to another
  configured domain's namespace is reported. With `root_namespace: MyApp` and
  `flag_unowned_root: true`, references to *unowned* modules under the root (e.g.
  `MyApp.Repo`) are reported as well.

  The module name in `defmodule` heads is not a reference. This check is syntactic
  (Boundary and xref remain the compile-time authority) but also covers files, such as tests,
  that compile-time tools skip.

  ## Limitations

  Aliased short names (`Invoice` after `alias MyApp.Billing.Invoice`) are caught at the
  `alias` line, not at each use; modules referenced through `__MODULE__`, variables or
  strings are invisible. A malformed domain entry raises `ArgumentError`.
  """

  use Credo.Check,
    category: :warning,
    base_priority: :low,
    param_defaults: [
      domains: [],
      shared: [],
      root_namespace: nil,
      flag_unowned_root: false
    ],
    explanations: [
      check: """
      A domain should depend on shared contracts, not on the internals of another domain. Configure
      each domain's `namespace` and `paths`; references from one domain's files to another's
      namespace are reported. Reach other domains through a contract/port or an event.
      """,
      params: [
        domains: "List of `[name:, namespace:, paths:, allow: []]`. Empty disables the check.",
        shared: "Modules (and their children) every domain may reference.",
        root_namespace: "Application root namespace, used only with `flag_unowned_root`.",
        flag_unowned_root: "Also report references to unowned modules under `root_namespace`."
      ]
    ]

  alias KogenCredo.CoreSupport.Aliases
  alias KogenCredo.CoreSupport.Ast
  alias KogenCredo.CoreSupport.Paths
  alias KogenCredo.CoreSupport.Scope
  alias KogenCredo.CoreSupport.Settings

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    domains =
      params
      |> Params.get(:domains, __MODULE__)
      |> domains!()

    case Enum.find(domains, &Paths.in_paths?(filename, &1.paths)) do
      nil -> []
      own -> reach_issues(source_file, params, own, domains)
    end
  end

  defp reach_issues(source_file, params, own, domains) do
    issue_meta = IssueMeta.for(source_file, params)
    {shared, root, unowned?} = reach_settings(params)
    allowed = [own.namespace | shared ++ own.allow]

    source_file
    |> SourceFile.ast()
    |> references()
    |> Enum.flat_map(&classify(&1, own, domains, allowed, {root, unowned?}))
    |> Enum.uniq_by(fn {line, mod, _} -> {line, mod} end)
    |> Enum.map(&reach_issue(issue_meta, own, shared, &1))
    |> Enum.sort_by(& &1.line_no)
  end

  defp reach_settings(params) do
    shared =
      params
      |> Params.get(:shared, __MODULE__)
      |> Settings.modules!(:shared)

    root = root_namespace(Params.get(params, :root_namespace, __MODULE__))
    unowned? = Params.get(params, :flag_unowned_root, __MODULE__) and root != nil
    {shared, root, unowned?}
  end

  defp root_namespace(nil), do: nil

  defp root_namespace(root) when is_atom(root), do: Ast.atom_name(root)

  defp root_namespace(root), do: Settings.raise_bad(:root_namespace, root, "a module or nil")

  defp reach_issue(issue_meta, own, shared, {line, mod, why}) do
    format_issue(issue_meta,
      message:
        "Domain `#{own.name}` references #{mod} (#{why}). Depend on a shared contract/port " <>
          "(#{Ast.inspect_names(shared)}) or an event instead of another domain's internals.",
      trigger: mod,
      line_no: line
    )
  end

  defp domains!(domains) when is_list(domains), do: Enum.map(domains, &normalize/1)
  defp domains!(other), do: Settings.raise_bad(:domains, other, "a list of domain entries")

  defp normalize(domain) do
    Settings.known_keys!(domain, [:name, :namespace, :paths, :allow], "DomainReach domain")
    name = domain[:name]
    ns = domain[:namespace]
    paths = domain[:paths]

    unless is_binary(name) and is_atom(ns) and not is_nil(ns) and is_list(paths) and paths != [] do
      raise ArgumentError,
            "DomainReach domain needs :name (string), :namespace (module) and :paths (non-empty list), got: #{inspect(domain)}"
    end

    %{
      name: name,
      namespace: Ast.atom_name(ns),
      paths: Settings.strings!(paths, :paths),
      allow: Settings.modules!(domain[:allow] || [], :allow)
    }
  end

  defp classify({mod, line}, own, domains, allowed, {root, unowned?}) do
    cond do
      under_any?(mod, allowed) ->
        []

      other = Enum.find(domains, &(&1 != own and Ast.under_name?(mod, &1.namespace))) ->
        [{line, mod, "domain `#{other.name}`"}]

      unowned? and Ast.under_name?(mod, root) and mod != root ->
        [{line, mod, "unowned module under #{root}"}]

      true ->
        []
    end
  end

  defp under_any?(mod, list), do: Enum.any?(list, &Ast.under_name?(mod, &1))

  # Reference sites, resolved through the aliases in force there. A use of an alias bound
  # earlier (`Invoice` after `alias MyApp.Billing.Invoice`) is not repeated: its `alias`
  # line is the reference.
  defp references(ast) do
    ast
    |> Macro.prewalk(&skip_module_head/1)
    |> Scope.walk([], &collect_reference/3)
  end

  defp skip_module_head({:defmodule, meta, [{:__aliases__, nmeta, parts} | rest]}),
    do: {:defmodule, meta, [{:__aliases__, [{:kogen_skip, true} | nmeta], parts} | rest]}

  defp skip_module_head(node), do: node

  defp collect_reference({{:., _, [{:__aliases__, _, _} = base, :{}]}, meta, children}, env, acc)
       when is_list(children) do
    case Aliases.resolve(base, env.aliases) do
      nil -> acc
      base_mod -> multi_alias_references(children, base_mod, meta) ++ acc
    end
  end

  defp collect_reference({:alias, _, [{:__aliases__, ameta, _} = node | _]}, env, acc),
    do: add_reference(node, ameta, env, acc)

  defp collect_reference({:__aliases__, meta, [first | _]} = node, env, acc)
       when is_atom(first) do
    cond do
      Keyword.get(meta, :kogen_skip, false) -> acc
      Map.has_key?(env.aliases, first) -> acc
      true -> add_reference(node, meta, env, acc)
    end
  end

  defp collect_reference({:__aliases__, meta, _} = node, env, acc),
    do: add_reference(node, meta, env, acc)

  defp collect_reference(_, _, acc), do: acc

  defp multi_alias_references(children, base_mod, meta) do
    for {:__aliases__, _, [_ | _] = rest} <- children, Enum.all?(rest, &is_atom/1) do
      {Ast.join_name([base_mod | rest]), meta[:line]}
    end
  end

  defp add_reference(node, meta, env, acc) do
    case Aliases.resolve(node, env.aliases) do
      nil -> acc
      mod -> [{mod, meta[:line]} | acc]
    end
  end
end
