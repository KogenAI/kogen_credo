defmodule KogenCredo.Diff.RulesTest.Src do
  @spec mod(String.t()) :: String.t()
  def mod(body), do: "defmodule App.X do\n#{body}\nend\n"
end

defmodule KogenCredo.Diff.RulesTest do
  use ExUnit.Case, async: true

  import KogenCredo.Diff.RulesTest.Src

  alias KogenCredo.Diff

  alias KogenCredo.Diff.Rules.ChangesetWeakened
  alias KogenCredo.Diff.Rules.LostTransaction
  alias KogenCredo.Diff.Rules.NewRepoInLoop
  alias KogenCredo.Diff.Rules.NewSilentFallback
  alias KogenCredo.Diff.Rules.QueryLostLimit
  alias KogenCredo.Diff.Rules.QueryLostScope
  alias KogenCredo.Diff.Rules.WidenedApi

  defp hits(rule, base, head, opts \\ []) do
    {:ok, changes} = Diff.changes("lib/app/x.ex", base, head)
    Diff.check(changes, [rule], opts)
  end

  describe "QueryLostLimit" do
    @base mod("""
          def history(user_id, n) do
            SearchHistory
            |> where([sh], sh.user_id == ^user_id)
            |> limit(^n)
            |> Repo.all()
          end
          """)

    test "flags limit replaced by Enum.uniq_by and Enum.take" do
      head =
        String.replace(
          @base,
          "|> limit(^n)\n  |> Repo.all()",
          "|> Repo.all()\n  |> Enum.uniq_by(& &1.query)\n  |> Enum.take(n)"
        )

      assert [hit] = hits(QueryLostLimit, @base, head)
      assert hit.function == "App.X.history/2"
      assert hit.severity == :advisory
      assert hit.message =~ "Enum.uniq_by, Enum.take"
    end

    test "flags nested Enum call and an aliased repo" do
      base = "alias App.Repo, as: R\n" <> mod("def a(n), do: from(p in P, limit: ^n) |> R.all()")
      head = "alias App.Repo, as: R\n" <> mod("def a(n), do: Enum.take(R.all(from(p in P)), n)")
      assert [hit] = hits(QueryLostLimit, base, head)
      assert hit.message =~ "Enum.take"
    end

    test "flags a dropped from limit: keyword" do
      assert [_] =
               hits(
                 QueryLostLimit,
                 mod("def q(n), do: from(p in Post, where: p.ok, limit: ^n)"),
                 mod("def q(_n), do: from(p in Post, where: p.ok)")
               )
    end

    test "judges multi-clause guarded functions as a whole" do
      base =
        mod(
          "def q(n) when n > 0, do: from(p in P, limit: ^n)\ndef q(_), do: from(p in P, limit: 1)"
        )

      head = mod("def q(n) when n > 0, do: from(p in P, limit: ^n)\ndef q(_), do: from(p in P)")
      assert [_] = hits(QueryLostLimit, base, head)
    end

    test "quiet when the limit moved into a helper" do
      head =
        mod("""
        def history(user_id, n) do
          SearchHistory
          |> where([sh], sh.user_id == ^user_id)
          |> page(n)
          |> Repo.all()
        end

        defp page(q, n), do: limit(q, ^n)
        """)

      assert [] = hits(QueryLostLimit, @base, head)
    end

    test "quiet when a limit is kept and distinct added" do
      head =
        String.replace(@base, "|> limit(^n)", "|> distinct([sh], sh.query)\n    |> limit(^n)")

      assert [] = hits(QueryLostLimit, @base, head)
    end

    test "lookalike: in-memory list trimming, no query" do
      base = mod("def top(xs, n), do: xs |> Enum.sort() |> Enum.take(n) |> limit(n)")
      head = mod("def top(xs, n), do: xs |> Enum.sort() |> Enum.take(n)")
      assert [] = hits(QueryLostLimit, base, head)
    end

    test "lookalike: limit: option of a non-query keyword call" do
      base = mod("def opts, do: Keyword.merge([limit: 5], [])")
      head = mod("def opts, do: Keyword.merge([], [])")
      assert [] = hits(QueryLostLimit, base, head)
    end

    test "quiet when a bounded query was deleted together with its Repo.all" do
      base =
        mod("""
        def r(e), do: e |> q() |> Repo.all() |> Enum.map(&ctx/1)
        defp q(e), do: from(x in X, where: x.e == ^e, limit: 6)
        defp ctx(x), do: from(t in T, where: t.x == ^x.id, limit: 300) |> Repo.all()
        """)

      head =
        mod("""
        def r(e), do: e |> q() |> Repo.all() |> Enum.map(&Map.put(&1, :t, nil))
        defp q(e), do: from(x in X, where: x.e == ^e, limit: 6)
        """)

      assert [] = hits(QueryLostLimit, base, head)
    end

    test "quiet for a non-Repo receiver and for new functions" do
      base = mod("def a(n), do: from(p in P, limit: ^n) |> Cache.all()")
      head = mod("def a(_n), do: from(p in P) |> Cache.all()")
      assert [_] = hits(QueryLostLimit, base, head)
      assert [] = hits(QueryLostLimit, nil, mod("def a(_n), do: from(p in P) |> Repo.all()"))
    end
  end

  describe "QueryLostScope" do
    @scoped mod("""
            def list(user_id), do: from(p in Post, where: p.user_id == ^user_id) |> Repo.all()
            """)

    test "flags a lost owner comparison" do
      head = mod("def list(_user_id), do: from(p in Post) |> Repo.all()")
      assert [hit] = hits(QueryLostScope, @scoped, head)
      assert hit.message =~ ":user_id (1 -> 0)"
    end

    test "flags a lost get_by keyword scope and honours configured fields" do
      base = mod("def get(id, org), do: Repo.get_by(Doc, id: id, org_slug: org)")
      head = mod("def get(id, _org), do: Repo.get_by(Doc, id: id)")
      assert [] = hits(QueryLostScope, base, head)
      assert [_] = hits(QueryLostScope, base, head, sensitive_fields: [:org_slug])
    end

    test "quiet when the scope moved into a helper" do
      head =
        mod("""
        def list(user_id), do: Post |> scoped(user_id) |> Repo.all()
        defp scoped(q, user_id), do: where(q, [p], p.user_id == ^user_id)
        """)

      assert [] = hits(QueryLostScope, @scoped, head)
    end

    test "lookalikes: pattern match on a map key and the whole query removed" do
      base = mod("def a(%{user_id: id}), do: from(p in P, where: p.ok) |> Repo.all(id)")
      head = mod("def a(_), do: from(p in P, where: p.ok) |> Repo.all(1)")
      assert [] = hits(QueryLostScope, base, head)
      assert [] = hits(QueryLostScope, @scoped, mod("def list(_), do: []"))
    end
  end

  describe "NewRepoInLoop" do
    test "flags Enum.map with a Repo call in an fn" do
      base = mod("def f(ids), do: Repo.all(from(u in User, where: u.id in ^ids))")
      head = mod("def f(ids), do: Enum.map(ids, fn id -> Repo.get(User, id) end)")
      assert [hit] = hits(NewRepoInLoop, base, head)
      assert hit.message =~ "once per element"
    end

    test "flags pipeline Stream, for, captures and local helpers" do
      assert [_] =
               hits(
                 NewRepoInLoop,
                 nil,
                 mod("def f(ids), do: ids |> Stream.map(&Repo.get(User, &1)) |> Enum.to_list()")
               )

      assert [_] =
               hits(
                 NewRepoInLoop,
                 nil,
                 mod(
                   "def f(ids), do: for(id <- ids, do: Repo.one(from(u in U, where: u.id == ^id)))"
                 )
               )

      helper = "defp load(id), do: Repo.get(User, id)"

      assert [_] =
               hits(NewRepoInLoop, nil, mod("def f(ids), do: Enum.map(ids, &load/1)\n" <> helper))

      assert [_] =
               hits(
                 NewRepoInLoop,
                 nil,
                 mod("def f(ids), do: Enum.map(ids, fn id -> load(id) end)\n" <> helper)
               )
    end

    test "for: the first generator is evaluated once" do
      assert [] = hits(NewRepoInLoop, nil, mod("def f, do: for(u <- Repo.all(User), do: u.id)"))
    end

    test "quiet when the call site already existed in the base" do
      base = mod("def f(ids), do: Enum.map(ids, fn id -> Repo.get(User, id) end)")
      head = mod("def f(ids), do: Enum.map(ids, fn id -> Repo.get(User, id) end) |> Enum.take(3)")
      assert [] = hits(NewRepoInLoop, base, head)
    end

    test "lookalikes: Repo outside the loop, non-Repo receiver, write needs opt-in" do
      assert [] =
               hits(
                 NewRepoInLoop,
                 nil,
                 mod("def f(ids) do\n u = Repo.get(User, 1)\n Enum.map(ids, &(&1 + u.id))\nend")
               )

      assert [] =
               hits(
                 NewRepoInLoop,
                 nil,
                 mod("def f(ids), do: Enum.map(ids, fn id -> Cache.get(id) end)")
               )

      write = mod("def f(rows), do: Enum.each(rows, fn r -> Repo.insert(r) end)")
      assert [] = hits(NewRepoInLoop, nil, write)
      assert [_] = hits(NewRepoInLoop, nil, write, include_writes: true)
    end
  end

  describe "NewSilentFallback" do
    test "flags a new catch-all returning :ok" do
      base = mod("def f(x) do\n case x do\n {:ok, v} -> v\n end\nend")
      head = mod("def f(x) do\n case x do\n {:ok, v} -> v\n _invalid -> :ok\n end\nend")
      assert [hit] = hits(NewSilentFallback, base, head)
      assert hit.message =~ "catch-all"
    end

    test "flags {:error, _} -> nil in with-else, bare rescue, and an added clause" do
      with_else =
        mod("def f(x) do\n with {:ok, a} <- x do\n a\n else\n {:error, _} -> nil\n end\nend")

      assert [_] = hits(NewSilentFallback, nil, with_else)
      assert [_] = hits(NewSilentFallback, nil, mod("def f(x) do\n g(x)\nrescue\n _ -> []\nend"))
      assert [_] = hits(NewSilentFallback, nil, mod("def f(1), do: :a\ndef f(_), do: nil"))
    end

    test "flags an unused bound variable" do
      assert [_] =
               hits(
                 NewSilentFallback,
                 nil,
                 mod("def f(x) do\n case x do\n 1 -> :a\n other -> nil\n end\nend")
               )
    end

    test "quiet when the fallback logs or re-raises, uses the variable, or existed" do
      logged =
        mod("def f(x) do\n case x do\n 1 -> :a\n _ ->\n Logger.warning(\"x\")\n :ok\n end\nend")

      assert [] = hits(NewSilentFallback, nil, logged)

      assert [] =
               hits(
                 NewSilentFallback,
                 nil,
                 mod("def f(x) do\n case x do\n 1 -> :a\n other -> {:error, other}\n end\nend")
               )

      assert [] =
               hits(
                 NewSilentFallback,
                 nil,
                 mod("def f(x) do\n g(x)\nrescue\n e -> reraise e, __STACKTRACE__\nend")
               )

      same = mod("def f(x) do\n case x do\n _ -> :ok\n end\nend")

      assert [] =
               hits(
                 NewSilentFallback,
                 same,
                 mod("def f(x) do\n case x do\n _ -> :ok\n end\n :done\nend")
               )
    end

    test "lookalikes: fn _ -> :ok, single-clause def f(_), cond true -> nil" do
      assert [] =
               hits(NewSilentFallback, nil, mod("def f(xs), do: Enum.each(xs, fn _ -> :ok end)"))

      assert [] = hits(NewSilentFallback, nil, mod("def f(_), do: nil"))

      assert [] =
               hits(
                 NewSilentFallback,
                 nil,
                 mod("def f(x) do\n cond do\n x > 1 -> :a\n true -> nil\n end\nend")
               )
    end
  end

  describe "ChangesetWeakened" do
    @cs mod("""
        def changeset(u, attrs) do
          u
          |> cast(attrs, [:email, :name])
          |> validate_required([:email, :name])
          |> validate_length(:name, min: 2)
          |> unique_constraint(:email)
        end
        """)

    test "flags a removed validator, constraint and dropped required field" do
      head = String.replace(@cs, "  |> validate_length(:name, min: 2)\n", "")
      assert [hit] = hits(ChangesetWeakened, @cs, head)
      assert hit.message =~ "removed validate_length(:name)"

      head_without_constraint = String.replace(@cs, "|> unique_constraint(:email)", "")
      assert [%{message: m}] = hits(ChangesetWeakened, @cs, head_without_constraint)
      assert m =~ "unique_constraint(:email)"

      head_without_required =
        String.replace(@cs, "validate_required([:email, :name])", "validate_required([:email])")

      assert [%{message: m}] = hits(ChangesetWeakened, @cs, head_without_required)
      assert m =~ "validate_required(:name)"
    end

    test "flags a sensitive field added to cast; configurable" do
      head = String.replace(@cs, "[:email, :name]", "[:email, :name, :is_admin]")
      assert [%{message: m}] = hits(ChangesetWeakened, @cs, head)
      assert m =~ "added :is_admin to cast"

      plan_head = String.replace(@cs, "[:email, :name]", "[:email, :name, :plan]")
      assert [] = hits(ChangesetWeakened, @cs, plan_head)
      assert [_] = hits(ChangesetWeakened, @cs, plan_head, cast_sensitive_fields: [:plan])
    end

    test "flags the unpiped Ecto.Changeset form" do
      base = mod("def cs(c), do: Ecto.Changeset.validate_required(c, [:a, :b])")
      head = mod("def cs(c), do: Ecto.Changeset.validate_required(c, [:a])")
      assert [_] = hits(ChangesetWeakened, base, head)
    end

    test "flags the lost validation of a guarded multi-clause function" do
      base =
        mod("def cs(c, :new) when is_map(c), do: validate_required(c, [:a])\ndef cs(c, _), do: c")

      head = mod("def cs(c, :new) when is_map(c), do: c\ndef cs(c, _), do: c")
      assert [_] = hits(ChangesetWeakened, base, head)
    end

    test "quiet when validators move to a helper, are added, or reordered" do
      moved =
        mod("""
        def changeset(u, attrs), do: u |> cast(attrs, [:email, :name]) |> checks()
        defp checks(cs) do
          cs |> validate_required([:email, :name]) |> validate_length(:name, min: 2) |> unique_constraint(:email)
        end
        """)

      assert [] = hits(ChangesetWeakened, @cs, moved)

      added =
        String.replace(
          @cs,
          "|> unique_constraint(:email)",
          "|> unique_constraint(:email)\n |> validate_format(:email, ~r/@/)"
        )

      assert [] = hits(ChangesetWeakened, @cs, added)
    end

    test "lookalike: a function named validate_x defined, or a non-changeset function" do
      base = mod("def go(x), do: Enum.map(x, & &1)")
      head = mod("def go(x), do: Enum.map(x, & &1 + 1)\ndef validate_thing(x), do: x")
      assert [] = hits(ChangesetWeakened, base, head)
    end
  end

  describe "LostTransaction" do
    @tx mod("""
        def pay(a, b) do
          Repo.transaction(fn ->
            Repo.update!(a)
            Repo.update!(b)
          end)
        end
        """)

    test "flags a transaction removed while two writes remain" do
      head = mod("def pay(a, b) do\n Repo.update!(a)\n Repo.update!(b)\nend")
      assert [hit] = hits(LostTransaction, @tx, head)
      assert hit.message =~ "2 writes"
    end

    test "flags a Multi pipeline run without a transaction" do
      base =
        mod(
          "def pay(m, a, b), do: m |> Multi.update(:a, a) |> Multi.update(:b, b) |> Repo.transaction()"
        )

      head = mod("def pay(_m, a, b) do\n Repo.update(a)\n Repo.delete(b)\nend")
      assert [_] = hits(LostTransaction, base, head)
    end

    test "quiet when the transaction moved to a helper, one write remains, or none existed" do
      moved =
        mod(
          "def pay(a, b), do: tx(a, b)\ndefp tx(a, b), do: Repo.transaction(fn -> Repo.update!(a)\n Repo.update!(b) end)"
        )

      assert [] = hits(LostTransaction, @tx, moved)
      assert [] = hits(LostTransaction, @tx, mod("def pay(a, _b), do: Repo.update!(a)"))
      untransacted = mod("def pay(a, b) do\n Repo.update!(a)\n Repo.update!(b)\nend")

      assert [] =
               hits(
                 LostTransaction,
                 untransacted,
                 mod("def pay(a, b) do\n Repo.update!(a)\n Repo.update!(b)\n :ok\nend")
               )
    end

    test "lookalike: transaction on a non-Repo receiver" do
      base =
        mod("def pay(a, b), do: Mnesia.transaction(fn -> Repo.update!(a)\n Repo.update!(b) end)")

      head = mod("def pay(a, b) do\n Repo.update!(a)\n Repo.update!(b)\nend")
      assert [] = hits(LostTransaction, base, head)
    end
  end

  describe "WidenedApi" do
    test "flags defp -> def and a new def in an existing module" do
      assert [hit] =
               hits(
                 WidenedApi,
                 mod("defp a, do: 1\ndef b, do: 1"),
                 mod("def a, do: 1\ndef b, do: 1")
               )

      assert hit.message =~ "defp"
      assert [hit] = hits(WidenedApi, mod("def b, do: 1"), mod("def b, do: 1\ndef c, do: 2"))
      assert hit.function == "App.X.c/0"
    end

    test "quiet for new defp, @impl callbacks, new modules and body-only edits" do
      assert [] = hits(WidenedApi, mod("def b, do: 1"), mod("def b, do: 1\ndefp c, do: 2"))

      assert [] =
               hits(
                 WidenedApi,
                 mod("def b, do: 1"),
                 mod("def b, do: 1\n@impl true\ndef init(x), do: {:ok, x}")
               )

      assert [] = hits(WidenedApi, nil, mod("def b, do: 1"))
      assert [] = hits(WidenedApi, mod("def b, do: 1"), mod("def b, do: 2"))
    end

    test "nested modules and multi-clause functions" do
      base = "defmodule A do\n defmodule B do\n defp f(1), do: 1\n defp f(2), do: 2\n end\nend\n"
      head = String.replace(base, "defp f(2)", "def f(2)")
      assert [hit] = hits(WidenedApi, base, head)
      assert hit.function == "A.B.f/1"
    end
  end

  describe "Diff.changes/3 and check/3" do
    test "invalid base or head source is an explicit error" do
      assert {:error, {:invalid_source, :head, msg}} = Diff.changes("a.ex", nil, "defmodule A do")
      assert is_binary(msg)

      assert {:error, {:invalid_source, :base, _}} =
               Diff.changes("a.ex", "def (", "defmodule A do\nend")
    end

    test "formatting-only edits and removed functions are not changes" do
      assert {:ok, []} = Diff.changes("a.ex", mod("def a, do: 1"), mod("def  a,   do: 1"))

      assert {:ok, []} =
               Diff.changes("a.ex", mod("def a, do: 1\ndef b, do: 2"), mod("def a, do: 1"))
    end

    test "an added parameter matches its base counterpart" do
      assert {:ok, [change]} =
               Diff.changes("a.ex", mod("def a(x), do: x"), mod("def a(x, y), do: x + y"))

      assert change.base != nil
    end

    test "severity overrides and rule lookup" do
      base = mod("def q(n), do: from(p in P, limit: ^n)")
      head = mod("def q(_n), do: from(p in P)")

      assert {:ok, [%{severity: :error}]} =
               Diff.check_sources("a.ex", base, head,
                 rules: [QueryLostLimit],
                 severity: %{"query-lost-limit" => :error}
               )

      assert {:ok, QueryLostLimit} = Diff.rule_by_id("query-lost-limit")
      assert :error = Diff.rule_by_id("nope")
      assert length(Diff.rules()) == 7
    end
  end
end
