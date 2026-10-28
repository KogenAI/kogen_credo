defmodule KogenCredo.Diff.RulesAdversarialTest.Src do
  @spec mod(String.t()) :: String.t()
  @spec mod(String.t(), String.t()) :: String.t()
  def mod(body, header \\ ""), do: "defmodule App.X do\n#{header}\n#{body}\nend\n"
end

defmodule KogenCredo.Diff.RulesAdversarialTest do
  use ExUnit.Case, async: true

  import KogenCredo.Diff.RulesAdversarialTest.Src

  alias KogenCredo.Diff

  alias KogenCredo.Diff.Rules.ChangesetWeakened
  alias KogenCredo.Diff.Rules.LostTransaction
  alias KogenCredo.Diff.Rules.NewRepoInLoop
  alias KogenCredo.Diff.Rules.NewSilentFallback
  alias KogenCredo.Diff.Rules.QueryLostLimit
  alias KogenCredo.Diff.Rules.QueryLostScope

  defp hits(rule, base, head, opts \\ []) do
    {:ok, changes} = Diff.changes("lib/app/x.ex", base, head)
    Diff.check(changes, [rule], opts)
  end

  describe "QueryLostScope counts each scope field independently" do
    test "losing user_id is not hidden by gaining another tenant_id comparison" do
      base =
        mod("""
        def list(user_id, tenant_id) do
          from(p in Post, where: p.user_id == ^user_id and p.tenant_id == ^tenant_id) |> Repo.all()
        end
        """)

      head =
        mod("""
        def list(_user_id, tenant_id) do
          from(p in Post, where: p.tenant_id == ^tenant_id, or_where: p.tenant_id == ^tenant_id)
          |> Repo.all()
        end
        """)

      assert [hit] = hits(QueryLostScope, base, head)
      assert hit.message =~ ":user_id (1 -> 0)"
      refute hit.message =~ ":tenant_id"
    end

    test "both fields lost are both named" do
      base =
        mod("""
        def list(u, t) do
          from(p in Post, where: p.user_id == ^u and p.tenant_id == ^t) |> Repo.all()
        end
        """)

      head = mod("def list(_u, _t), do: from(p in Post) |> Repo.all()")
      assert [hit] = hits(QueryLostScope, base, head)
      assert hit.message =~ ":user_id" and hit.message =~ ":tenant_id"
    end

    test "keyword and field/2 forms count; maps and structs do not" do
      base = mod("def a(id), do: Repo.get_by(Post, user_id: id)")

      head =
        mod("""
        def a(id) do
          _ = %{user_id: id}
          _ = %Post{user_id: id}
          Repo.get(Post, id)
        end
        """)

      assert [_] = hits(QueryLostScope, base, head)

      base2 =
        mod("def a(id), do: from(p in Post, where: field(p, :user_id) == ^id) |> Repo.all()")

      head2 = mod("def a(_id), do: from(p in Post) |> Repo.all()")
      assert [_] = hits(QueryLostScope, base2, head2)
    end

    test "scope extracted into a helper stays quiet; into a helper that is never called does not" do
      base = mod("def a(id), do: from(p in Post, where: p.user_id == ^id) |> Repo.all()")

      quiet =
        mod("""
        def a(id), do: Post |> scoped(id) |> Repo.all()
        defp scoped(q, id), do: from(p in q, where: p.user_id == ^id)
        """)

      loud =
        mod("""
        def a(_id), do: Post |> Repo.all()
        defp scoped(q, id), do: from(p in q, where: p.user_id == ^id)
        """)

      assert [] = hits(QueryLostScope, base, quiet)
      assert [_] = hits(QueryLostScope, base, loud)
    end

    test "a query dropped together with its scope is not a lost scope" do
      base =
        mod("""
        def a(id) do
          x = from(p in Post, where: p.user_id == ^id) |> Repo.all()
          y = from(c in Comment) |> Repo.all()
          {x, y}
        end
        """)

      head = mod("def a(_id), do: {[], from(c in Comment) |> Repo.all()}")
      assert [] = hits(QueryLostScope, base, head)
    end
  end

  describe "LostTransaction" do
    @tx_base mod("""
             def run(a, b) do
               Repo.transaction(fn ->
                 Repo.insert!(a)
                 Repo.update!(b)
               end)
             end
             """)

    test "flags a removed transaction with two writes remaining" do
      head =
        mod("""
        def run(a, b) do
          Repo.insert!(a)
          Repo.update!(b)
        end
        """)

      assert [hit] = hits(LostTransaction, @tx_base, head)
      assert hit.message =~ "2 writes"
    end

    test "quiet when the transaction moved to a helper, or one write remains" do
      moved =
        mod("""
        def run(a, b), do: wrap(a, b)
        defp wrap(a, b) do
          Repo.transaction(fn ->
            Repo.insert!(a)
            Repo.update!(b)
          end)
        end
        """)

      one =
        mod("""
        def run(a, _b), do: Repo.insert!(a)
        """)

      assert [] = hits(LostTransaction, @tx_base, moved)
      assert [] = hits(LostTransaction, @tx_base, one)
    end

    test "Repo aliases are resolved per side: an alias to another module is not a repo" do
      head =
        mod(
          """
          def run(a, b) do
            Repo.insert!(a)
            Repo.update!(b)
          end
          """,
          "alias Other.Thing, as: Repo"
        )

      # Repo is not a repository in the head, so no writes are seen there.
      assert [] = hits(LostTransaction, @tx_base, head)
    end

    test "an aliased repo (alias MyApp.Repo, as: DB) is a repo" do
      base =
        mod(
          "def run(a, b), do: DB.transaction(fn -> DB.insert!(a); DB.update!(b) end)",
          "alias MyApp.Repo, as: DB"
        )

      head =
        mod("def run(a, b) do\n DB.insert!(a)\n DB.update!(b)\nend", "alias MyApp.Repo, as: DB")

      assert [_] = hits(LostTransaction, base, head)
    end

    test "transact/2 counts as a transaction" do
      base =
        mod(
          "def run(a, b), do: Repo.transact(fn -> Repo.insert!(a); Repo.update!(b); {:ok, 1} end)"
        )

      head = mod("def run(a, b) do\n Repo.insert!(a)\n Repo.update!(b)\nend")
      assert [_] = hits(LostTransaction, base, head)
    end
  end

  describe "ChangesetWeakened" do
    @cs_base mod("""
             def changeset(user, attrs) do
               user
               |> cast(attrs, [:name, :email])
               |> validate_required([:name, :email])
               |> validate_length(:name, min: 2)
               |> unique_constraint(:email)
             end
             """)

    test "a field dropped from validate_required, a removed validator and constraint" do
      head =
        mod("""
        def changeset(user, attrs) do
          user
          |> cast(attrs, [:name, :email])
          |> validate_required([:name])
        end
        """)

      assert [hit] = hits(ChangesetWeakened, @cs_base, head)
      assert hit.message =~ "validate_required(:email)"
      assert hit.message =~ "validate_length(:name)"
      assert hit.message =~ "unique_constraint(:email)"
    end

    test "a sensitive field added to cast; configurable list" do
      head = String.replace(@cs_base, "[:name, :email])", "[:name, :email, :role])")
      assert [hit] = hits(ChangesetWeakened, @cs_base, head)
      assert hit.message =~ "added :role to cast"
      assert [] = hits(ChangesetWeakened, @cs_base, head, cast_sensitive_fields: [:is_root])

      head2 = String.replace(@cs_base, "[:name, :email])", "[:name, :email, :is_root])")
      assert [_] = hits(ChangesetWeakened, @cs_base, head2, cast_sensitive_fields: [:is_root])
    end

    test "validations moved into a same-module helper are not lost" do
      head =
        mod("""
        def changeset(user, attrs) do
          user |> cast(attrs, [:name, :email]) |> checks()
        end
        defp checks(cs) do
          cs
          |> validate_required([:name, :email])
          |> validate_length(:name, min: 2)
          |> unique_constraint(:email)
        end
        """)

      assert [] = hits(ChangesetWeakened, @cs_base, head)
    end

    test "adding validations or non-sensitive cast fields is quiet" do
      head = String.replace(@cs_base, "[:name, :email])", "[:name, :email, :bio])")
      unchanged_head = head <> ""
      assert [] = hits(ChangesetWeakened, @cs_base, unchanged_head)
    end
  end

  describe "NewRepoInLoop" do
    test "a new per-element query is flagged; a moved call site is not" do
      base = mod("def a(ids), do: Enum.map(ids, fn id -> Repo.get(User, id) end)")
      moved = mod("def a(ids) do\n\n  Enum.map(ids, fn id ->\n   Repo.get(User, id)\n end)\nend")

      worse =
        mod("def a(ids), do: Enum.map(ids, fn id -> {Repo.get(User, id), Repo.get(Org, id)} end)")

      assert [] = hits(NewRepoInLoop, base, moved)
      assert [_] = hits(NewRepoInLoop, base, worse)
    end

    test "a piped helper that queries, called per element, counts" do
      base = mod("def a(ids), do: Repo.all(from(u in User, where: u.id in ^ids))")

      head =
        mod("""
        def a(ids), do: Enum.map(ids, fn id -> id |> fetch() end)
        defp fetch(id), do: Repo.get(User, id)
        """)

      assert [_] = hits(NewRepoInLoop, base, head)
    end

    test "a same-named function of another arity that queries is not the helper called" do
      base = mod("def a(ids), do: Enum.map(ids, & &1)")

      head =
        mod("""
        def a(ids), do: Enum.map(ids, fn id -> fetch(id) end)
        defp fetch(id), do: id
        defp fetch(id, _other), do: Repo.get(User, id)
        """)

      assert [] = hits(NewRepoInLoop, base, head)
    end

    test "a query before the loop and the loop's collection are not per element" do
      base = mod("def a(ids), do: ids")

      head =
        mod("""
        def a(ids) do
          users = Repo.all(User)
          Enum.map(Repo.all(from(u in User)), fn u -> {u, users} end)
        end
        """)

      assert [] = hits(NewRepoInLoop, base, head)
    end
  end

  describe "NewSilentFallback" do
    test "a new `_ -> :ok` arm in case is flagged; a logged one is not" do
      base = mod("def a(x), do: case(x, do: (:a -> 1; :b -> 2))")

      silent =
        mod("""
        def a(x) do
          case x do
            :a -> 1
            _ -> :ok
          end
        end
        """)

      logged =
        mod("""
        def a(x) do
          case x do
            :a -> 1
            _ ->
              Logger.warning("unexpected")
              :ok
          end
        end
        """)

      assert [_] = hits(NewSilentFallback, base, silent)
      assert [] = hits(NewSilentFallback, base, logged)
    end

    test "a guarded or pattern-specific arm returning a literal is not a catch-all" do
      base = mod("def a(x), do: x")

      head =
        mod("""
        def a(x) do
          case x do
            {:error, :not_found} -> nil
            n when n > 1 -> nil
            :a -> []
          end
        end
        """)

      assert [] = hits(NewSilentFallback, base, head)
    end

    test "a rescue that swallows is flagged only when new" do
      base = mod("def a, do: try(do: 1, rescue: (_ -> nil))")
      same = mod("def a, do: try(do: 2, rescue: (_ -> nil))")

      more =
        mod("""
        def a do
          try do
            1
          rescue
            _ -> nil
          end
          try do
            2
          rescue
            _ -> nil
          end
        end
        """)

      assert [] = hits(NewSilentFallback, base, same)
      assert [_] = hits(NewSilentFallback, base, more)
    end
  end

  describe "QueryLostLimit reads and bounds" do
    test "a limit replaced by Enum.take is flagged and the message names it" do
      base = mod("def a(q), do: q |> limit(5) |> Repo.all()")
      head = mod("def a(q), do: q |> Repo.all() |> Enum.take(5)")
      assert [hit] = hits(QueryLostLimit, base, head)
      assert hit.message =~ "Enum.take"
    end

    test "dropping the bound together with its read is not a lost limit" do
      base =
        mod("""
        def a(q) do
          {Repo.all(limit(q, 5)), Repo.all(q)}
        end
        """)

      head = mod("def a(q), do: {[], Repo.all(q)}")
      assert [] = hits(QueryLostLimit, base, head)
    end

    test "limit options on non-query keyword lists are not bounds" do
      base =
        mod(
          "def a(opts), do: Keyword.get(opts, :limit, 10) |> then(&from(p in Post, limit: ^&1)) |> Repo.all()"
        )

      head =
        mod(
          "def a(opts), do: Keyword.get(opts, :limit, 10) |> then(&from(p in Post)) |> Repo.all()"
        )

      assert [_] = hits(QueryLostLimit, base, head)

      plain_base = mod("def a, do: Plug.Parsers.init(limit: 10)")
      plain_head = mod("def a, do: Plug.Parsers.init([])")
      assert [] = hits(QueryLostLimit, plain_base, plain_head)
    end
  end
end
