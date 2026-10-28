defmodule KogenCredo.Check.Warning.DomainReachTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.DomainReach

  @domains [
    [
      name: "billing",
      namespace: Shop.Billing,
      paths: ["lib/shop/billing", "test/billing"],
      allow: [Shop.Testkit]
    ],
    [name: "accounts", namespace: Shop.Accounts, paths: ["lib/shop/accounts"]]
  ]

  defp run(source, filename, params \\ []) do
    params = Keyword.merge([domains: @domains, shared: [Shop.Contracts]], params)

    source
    |> to_source_file(filename)
    |> run_check(DomainReach, params)
  end

  describe "reach detection" do
    test "alias of another domain's module" do
      source = "defmodule Shop.Billing.Invoice do\n  alias Shop.Accounts.User\nend\n"
      [issue] = run(source, "lib/shop/billing/invoice.ex")
      assert issue.message =~ "Domain `billing` references Shop.Accounts.User (domain `accounts`)"
      assert issue.line_no == 2
    end

    test "remote call and struct reference" do
      source = """
      defmodule Shop.Billing.Invoice do
        def f(id), do: Shop.Accounts.fetch(id)
        def g, do: %Shop.Accounts.User{}
      end
      """

      assert [_, _] = run(source, "lib/shop/billing/invoice.ex")
    end

    test "multi-alias members are expanded" do
      source =
        "defmodule Shop.Billing.Invoice do\n  alias Shop.{Accounts.User, Billing.Line}\nend\n"

      assert [issue] = run(source, "lib/shop/billing/invoice.ex")
      assert issue.message =~ "Shop.Accounts.User"
    end

    test "test files mapped to a domain are checked" do
      source = "defmodule Shop.BillingTest do\n  alias Shop.Accounts.User\nend\n"
      assert [_] = run(source, "test/billing/invoice_test.exs")
    end
  end

  describe "allowed references" do
    test "own namespace, shared contracts, allow list and third-party modules" do
      source = """
      defmodule Shop.Billing.Invoice do
        alias Shop.Billing.Line
        alias Shop.Contracts.Money
        alias Shop.Testkit
        def f, do: Enum.map([], &Jason.encode!/1)
      end
      """

      source
      |> run("lib/shop/billing/invoice.ex")
      |> refute_issues()
    end

    test "a module name that merely shares a prefix is not the domain" do
      source = "defmodule Shop.Billing.Invoice do\n  alias Shop.AccountsPayable.Row\nend\n"

      source
      |> run("lib/shop/billing/invoice.ex")
      |> refute_issues()
    end

    test "defmodule heads are not references" do
      "defmodule Shop.Accounts.User do\nend\n"
      |> run("lib/shop/billing/user.ex")
      |> refute_issues()
    end

    test "files outside every domain are ignored" do
      source = "defmodule Shop.Web do\n  alias Shop.Accounts.User\nend\n"

      source
      |> run("lib/shop/web/page.ex")
      |> refute_issues()
    end

    test "directory prefixes respect segment boundaries" do
      source = "defmodule X do\n  alias Shop.Accounts.User\nend\n"

      source
      |> run("lib/shop/billing_extras/x.ex")
      |> refute_issues()
    end
  end

  describe "unowned root modules" do
    @source "defmodule Shop.Billing.Invoice do\n  alias Shop.Repo\nend\n"

    test "not reported by default" do
      @source
      |> run("lib/shop/billing/invoice.ex")
      |> refute_issues()
    end

    test "reported with flag_unowned_root" do
      assert [issue] =
               run(@source, "lib/shop/billing/invoice.ex",
                 root_namespace: Shop,
                 flag_unowned_root: true
               )

      assert issue.message =~ "unowned module under Shop"
    end
  end

  describe "configuration" do
    test "disabled without domains" do
      source = "defmodule Shop.Billing.Invoice do\n  alias Shop.Accounts.User\nend\n"

      source
      |> run("lib/shop/billing/invoice.ex", domains: [])
      |> refute_issues()
    end

    test "malformed domain raises" do
      assert_raise ArgumentError, ~r/needs :name/, fn ->
        "defmodule A do\nend\n"
        |> to_source_file("lib/a.ex")
        |> DomainReach.run(domains: [[name: "x"]])
      end
    end
  end
end
