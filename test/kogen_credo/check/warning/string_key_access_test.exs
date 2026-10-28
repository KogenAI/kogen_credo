defmodule KogenCredo.Check.Warning.StringKeyAccessTest do
  use Credo.Test.Case, async: true

  alias KogenCredo.Check.Warning.StringKeyAccess

  defp run(source, filename \\ "lib/app/core.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(StringKeyAccess, params)
  end

  describe "positives" do
    test "bracket access with a string key" do
      [issue] = run(~S|defmodule A do def f(m), do: m["name"] end|)
      assert issue.message =~ ~S|x["name"]|
    end

    test "Map functions with a string key" do
      issues =
        run("""
        defmodule A do
          def f(m) do
            Map.get(m, "a")
            Map.fetch!(m, "b")
            Map.put(m, "c", 1)
          end
        end
        """)

      assert length(issues) == 3
    end

    test "get_in with a string path" do
      assert [_] = run(~S|defmodule A do def f(m), do: get_in(m, ["a", "b"]) end|)
    end

    test "string-keyed literal and pattern" do
      assert [_, _] =
               run("""
               defmodule A do
                 def f(%{"id" => id}), do: %{"id" => id}
               end
               """)
    end
  end

  describe "negatives and lookalikes" do
    test "atom keys and variable keys pass" do
      """
      defmodule A do
        def f(m, key) do
          Map.get(m, :a)
          Map.get(m, key)
          m[:b]
          %{a: 1}
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "strings that are not keys pass" do
      source = ~S"""
      defmodule A do
        def f(s), do: s |> String.split(",") |> Enum.map(&"x#{&1}")
      end
      """

      source
      |> run()
      |> refute_issues()
    end
  end

  describe "codec allowances" do
    @source ~S|defmodule MyApp.Codec do def decode(m), do: %{id: m["id"]} end|

    test "codec_modules exempt the module" do
      @source
      |> run("lib/app/codec.ex", codec_modules: [MyApp.Codec])
      |> refute_issues()
    end

    test "codec_modules exempt nested modules but not siblings" do
      source = """
      defmodule MyApp do
        defmodule Codec do
          def decode(m), do: m["id"]
        end

        defmodule Other do
          def f(m), do: m["id"]
        end
      end
      """

      assert [issue] = run(source, "lib/app.ex", codec_modules: [MyApp.Codec])
      assert issue.line_no == 7
    end

    test "codec_globs exempt files" do
      @source
      |> run("lib/app/user_codec.ex", codec_globs: ["lib/**/*_codec.ex"])
      |> refute_issues()
    end

    test "without configuration the same file is reported" do
      assert [_] = run(@source, "lib/app/codec.ex")
    end
  end

  describe "filename scope" do
    test "tests are skipped by default" do
      @source
      |> run("test/app_test.exs")
      |> refute_issues()
    end

    test "umbrella lib paths are in scope" do
      assert [_] = run(@source, "apps/core/lib/core.ex")
    end
  end

  describe "framework contracts" do
    test "LiveView callback heads and reads from the bound params are the boundary" do
      """
      defmodule AppWeb.ItemLive do
        use AppWeb, :live_view

        def mount(%{"id" => id}, session, socket) do
          {:ok, assign(socket, owner: session["owner"], id: id)}
        end

        def handle_params(%{"id" => id} = params, _uri, socket) do
          {:noreply, assign(socket, q: params["q"] || "", id: id)}
        end

        def handle_event("save", %{"item" => %{"name" => name} = item}, socket) do
          {:noreply, assign(socket, name: name, body: Map.get(item, "body"))}
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "using the unpacked value after it was passed on is still reported" do
      assert [_] =
               run("""
               defmodule AppWeb.ItemLive do
                 use Phoenix.LiveView

                 def handle_event("save", params, socket) do
                   other = Map.new(params)
                   {:noreply, assign(socket, name: other["name"])}
                 end
               end
               """)
    end

    test "controller actions only in controller modules" do
      source = fn name, extra ->
        """
        defmodule #{name} do
          #{extra}
          def show(conn, %{"id" => id}), do: render(conn, id)
          def other(thing, %{"id" => id}), do: {thing, id}
        end
        """
      end

      assert [_] = run(source.("AppWeb.ItemController", ""))
      assert [_, _] = run(source.("App.Items", ""))
      assert [_] = run(source.("AppWeb.Things", "use AppWeb, :controller"))
    end

    test "Oban perform args and Ecto.Type cast are contracts; building job args is not" do
      """
      defmodule App.Worker do
        use Oban.Worker

        def perform(%Oban.Job{args: %{"id" => id} = args}), do: {id, args["mode"]}
      end

      defmodule App.Interval do
        use Ecto.Type

        def cast(%{"months" => m}), do: {:ok, m}
      end
      """
      |> run()
      |> refute_issues()

      assert [_] =
               run("""
               defmodule App.Caller do
                 def f(id), do: App.Worker.enqueue(%{"id" => id})
               end
               """)
    end

    test "Plug.Conn string-keyed fields" do
      """
      defmodule AppWeb.Plug do
        def call(%{params: %{"return_to" => to}} = conn, _opts), do: {conn, to}
        def g(conn), do: {Map.get(conn.cookies, "k"), conn.params["q"], conn.req_cookies["z"]}
      end
      """
      |> run()
      |> refute_issues()

      assert [_] = run(~S|defmodule A do def f(socket), do: socket.assigns["q"] end|)
    end

    test "Phoenix callback names need a declared Phoenix contract" do
      domain = """
      defmodule MyApp.Teams do
        def join(team, member, role), do: {team, member["email"], Map.get(member, "name"), role}
        def handle_event("x", params, socket), do: {socket, params["k"]}
      end
      """

      assert [_, _, _] = run(domain)

      impl_only = """
      defmodule MyApp.Teams do
        @impl true
        def join(team, member, role), do: {team, member["email"], role}
      end
      """

      assert [_] = run(impl_only)

      for decl <- ["use Phoenix.Channel", "use AppWeb, :channel", "@behaviour Phoenix.Channel"] do
        """
        defmodule AppWeb.RoomChannel do
          #{decl}
          def join("room:" <> _, %{"token" => token}, socket), do: {:ok, token, socket}
          def handle_in("ping", payload, socket), do: {:reply, {:ok, payload["x"]}, socket}
        end
        """
        |> run()
        |> refute_issues()
      end

      for decl <- [
            "use Phoenix.LiveComponent",
            "use AppWeb, :live_component",
            "@behaviour Phoenix.LiveView"
          ] do
        """
        defmodule AppWeb.Comp do
          #{decl}
          def handle_event("x", %{"id" => id}, socket), do: {:noreply, assign(socket, id: id)}
        end
        """
        |> run()
        |> refute_issues()
      end

      # a channel contract does not cover LiveView callbacks and vice versa
      assert [_] =
               run("""
               defmodule AppWeb.RoomChannel do
                 use Phoenix.Channel
                 def handle_event("x", %{"id" => id}, socket), do: {id, socket}
               end
               """)
    end

    test "params:/cookies: exemptions need a Plug.Conn pattern or a conn binding" do
      source = """
      defmodule MyApp.Audit do
        def a(id), do: MyApp.Repo.insert(%MyApp.Event{id: id, params: %{"actor" => id}})
        def b(id), do: MyApp.Repo.insert(%MyApp.Event{id: id, payload: %{"actor" => id}})
        def c(webhook), do: webhook.params["event"]
        def d(webhook), do: Map.get(webhook.cookies, "k")
        def e(%{params: %{"id" => id}} = event), do: {event, id}
      end
      """

      assert [_, _, _, _, _] = run(source)

      """
      defmodule AppWeb.Plugs do
        def a(%Plug.Conn{params: %{"id" => id}}, _), do: id
        def b(%{params: %{"id" => id}} = conn, _), do: {conn, id}
        def c(conn), do: {conn.params["q"], Map.get(conn.cookies, "k")}
        def d(%Plug.Conn{} = c), do: c.params["q"]
        def e(c = %Plug.Conn{}), do: Map.get(c.req_cookies, "k")
        def f(conn) do
          case conn do
            %Plug.Conn{query_params: %{"q" => q}} -> q
          end
        end
      end
      """
      |> run()
      |> refute_issues()

      # a bound name that is not a connection is not exempt
      assert [_] = run("defmodule A do def f(c), do: c.params[\"q\"] end")
    end

    test "Ecto JSON paths inside query macros" do
      """
      defmodule App.Q do
        def f(status), do: dynamic([d], d.screenshot["status"] in ^status)
        def g(q), do: from(d in q, where: d.meta["kind"] == "x")
      end
      """
      |> run()
      |> refute_issues()

      assert [_] = run(~S|defmodule A do def f(d), do: d.meta["kind"] end|)
    end

    test "a map literal handed to a JSON encoder is a produced wire document" do
      """
      defmodule A do
        def f(t), do: Jason.encode!(%{"@context" => "https://schema.org", "name" => t})
        def g(v), do: URI.encode_query(%{"v" => v})
      end
      """
      |> run()
      |> refute_issues()

      assert [_] = run(~S|defmodule A do def f(t), do: Map.new(%{"name" => t}) end|)
    end
  end
end
