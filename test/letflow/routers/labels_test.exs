defmodule Letflow.Routers.LabelsTest do
  @moduledoc """
  REQ-551 / GH #3180 -- `Letflow.Routers.Labels` through its own `call/2` (the real Authorize
  plug), over provisioned tenant schemas. Test IDs follow T-0483's design: P1..P3 permissions,
  M1 merge, L1..L3 locale rule, W1/W2 write locale, V1..V7 value rules, I1 refused ids,
  S1 storage isolation, A1 audit, X1/X2 cross-tenant, N1 not-found, F1 uniform 403.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Identity.Tenant
  alias Letflow.Labels
  alias Letflow.Labels.Defaults
  alias Letflow.Labels.Override
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Labels.init([])
  @id "entities.admin.landing.title"
  @other_id "entities.admin.landing.intro"

  defp tenant!(settings \\ %{"locales" => ["en", "ru"], "default_locale" => "ru"}) do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "req551")

    {1, nil} =
      Repo.update_all(from(x in Tenant, where: x.id == ^t.tenant_id), set: [settings: settings])

    t
  end

  defp call(method, path, t, opts \\ []) do
    conn(method, path)
    |> Map.put(:body_params, Keyword.get(opts, :body, %{}))
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
      tenant_id: t.tenant_id,
      roles: Keyword.get(opts, :roles, ["TENANT_ADMIN"])
    })
    |> assign(:trace_id, "req551-trace")
    |> Letflow.Routers.Labels.call(@opts)
  end

  defp put(t, id, locale, text, opts \\ []),
    do: call(:put, "/#{id}", t, [body: %{"locale" => locale, "text" => text}] ++ opts)

  defp del(t, id, locale, opts \\ []),
    do: call(:delete, "/#{id}?locale=#{locale}", t, opts)

  defp read(t, query \\ "", opts \\ []) do
    conn = call(:get, "/" <> query, t, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp rows(t), do: Repo.all(Override, prefix: t.schema_name)

  describe "permissions (P1..P3)" do
    test "P1 TENANT_ADMIN: 200 on PUT, 204 on DELETE" do
      t = tenant!()
      assert put(t, @id, "ru", "Банк").status == 200
      assert del(t, @id, "ru").status == 204
    end

    test "P2 TASK_WORKER and TENANT_AUDITOR: 403 on PUT and DELETE, 200 on GET" do
      t = tenant!()

      for role <- ["TASK_WORKER", "TENANT_AUDITOR"] do
        assert put(t, @id, "ru", "x", roles: [role]).status == 403
        assert del(t, @id, "ru", roles: [role]).status == 403
        assert {200, _} = read(t, "", roles: [role])
      end

      assert rows(t) == []
    end

    test "P3 the fixtures never grant PLATFORM_ADMIN to the tenant user" do
      t = tenant!()
      assert put(t, @id, "ru", "x", roles: ["PLATFORM_ADMIN"]).status == 403
      assert rows(t) == []
    end
  end

  describe "merged read (M1) and locale rule (L1..L3)" do
    test "M1 override shows in GET, others stay default, DELETE restores the default" do
      t = tenant!()
      default = Defaults.messages("ru")[@id]
      assert put(t, @id, "ru", "  Мой банк  ").status == 200

      {200, body} = read(t, "?locale=ru")
      assert body["locale"] == "ru"
      assert body["messages"][@id] == "Мой банк"
      assert body["messages"][@other_id] == Defaults.messages("ru")[@other_id]
      assert Map.keys(body["messages"]) |> Enum.sort() == Defaults.ids()
      refute Enum.any?(Map.keys(body["messages"]), &String.starts_with?(&1, "login."))

      assert del(t, @id, "ru").status == 204
      {200, body} = read(t, "?locale=ru")
      assert body["messages"][@id] == default
    end

    test "L1 locales [en, ru], default ru: ru-RU serves ru, kk (not configured) serves ru" do
      t = tenant!()
      assert {200, %{"locale" => "ru"}} = read(t, "?locale=ru-RU")
      assert {200, %{"locale" => "ru"}} = read(t, "?locale=kk")
      assert {200, %{"locale" => "ru"}} = read(t)
    end

    test "L2 default_locale de, locales [de]: serves en with the en texts" do
      t = tenant!(%{"locales" => ["de"], "default_locale" => "de"})
      assert {200, %{"locale" => "en", "messages" => msgs}} = read(t, "?locale=de")
      assert msgs[@id] == Defaults.messages("en")[@id]
    end

    test "L3 no locales configured: serves en" do
      t = tenant!(%{})
      assert {200, %{"locale" => "en"}} = read(t)
      assert {200, %{"locale" => "en"}} = read(t, "?locale=ru")
    end
  end

  describe "write locale (W1, W2)" do
    test "W1 kk for [en, ru] and de for a tenant configuring it: 422, nothing stored or removed" do
      t = tenant!()
      assert put(t, @id, "ru", "keep").status == 200
      assert put(t, @id, "kk", "x").status == 422
      assert del(t, @id, "kk").status == 422

      d = tenant!(%{"locales" => ["de", "en"], "default_locale" => "en"})
      assert put(d, @id, "de", "x").status == 422
      assert del(d, @id, "de").status == 422
      assert rows(d) == []
      assert [%{locale: "ru", text: "keep"}] = rows(t)
      assert put(t, @id, nil, "x").status == 422
    end

    test "W2 ru-RU is accepted for a ru tenant and stored as ru" do
      t = tenant!(%{"locales" => ["ru-RU"]})
      conn = put(t, @id, "ru-RU", "Банк")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["locale"] == "ru"
      assert [%{locale: "ru"}] = rows(t)
    end
  end

  describe "value rules (V1..V7) and refused ids (I1)" do
    setup do: {:ok, t: tenant!()}

    test "V1 empty and whitespace-only", %{t: t} do
      assert put(t, @id, "ru", "").status == 422
      assert put(t, @id, "ru", " \t ").status == 422
      assert put(t, @id, "ru", nil).status == 422
      assert rows(t) == []
    end

    test "V2 500 characters accepted, 501 refused", %{t: t} do
      assert put(t, @id, "ru", String.duplicate("a", 501)).status == 422
      assert rows(t) == []
      assert put(t, @id, "ru", String.duplicate("a", 500)).status == 200
    end

    test "V3 newline and other control characters", %{t: t} do
      for bad <- ["a\nb", "a\tb", "a\u0000b", "a\u0085b"] do
        assert put(t, @id, "ru", bad).status == 422, inspect(bad)
      end

      assert rows(t) == []
    end

    test "V4 placeholder the default does not have", %{t: t} do
      assert put(t, @id, "ru", "Hello {name}").status == 422
      assert put(t, @id, "ru", "Hello {}").status == 422
      assert rows(t) == []
    end

    test "V5 default placeholder accepted, unknown refused, and omitting it is fine" do
      defaults = %{"ru" => %{@id => "Всего {count}"}}
      t = tenant!()
      settings = t.tenant.settings || %{}
      settings = Map.put(settings, "locales", ["ru"])
      p = t.schema_name

      assert {:ok, %{text: "Итого {count}"}} =
               Labels.put_override(p, t.tenant_id, settings, nil, @id, "ru", "Итого {count}",
                 defaults: defaults
               )

      assert {:ok, _} =
               Labels.put_override(p, t.tenant_id, settings, nil, @id, "ru", "Без числа",
                 defaults: defaults
               )

      assert {:error, {:invalid_text, :placeholder}} =
               Labels.put_override(p, t.tenant_id, settings, nil, @id, "ru", "Итого {total}",
                 defaults: defaults
               )

      assert MapSet.to_list(Defaults.placeholders(defaults, @id, "ru")) == ["count"]
    end

    test "V6 ICU plural, select and lone braces", %{t: t} do
      for bad <- [
            "{n, plural, one {a} other {b}}",
            "{x, select, a {b} other {c}}",
            "open { brace",
            "close } brace"
          ] do
        assert put(t, @id, "ru", bad).status == 422, bad
      end

      assert rows(t) == []
    end

    test "V7 markup text is stored and returned unchanged", %{t: t} do
      assert put(t, @id, "ru", "<b>x</b>").status == 200
      {200, body} = read(t, "?locale=ru")
      assert body["messages"][@id] == "<b>x</b>"
    end

    test "I1 login.*, security.*, auth.* and unknown ids: 422, nothing stored", %{t: t} do
      for id <- ["login.title", "security.x", "auth.x", "entities.no.such.id"] do
        assert put(t, id, "ru", "x").status == 422, id
        assert del(t, id, "ru").status == 422, id
      end

      assert rows(t) == []
    end
  end

  describe "storage (S1, S2)" do
    test "S1 two tenants override the same id and locale, each reads its own text" do
      a = tenant!()
      b = tenant!()
      assert put(a, @id, "ru", "A text").status == 200
      assert put(b, @id, "ru", "B text").status == 200
      assert {200, %{"messages" => %{@id => "A text"}}} = read(a, "?locale=ru")
      assert {200, %{"messages" => %{@id => "B text"}}} = read(b, "?locale=ru")
    end

    test "S2 a second PUT replaces, one row" do
      t = tenant!()
      put(t, @id, "ru", "one")
      put(t, @id, "ru", "two")
      assert [%{text: "two", tenant_id: tid}] = rows(t)
      assert tid == t.tenant_id
    end
  end

  describe "audit (A1)" do
    test "A1 PUT and DELETE write one event with id, locale and actor, no other tenant's data" do
      a = tenant!()
      b = tenant!()
      actor = Ecto.UUID.generate()
      put(b, @other_id, "ru", "B only")
      put(a, @id, "ru", "A text", user_id: actor)
      del(a, @id, "ru", user_id: actor)

      entries = Repo.all(from(e in Entry, order_by: e.timestamp), prefix: a.schema_name)
      assert Enum.map(entries, & &1.action) == ["labels.override_set", "labels.override_delete"]
      assert Enum.all?(entries, &(&1.actor_id == actor and &1.resource_id == "#{@id}:ru"))

      assert hd(entries).after_state == %{
               "message_id" => @id,
               "locale" => "ru",
               "text" => "A text"
             }

      refute inspect(entries) =~ "B only"
    end

    test "A1 a refusal writes no audit event" do
      t = tenant!()
      put(t, "login.x", "ru", "x")
      del(t, @id, "ru")
      assert Repo.all(Entry, prefix: t.schema_name) == []
    end
  end

  describe "cross-tenant (X1, X2) and not-found (N1, F1)" do
    test "X1 tenant B sees nothing of A, and B's DELETE equals a delete of nothing" do
      a = tenant!()
      b = tenant!()
      put(a, @id, "ru", "A secret wording")

      {200, body} = read(b, "?locale=ru")
      refute inspect(body) =~ "A secret wording"

      same = del(b, @id, "ru")
      nothing = del(b, @other_id, "ru")
      assert same.status == 404
      assert {same.status, same.resp_body} == {nothing.status, nothing.resp_body}
      assert [%{text: "A secret wording"}] = rows(a)
    end

    test "X2 a tenant_id in query or body is ignored" do
      a = tenant!()
      b = tenant!()
      put(a, @id, "ru", "A text")

      conn =
        call(:put, "/#{@id}?tenant_id=#{a.tenant_id}", b,
          body: %{"locale" => "ru", "text" => "B text", "tenant_id" => a.tenant_id}
        )

      assert conn.status == 200
      assert [%{text: "A text"}] = rows(a)
      assert [%{text: "B text"}] = rows(b)
      {200, body} = read(b, "?locale=ru&tenant_id=#{a.tenant_id}")
      assert body["messages"][@id] == "B text"
    end

    test "N1 DELETE of a missing override by an admin: one fixed 404" do
      t = tenant!()
      one = del(t, @id, "ru")
      two = del(t, @other_id, "en")
      assert one.status == 404
      assert {one.status, one.resp_body} == {two.status, two.resp_body}
    end

    test "F1 a non-admin gets the same 403 with and without an existing override" do
      t = tenant!()
      put(t, @id, "ru", "exists")
      ct = &get_resp_header(&1, "content-type")

      for role <- ["TASK_WORKER", "TENANT_AUDITOR"] do
        with_override = del(t, @id, "ru", roles: [role])
        without = del(t, @other_id, "ru", roles: [role])
        assert with_override.status == 403

        assert {with_override.status, with_override.resp_body, ct.(with_override)} ==
                 {without.status, without.resp_body, ct.(without)}

        put_with = put(t, @id, "ru", "x", roles: [role])
        put_without = put(t, @other_id, "ru", "x", roles: [role])

        assert {put_with.status, put_with.resp_body, ct.(put_with)} ==
                 {put_without.status, put_without.resp_body, ct.(put_without)}
      end

      assert [%{text: "exists"}] = rows(t)
    end
  end

  describe "S3 every Repo call of the context passes the tenant prefix" do
    test "no Repo call in lib/letflow/labels.ex lacks prefix:" do
      calls =
        "lib/letflow/labels.ex"
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/Repo\.(all|insert|delete_all|update|one|get|transaction)/))

      refute calls == []

      for line <- calls, not (line =~ "Repo.transaction") do
        assert line =~ "prefix", line
      end
    end
  end
end
