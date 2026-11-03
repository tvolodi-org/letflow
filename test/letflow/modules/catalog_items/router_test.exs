Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.RouterTest do
  @moduledoc """
  GH #3610 / REQ-668: the three lot routes of module `catalog_items` through the full pipeline
  (`Letflow.Router`) with real bearer tokens. Tests H1..H3 (holders), R1..R3 (routes), E3/E4
  (refusals), T1..T3 (tenancy). `async: false`: tenant provisioning runs DDL.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.CatalogItems
  alias Letflow.Repo

  import Letflow.CatalogItemsFixture, except: [values: 3]

  @base "/api/v1/modules/catalog_items"

  setup do
    a = installed_tenant!("gh3610a")
    b = installed_tenant!("gh3610b")
    item = item!(a.schema, "RI", uom!(a.schema, "RU").record_id)

    %{
      a: a,
      b: b,
      item: item.record_id,
      admin: user!(a, ["TENANT_ADMIN"]),
      admin_b: user!(b, ["TENANT_ADMIN"])
    }
  end

  defp user!(ctx, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3610-user-#{Ecto.UUID.generate()}",
        display_name: "Catalog Router Test User",
        email: "gh3610-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema)

    %{user_id: user.id, plaintext: plaintext, slug: ctx.slug}
  end

  defp call(method, path, user, body) do
    conn(method, @base <> path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", "t-3610")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp key, do: "k-" <> Ecto.UUID.generate()
  defp strip(body), do: Map.delete(body, "trace_id")

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    json(conn)
  end

  defp with_key(body), do: Map.put_new(body, "idempotency_key", key())

  defp lot!(ctx, code) do
    ok!(
      call(:post, "/lots", ctx.admin, with_key(%{"item_id" => ctx.item, "code" => code})),
      201
    )
  end

  defp lookup!(ctx, id) do
    {:ok, rec} = CatalogItems.lookup(ctx.a.schema, id)
    rec
  end

  describe "routes" do
    test "R1 create, R1b duplicate code, R1c bad date", ctx do
      lot = lot!(ctx, "R1")
      assert lot["entity_type"] == "catalog_lot" and lot["active"] == true
      assert lookup!(ctx, lot["record_id"])["code"] == "R1"

      body =
        ok!(
          call(:post, "/lots", ctx.admin, with_key(%{"item_id" => ctx.item, "code" => "R1"})),
          422
        )

      assert body["reason"] == "record_payload_invalid"
      assert is_list(body["fields"])

      bad = %{"item_id" => ctx.item, "code" => "R1C", "expiry_date" => "2026-02-30"}
      body = ok!(call(:post, "/lots", ctx.admin, with_key(bad)), 422)
      assert body["reason"] == "field_invalid" and body["field"] == "expiry_date"
    end

    test "R2 update, R2b fixed field refused", ctx do
      lot = lot!(ctx, "R2")["record_id"]
      ok!(call(:patch, "/lots/#{lot}", ctx.admin, with_key(%{"producer" => "Acme"})), 200)
      assert lookup!(ctx, lot)["producer"] == "Acme"

      body = ok!(call(:patch, "/lots/#{lot}", ctx.admin, with_key(%{"item_id" => ctx.item})), 422)
      assert body["reason"] == "field_not_allowed" and body["field"] == "item_id"
    end

    test "R3 retire, extra key refused", ctx do
      lot = lot!(ctx, "R3")["record_id"]
      body = ok!(call(:post, "/lots/#{lot}/retire", ctx.admin, with_key(%{"x" => 1})), 422)
      assert body["reason"] == "field_not_allowed"
      assert lookup!(ctx, lot)["active"] == true

      assert ok!(call(:post, "/lots/#{lot}/retire", ctx.admin, with_key(%{})), 200)["active"] ==
               false

      assert lookup!(ctx, lot)["active"] == false
    end
  end

  describe "holders" do
    test "H1/H2 only the tenant admin writes", ctx do
      lot = lot!(ctx, "H1")["record_id"]

      for role <- ["PROCESS_OPERATOR", "TASK_WORKER", "TENANT_AUDITOR"] do
        u = user!(ctx.a, [role])
        create = with_key(%{"item_id" => ctx.item, "code" => "H2"})
        assert call(:post, "/lots", u, create).status == 403, role
        assert call(:patch, "/lots/#{lot}", u, with_key(%{"mark" => "m"})).status == 403, role
        assert call(:post, "/lots/#{lot}/retire", u, with_key(%{})).status == 403, role
      end

      assert lookup!(ctx, lot)["active"] == true
    end

    test "H3 the module permission is held by TENANT_ADMIN and PLATFORM_ADMIN only" do
      alias Letflow.Api.Authorization

      for atom <- CatalogItems.manifest().permissions do
        holders =
          for role <- Enum.map(Authorization.roles(), &Atom.to_string/1),
              Authorization.has_permission?(
                Authorization.effective_roles([role], role == "PLATFORM_ADMIN"),
                atom
              ),
              do: role

        assert Enum.sort(holders) == ["PLATFORM_ADMIN", "TENANT_ADMIN"], inspect(atom)
      end
    end
  end

  describe "refusals" do
    test "E3 idempotency_key missing, blank or not text", ctx do
      base = %{"item_id" => ctx.item, "code" => "E3"}

      for bad <- [%{}, %{"idempotency_key" => ""}, %{"idempotency_key" => 5}] do
        body = ok!(call(:post, "/lots", ctx.admin, Map.merge(base, bad)), 422)
        assert body["reason"] == "field_invalid" and body["field"] == "idempotency_key"
      end
    end

    test "E4 replay returns the original, key reuse with other input is 409", ctx do
      body = %{"idempotency_key" => key(), "item_id" => ctx.item, "code" => "E4"}
      first = ok!(call(:post, "/lots", ctx.admin, body), 201)
      second = ok!(call(:post, "/lots", ctx.admin, body), 201)
      assert first["record_id"] == second["record_id"]

      conn = call(:post, "/lots", ctx.admin, %{body | "code" => "E4B"})
      assert conn.status == 409
      assert json(conn)["reason"] == "idempotency_key_reuse"
    end

    test "E5 an inactive item is refused", ctx do
      off = item!(ctx.a.schema, "OFF", uom!(ctx.a.schema, "OU").record_id, %{"active" => false})
      attrs = with_key(%{"item_id" => off.record_id, "code" => "E5"})
      body = ok!(call(:post, "/lots", ctx.admin, attrs), 422)
      assert body["reason"] == "item_inactive"
    end
  end

  describe "tenancy" do
    test "T1 tenant B cannot touch tenant A lots or items", ctx do
      lot = lot!(ctx, "T1")["record_id"]
      before = lookup!(ctx, lot)

      unknown =
        call(:patch, "/lots/#{Ecto.UUID.generate()}", ctx.admin_b, with_key(%{"mark" => "x"}))

      patch = call(:patch, "/lots/#{lot}", ctx.admin_b, with_key(%{"mark" => "x"}))
      retire = call(:post, "/lots/#{lot}/retire", ctx.admin_b, with_key(%{}))

      create =
        call(:post, "/lots", ctx.admin_b, with_key(%{"item_id" => ctx.item, "code" => "T1B"}))

      for c <- [unknown, patch, retire, create], do: assert(c.status == 404)
      assert strip(json(patch)) == strip(json(unknown))
      assert strip(json(retire)) == strip(json(unknown))
      assert strip(json(create)) == strip(json(unknown))
      assert before == lookup!(ctx, lot)
    end

    test "T2 a tenant identifier in the body is refused", ctx do
      body = with_key(%{"item_id" => ctx.item, "code" => "T2"})

      for k <- ["tenant_id", "prefix"] do
        res = ok!(call(:post, "/lots", ctx.admin_b, Map.put(body, k, ctx.a.tenant_id)), 422)
        assert res["reason"] == "field_not_allowed"
      end

      src = File.read!(Path.join(File.cwd!(), "lib/letflow/modules/catalog_items/router.ex"))
      refute src =~ ~s(params["tenant)
    end

    test "T3 a tenant without catalog_items answers the dispatcher 404" do
      t = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "gh3610n")
      slug = Repo.get!(Letflow.Identity.Tenant, t.tenant_id).slug
      u = user!(%{schema: t.schema_name, slug: slug}, ["TENANT_ADMIN"])
      unknown = call(:post, "/nothing-here", u, %{"idempotency_key" => key()})

      for {m, path} <- [{:post, "/lots"}, {:patch, "/lots/x"}, {:post, "/lots/x/retire"}] do
        conn = call(m, path, u, %{"idempotency_key" => key()})
        assert conn.status == 404, path
        assert strip(json(conn)) == strip(json(unknown))
      end
    end
  end
end
