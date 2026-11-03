Code.require_file("locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.RouterTest do
  @moduledoc """
  GH #3612 / REQ-666: the six write routes of module `locations` through the full pipeline
  (`Letflow.Router`) with real bearer tokens. Tests M1 (manifest), H1..H3 (holders), R1..R7 (one per
  route), E1..E9 (refusals), T1..T3 (tenancy). `async: false`: tenant provisioning runs DDL.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.LocationsFixture
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Repo

  @base "/api/v1/modules/locations"

  setup do
    a = LocationsFixture.installed_tenant!("gh3612a")
    b = LocationsFixture.installed_tenant!("gh3612b")
    %{a: a, b: b, admin: user!(a, ["TENANT_ADMIN"]), admin_b: user!(b, ["TENANT_ADMIN"])}
  end

  defp user!(ctx, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3612-user-#{Ecto.UUID.generate()}",
        display_name: "Locations Router Test User",
        email: "gh3612-#{Ecto.UUID.generate()}@example.com",
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
    conn =
      case body do
        nil ->
          conn(method, @base <> path)

        body ->
          conn(method, @base <> path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", "t-3612")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp key, do: "k-" <> Ecto.UUID.generate()
  defp strip(body), do: Map.delete(body, "trace_id")

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    json(conn)
  end

  defp post!(ctx, path, body, status \\ 201),
    do: ok!(call(:post, path, ctx.admin, Map.put_new(body, "idempotency_key", key())), status)

  defp node!(ctx, extra \\ %{}) do
    code = "N#{System.unique_integer([:positive])}"

    post!(
      ctx,
      "/nodes",
      Map.merge(%{"code" => code, "name" => code, "node_kind" => "zone"}, extra)
    )
  end

  # An org unit written through the org write functions (the org routes are REQ-665's).
  defp unit!(tenant) do
    n = System.unique_integer([:positive])
    opts = fn -> %{actor_id: Ecto.UUID.generate(), idempotency_key: key()} end

    {:ok, le} =
      Org.create_legal_entity(
        tenant.schema,
        %{"code" => "LE#{n}", "name" => "LE", "bin" => String.pad_leading("#{n}", 12, "5")},
        opts.()
      )

    {:ok, site} =
      Org.create_site(
        tenant.schema,
        %{"code" => "S#{n}", "name" => "S", "legal_entity_id" => le["record_id"]},
        opts.()
      )

    {:ok, unit} =
      Org.create_unit(
        tenant.schema,
        %{
          "code" => "U#{n}",
          "name" => "U",
          "legal_entity_id" => le["record_id"],
          "site_id" => site["record_id"]
        },
        opts.()
      )

    unit["record_id"]
  end

  defp lookup!(ctx, id) do
    {:ok, rec} = Locations.lookup(ctx.a.schema, id)
    rec
  end

  test "M1 manifest: one permission, six policies, the router, no role grants" do
    m = Locations.manifest()
    assert m.permissions == [:LocationsWrite]
    assert m.role_grants == %{}
    assert Locations.router() == Letflow.Modules.Locations.Router
    assert length(m.route_policies) == 6
    assert length(Enum.uniq(m.route_policies)) == 6
    assert Enum.all?(m.route_policies, fn {_, _, atom} -> atom == :LocationsWrite end)
    assert Version.compare(m.version, "0.3.0") == :gt
    assert Catalog.validate(m) == :ok
  end

  describe "holders" do
    test "H1/H2 only the tenant admin writes", ctx do
      unit = unit!(ctx.a)
      node = node!(ctx)["record_id"]
      nbody = %{"idempotency_key" => key(), "code" => "H1", "name" => "H", "node_kind" => "z"}
      assert call(:post, "/nodes", ctx.admin, nbody).status == 201

      lbody = %{"idempotency_key" => key(), "org_unit_id" => unit, "location_id" => node}
      assert call(:post, "/links", ctx.admin, lbody).status == 201

      for role <- ["PROCESS_OPERATOR", "PROCESS_DESIGNER", "TASK_WORKER", "TENANT_AUDITOR"] do
        u = user!(ctx.a, [role])
        assert call(:post, "/nodes", u, Map.put(nbody, "idempotency_key", key())).status == 403
        assert call(:post, "/links", u, Map.put(lbody, "idempotency_key", key())).status == 403
      end
    end

    test "H3 LocationsWrite is held by TENANT_ADMIN and PLATFORM_ADMIN only" do
      alias Letflow.Api.Authorization

      holders =
        for role <- Enum.map(Authorization.roles(), &Atom.to_string/1),
            Authorization.has_permission?(
              Authorization.effective_roles([role], role == "PLATFORM_ADMIN"),
              :LocationsWrite
            ),
            do: role

      assert Enum.sort(holders) == ["PLATFORM_ADMIN", "TENANT_ADMIN"]
    end
  end

  describe "routes R1..R7" do
    test "R1 create a node", ctx do
      node = node!(ctx, %{"segment" => "A"})
      assert lookup!(ctx, node["record_id"])["active"] == true
    end

    test "R2 address_pattern segments composes the address", ctx do
      seg = fn s, parent ->
        extra = %{"segment" => s, "address_pattern" => "segments"}
        node!(ctx, if(parent, do: Map.put(extra, "parent_id", parent), else: extra))
      end

      a = seg.("A", nil)
      b = seg.("B", a["record_id"])
      c = seg.("C", b["record_id"])
      assert lookup!(ctx, c["record_id"])["address"] == "A-B-C"
    end

    test "R3 update a node", ctx do
      node = node!(ctx)["record_id"]

      ok!(
        call(:patch, "/nodes/#{node}", ctx.admin, %{"idempotency_key" => key(), "name" => "New"}),
        200
      )

      assert lookup!(ctx, node)["name"] == "New"
    end

    test "R4 move a node under a parent and to the root", ctx do
      parent = node!(ctx)["record_id"]
      child = node!(ctx)["record_id"]
      post!(ctx, "/nodes/#{child}/move", %{"parent_id" => parent}, 200)
      assert lookup!(ctx, child)["parent_id"] == parent
      post!(ctx, "/nodes/#{child}/move", %{"parent_id" => nil}, 200)
      assert lookup!(ctx, child)["parent_id"] == nil
    end

    test "R5 retire a node", ctx do
      node = node!(ctx)["record_id"]
      post!(ctx, "/nodes/#{node}/retire", %{}, 200)
      assert lookup!(ctx, node)["active"] == false
    end

    test "R6/R7 link and unlink", ctx do
      unit = unit!(ctx.a)
      node = node!(ctx)["record_id"]
      body = %{"org_unit_id" => unit, "location_id" => node}
      post!(ctx, "/links", body, 201)
      assert Locations.linked?(ctx.a.schema, unit, node)
      post!(ctx, "/links/retire", body, 200)
      refute Locations.linked?(ctx.a.schema, unit, node)
    end
  end

  describe "refusals" do
    test "E1 a move into the own subtree is a cycle", ctx do
      parent = node!(ctx)["record_id"]
      child = node!(ctx, %{"parent_id" => parent})["record_id"]

      assert post!(ctx, "/nodes/#{parent}/move", %{"parent_id" => child}, 422)["reason"] ==
               "cycle"
    end

    test "E2 retire with an active child", ctx do
      parent = node!(ctx)["record_id"]
      node!(ctx, %{"parent_id" => parent})

      assert post!(ctx, "/nodes/#{parent}/retire", %{}, 422)["reason"] ==
               "has_active_descendants"
    end

    test "E3 link to a retired unit is refused", ctx do
      unit = unit!(ctx.a)
      node = node!(ctx)["record_id"]
      opts = %{actor_id: Ecto.UUID.generate(), idempotency_key: key()}
      {:ok, _} = Org.retire_unit(ctx.a.schema, unit, opts)

      body = post!(ctx, "/links", %{"org_unit_id" => unit, "location_id" => node}, 422)
      assert body["reason"] == "unit_inactive"
    end

    test "E4 unlink of an unlinked pair is 404", ctx do
      unit = unit!(ctx.a)
      node = node!(ctx)["record_id"]
      post!(ctx, "/links/retire", %{"org_unit_id" => unit, "location_id" => node}, 404)
    end

    test "E5 a bad address_pattern is field_invalid and writes nothing", ctx do
      for bad <- ["free", 5, true] do
        body =
          post!(
            ctx,
            "/nodes",
            %{"code" => "E5", "name" => "n", "node_kind" => "z", "address_pattern" => bad},
            422
          )

        assert body["reason"] == "field_invalid" and body["field"] == "address_pattern"
      end

      assert {:error, _} = Locations.lookup(ctx.a.schema, Ecto.UUID.generate())
    end

    test "E6 an unknown key, and address_pattern off create, is field_not_allowed", ctx do
      body =
        post!(ctx, "/nodes", %{"code" => "E6", "name" => "n", "node_kind" => "z", "x" => 1}, 422)

      assert body["reason"] == "field_not_allowed" and body["field"] == "x"

      node = node!(ctx)["record_id"]

      for {m, path, extra} <- [
            {:patch, "/nodes/#{node}", %{"name" => "n"}},
            {:post, "/nodes/#{node}/move", %{"parent_id" => nil}},
            {:post, "/nodes/#{node}/retire", %{}}
          ] do
        res =
          ok!(
            call(
              m,
              path,
              ctx.admin,
              Map.merge(extra, %{"idempotency_key" => key(), "address_pattern" => "segments"})
            ),
            422
          )

        assert res["reason"] == "field_not_allowed", path
      end
    end

    test "E7 idempotency_key missing, blank or not text", ctx do
      base = %{"code" => "E7", "name" => "n", "node_kind" => "z"}

      for bad <- [%{}, %{"idempotency_key" => ""}, %{"idempotency_key" => 5}] do
        body = ok!(call(:post, "/nodes", ctx.admin, Map.merge(base, bad)), 422)
        assert body["reason"] == "field_invalid" and body["field"] == "idempotency_key"
      end
    end

    test "E8 a replay returns the first result, one record", ctx do
      k = key()
      body = %{"idempotency_key" => k, "code" => "IDEM", "name" => "n", "node_kind" => "z"}
      first = ok!(call(:post, "/nodes", ctx.admin, body), 201)
      second = ok!(call(:post, "/nodes", ctx.admin, body), 201)
      assert first["record_id"] == second["record_id"]
    end

    test "E9 the same key with another body is 409", ctx do
      k = key()
      body = %{"idempotency_key" => k, "code" => "IDEM9", "name" => "n", "node_kind" => "z"}
      ok!(call(:post, "/nodes", ctx.admin, body), 201)
      conn = call(:post, "/nodes", ctx.admin, %{body | "name" => "other"})
      assert conn.status == 409
      assert json(conn)["reason"] == "idempotency_key_reuse"
    end

    test "E10 a missing link key is field_invalid", ctx do
      body = post!(ctx, "/links", %{"org_unit_id" => Ecto.UUID.generate()}, 422)
      assert body["reason"] == "field_invalid" and body["field"] == "location_id"
    end
  end

  describe "tenancy" do
    test "T1 tenant B cannot touch tenant A records on any id route", ctx do
      unit = unit!(ctx.a)
      node = node!(ctx)["record_id"]
      post!(ctx, "/links", %{"org_unit_id" => unit, "location_id" => node})
      before = lookup!(ctx, node)
      k = fn extra -> Map.put(extra, "idempotency_key", key()) end

      unknown =
        call(:patch, "/nodes/#{Ecto.UUID.generate()}", ctx.admin_b, k.(%{"name" => "x"}))

      assert unknown.status == 404

      calls = [
        {:patch, "/nodes/#{node}", k.(%{"name" => "x"})},
        {:post, "/nodes/#{node}/move", k.(%{"parent_id" => nil})},
        {:post, "/nodes/#{node}/retire", k.(%{})},
        {:post, "/links", k.(%{"org_unit_id" => unit, "location_id" => node})},
        {:post, "/links/retire", k.(%{"org_unit_id" => unit, "location_id" => node})}
      ]

      for {m, path, body} <- calls do
        conn = call(m, path, ctx.admin_b, body)
        assert conn.status == 404, path
        assert strip(json(conn)) == strip(json(unknown))
      end

      assert before == lookup!(ctx, node)
      assert Locations.linked?(ctx.a.schema, unit, node)
    end

    test "T2 a tenant identifier in the body is refused", ctx do
      body = %{"idempotency_key" => key(), "code" => "T2", "name" => "n", "node_kind" => "z"}

      for k <- ["tenant_id", "prefix"] do
        res = ok!(call(:post, "/nodes", ctx.admin_b, Map.put(body, k, ctx.a.tenant_id)), 422)
        assert res["reason"] == "field_not_allowed"
      end

      created = ok!(call(:post, "/nodes", ctx.admin_b, body), 201)
      assert {:ok, _} = Locations.lookup(ctx.b.schema, created["record_id"])
      assert {:error, :not_found} = Locations.lookup(ctx.a.schema, created["record_id"])

      src = File.read!(Path.join(File.cwd!(), "lib/letflow/modules/locations/router.ex"))
      refute src =~ ~s(params["tenant)
      refute src =~ "String.to_atom"
    end

    test "T3 a tenant without locations answers the dispatcher 404" do
      t = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "gh3612n")
      slug = Repo.get!(Letflow.Identity.Tenant, t.tenant_id).slug
      u = user!(%{schema: t.schema_name, slug: slug}, ["TENANT_ADMIN"])
      body = %{"idempotency_key" => key()}
      unknown = call(:post, "/nothing-here", u, body)

      for {m, path} <- [{:post, "/nodes"}, {:post, "/links"}, {:patch, "/nodes/x"}] do
        conn = call(m, path, u, body)
        assert conn.status == 404, path
        assert strip(json(conn)) == strip(json(unknown))
      end
    end
  end
end
