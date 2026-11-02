Code.require_file("org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Org.RouterTest do
  @moduledoc """
  GH #3613 / REQ-665: the 17 write routes of module `org` through the full pipeline
  (`Letflow.Router`) with real bearer tokens. Tests R1..R17 (one per route), H1/H2 (holders),
  E1..E10 (refusals), T1..T3 (tenancy). `async: false`: tenant provisioning runs DDL.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @base "/api/v1/modules/org"

  setup do
    a = OrgFixture.installed_tenant!("gh3613a")
    b = OrgFixture.installed_tenant!("gh3613b")
    %{a: a, b: b, admin: user!(a, ["TENANT_ADMIN"]), admin_b: user!(b, ["TENANT_ADMIN"])}
  end

  defp user!(ctx, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3613-user-#{Ecto.UUID.generate()}",
        display_name: "Org Router Test User",
        email: "gh3613-#{Ecto.UUID.generate()}@example.com",
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
    |> put_req_header("x-trace-id", "t-3613")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp key, do: "k-" <> Ecto.UUID.generate()

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    json(conn)
  end

  defp post!(ctx, path, body, status \\ 201),
    do: ok!(call(:post, path, ctx.admin, Map.put_new(body, "idempotency_key", key())), status)

  defp patch!(ctx, path, body),
    do: ok!(call(:patch, path, ctx.admin, Map.put_new(body, "idempotency_key", key())), 200)

  defp le!(ctx, code \\ nil, bin \\ nil) do
    code = code || "LE#{System.unique_integer([:positive])}"
    bin = bin || String.pad_leading("#{System.unique_integer([:positive])}", 12, "7")
    post!(ctx, "/legal-entities", %{"code" => code, "name" => "Company #{code}", "bin" => bin})
  end

  defp site!(ctx, le_id) do
    code = "S#{System.unique_integer([:positive])}"
    post!(ctx, "/sites", %{"code" => code, "name" => code, "legal_entity_id" => le_id})
  end

  defp unit!(ctx, extra \\ %{}) do
    le = le!(ctx)["record_id"]
    site = site!(ctx, le)["record_id"]
    code = "U#{System.unique_integer([:positive])}"

    post!(
      ctx,
      "/units",
      Map.merge(
        %{"code" => code, "name" => code, "legal_entity_id" => le, "site_id" => site},
        extra
      )
    )
  end

  defp position!(ctx, unit_id) do
    code = "P#{System.unique_integer([:positive])}"
    post!(ctx, "/positions", %{"code" => code, "name" => code, "org_unit_id" => unit_id})
  end

  defp employee!(ctx, unit_id, position_id) do
    code = "E#{System.unique_integer([:positive])}"

    post!(ctx, "/employees", %{
      "code" => code,
      "full_name" => "Name #{code}",
      "org_unit_id" => unit_id,
      "position_id" => position_id
    })
  end

  defp lookup!(ctx, id) do
    {:ok, rec} = Org.lookup(ctx.a.schema, id)
    rec
  end

  defp strip(body), do: Map.delete(body, "trace_id")

  describe "routes R1..R17" do
    test "R1-R3 legal entity create, update, retire", ctx do
      le = le!(ctx)
      assert lookup!(ctx, le["record_id"])["active"] == true
      patch!(ctx, "/legal-entities/#{le["record_id"]}", %{"name" => "Changed"})
      assert lookup!(ctx, le["record_id"])["name"] == "Changed"

      ok!(
        call(:post, "/legal-entities/#{le["record_id"]}/retire", ctx.admin, %{
          "idempotency_key" => key()
        }),
        200
      )

      assert lookup!(ctx, le["record_id"])["active"] == false
    end

    test "R4-R6 site create, update, retire", ctx do
      site = site!(ctx, le!(ctx)["record_id"])
      patch!(ctx, "/sites/#{site["record_id"]}", %{"name" => "Site X"})
      assert lookup!(ctx, site["record_id"])["name"] == "Site X"

      ok!(
        call(:post, "/sites/#{site["record_id"]}/retire", ctx.admin, %{"idempotency_key" => key()}),
        200
      )

      assert lookup!(ctx, site["record_id"])["active"] == false
    end

    test "R7-R10 unit create, update, move, retire; R10b root move", ctx do
      parent = unit!(ctx)
      unit = unit!(ctx, %{"parent" => parent["record_id"]})
      assert lookup!(ctx, unit["record_id"])["parent"] == parent["record_id"]
      patch!(ctx, "/units/#{unit["record_id"]}", %{"name" => "Renamed"})
      assert lookup!(ctx, unit["record_id"])["name"] == "Renamed"

      other = unit!(ctx)
      post!(ctx, "/units/#{unit["record_id"]}/move", %{"parent_id" => other["record_id"]}, 200)
      assert lookup!(ctx, unit["record_id"])["parent"] == other["record_id"]

      post!(ctx, "/units/#{unit["record_id"]}/move", %{"parent_id" => nil}, 200)
      assert lookup!(ctx, unit["record_id"])["parent"] in [nil, ""]

      post!(ctx, "/units/#{unit["record_id"]}/retire", %{}, 200)
      assert lookup!(ctx, unit["record_id"])["active"] == false
    end

    test "R11-R17 position and employee routes, transfer to another unit", ctx do
      u1 = unit!(ctx)["record_id"]
      u2 = unit!(ctx)["record_id"]
      pos1 = position!(ctx, u1)["record_id"]
      pos2 = position!(ctx, u2)["record_id"]
      patch!(ctx, "/positions/#{pos1}", %{"name" => "Boss"})
      assert lookup!(ctx, pos1)["name"] == "Boss"

      emp = employee!(ctx, u1, pos1)["record_id"]
      patch!(ctx, "/employees/#{emp}", %{"full_name" => "New Name"})
      assert lookup!(ctx, emp)["full_name"] == "New Name"

      post!(ctx, "/employees/#{emp}/transfer", %{"org_unit_id" => u2, "position_id" => pos2}, 200)
      rec = lookup!(ctx, emp)
      assert rec["org_unit_id"] == u2
      assert rec["position_id"] == pos2

      post!(ctx, "/employees/#{emp}/retire", %{}, 200)
      assert lookup!(ctx, emp)["active"] == false
      post!(ctx, "/positions/#{pos1}/retire", %{}, 200)
      assert lookup!(ctx, pos1)["active"] == false
    end
  end

  describe "holders" do
    test "H1/H2 only the tenant admin writes", ctx do
      body = %{"idempotency_key" => key(), "code" => "H1", "name" => "H", "bin" => "111111111111"}
      assert call(:post, "/legal-entities", ctx.admin, body).status == 201

      for role <- ["PROCESS_OPERATOR", "PROCESS_DESIGNER", "TASK_WORKER", "TENANT_AUDITOR"] do
        u = user!(ctx.a, [role])
        assert call(:post, "/legal-entities", u, body).status == 403, role
        emp = %{"idempotency_key" => key(), "code" => "x", "full_name" => "x"}
        assert call(:post, "/employees", u, emp).status == 403, role
      end
    end

    test "H3 the module permissions are held by TENANT_ADMIN and PLATFORM_ADMIN only" do
      alias Letflow.Api.Authorization

      for atom <- Org.manifest().permissions do
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
    test "E1 unknown, malformed and other-tenant ids give the same 404", ctx do
      unit = unit!(ctx)["record_id"]
      body = %{"name" => "X", "idempotency_key" => key()}
      unknown = call(:patch, "/units/#{Ecto.UUID.generate()}", ctx.admin, body)
      malformed = call(:patch, "/units/not-a-uuid", ctx.admin, body)
      cross = call(:patch, "/units/#{unit}", ctx.admin_b, body)
      assert {unknown.status, malformed.status, cross.status} == {404, 404, 404}
      assert strip(json(unknown)) == strip(json(malformed))
      assert strip(json(unknown)) == strip(json(cross))
    end

    test "E2/E4 unknown key and bad bin", ctx do
      base = %{"code" => "E2", "name" => "n", "bin" => "123456789012"}

      body =
        ok!(
          call(
            :post,
            "/legal-entities",
            ctx.admin,
            Map.merge(base, %{"idempotency_key" => key(), "x" => 1})
          ),
          422
        )

      assert body["reason"] == "field_not_allowed" and body["field"] == "x"

      body =
        ok!(
          call(
            :post,
            "/legal-entities",
            ctx.admin,
            Map.merge(base, %{"idempotency_key" => key(), "bin" => "12345678901"})
          ),
          422
        )

      assert body["reason"] == "field_invalid" and body["field"] == "bin"
    end

    test "E3 idempotency_key missing, blank or not text", ctx do
      base = %{"code" => "E3", "name" => "n", "bin" => "123456789012"}

      for bad <- [%{}, %{"idempotency_key" => ""}, %{"idempotency_key" => 5}] do
        body = ok!(call(:post, "/legal-entities", ctx.admin, Map.merge(base, bad)), 422)
        assert body["reason"] == "field_invalid" and body["field"] == "idempotency_key"
      end

      assert {:error, :not_found} == Org.lookup(ctx.a.schema, Ecto.UUID.generate())
    end

    test "E5 a move into the own subtree is a cycle", ctx do
      parent = unit!(ctx)["record_id"]
      child = unit!(ctx, %{"parent" => parent})["record_id"]
      body = post!(ctx, "/units/#{parent}/move", %{"parent_id" => child}, 422)
      assert body["reason"] == "cycle"
    end

    test "E6 a unit named by a scope grant is not retired", ctx do
      unit = unit!(ctx)["record_id"]
      group = RSG.fresh_group!(ctx.a.schema)
      RSG.raw_scoped_row!(ctx.a.schema, group.id, "TASK_WORKER", unit)
      assert post!(ctx, "/units/#{unit}/retire", %{}, 422)["reason"] == "node_has_grants"
    end

    test "E7/E8 idempotent replay and key reuse", ctx do
      k = key()
      body = %{"idempotency_key" => k, "code" => "IDEM", "name" => "n", "bin" => "222222222222"}
      first = ok!(call(:post, "/legal-entities", ctx.admin, body), 201)
      second = ok!(call(:post, "/legal-entities", ctx.admin, body), 201)
      assert first["record_id"] == second["record_id"]

      other = %{body | "name" => "different"}
      conn = call(:post, "/legal-entities", ctx.admin, other)
      assert conn.status == 409
      assert json(conn)["reason"] == "idempotency_key_reuse"
    end

    test "E9 action routes check their own keys", ctx do
      unit = unit!(ctx)["record_id"]

      assert post!(ctx, "/units/#{unit}/retire", %{"foo" => 1}, 422)["reason"] ==
               "field_not_allowed"

      assert post!(ctx, "/units/#{unit}/move", %{}, 422)["reason"] == "field_invalid"

      emp = employee!(ctx, unit, position!(ctx, unit)["record_id"])["record_id"]
      body = post!(ctx, "/employees/#{emp}/transfer", %{"org_unit_id" => unit}, 422)
      assert body["reason"] == "field_invalid" and body["field"] == "position_id"
    end

    test "E10 a payload violation lists field names only", ctx do
      le = le!(ctx)["record_id"]
      site = site!(ctx, le)["record_id"]
      attrs = %{"code" => "DUPCODE", "name" => "n", "legal_entity_id" => le, "site_id" => site}
      post!(ctx, "/units", attrs)
      conn = call(:post, "/units", ctx.admin, Map.put(attrs, "idempotency_key", key()))
      assert conn.status == 422
      refute conn.resp_body =~ "DUPCODE"
    end
  end

  describe "tenancy" do
    test "T1 tenant B cannot touch tenant A records on any id route", ctx do
      unit = unit!(ctx)["record_id"]
      pos = position!(ctx, unit)["record_id"]
      emp = employee!(ctx, unit, pos)["record_id"]
      le = le!(ctx)["record_id"]
      site = site!(ctx, le)["record_id"]
      before = Enum.map([unit, pos, emp, le, site], &lookup!(ctx, &1))

      k = fn extra -> Map.put(extra, "idempotency_key", key()) end

      calls = [
        {:patch, "/legal-entities/#{le}", k.(%{"name" => "x"})},
        {:post, "/legal-entities/#{le}/retire", k.(%{})},
        {:patch, "/sites/#{site}", k.(%{"name" => "x"})},
        {:post, "/sites/#{site}/retire", k.(%{})},
        {:patch, "/units/#{unit}", k.(%{"name" => "x"})},
        {:post, "/units/#{unit}/move", k.(%{"parent_id" => nil})},
        {:post, "/units/#{unit}/retire", k.(%{})},
        {:patch, "/positions/#{pos}", k.(%{"name" => "x"})},
        {:post, "/positions/#{pos}/retire", k.(%{})},
        {:patch, "/employees/#{emp}", k.(%{"full_name" => "x"})},
        {:post, "/employees/#{emp}/transfer", k.(%{"org_unit_id" => unit, "position_id" => pos})},
        {:post, "/employees/#{emp}/retire", k.(%{})}
      ]

      for {m, path, body} <- calls do
        assert call(m, path, ctx.admin_b, body).status == 404, path
      end

      assert before == Enum.map([unit, pos, emp, le, site], &lookup!(ctx, &1))
    end

    test "T2 a tenant identifier in the body is refused and the slug of A does not redirect",
         ctx do
      body = %{"idempotency_key" => key(), "code" => "T2", "name" => "n", "bin" => "333333333333"}

      for k <- ["tenant_id", "prefix"] do
        res =
          ok!(call(:post, "/legal-entities", ctx.admin_b, Map.put(body, k, ctx.a.tenant_id)), 422)

        assert res["reason"] == "field_not_allowed"
      end

      created = ok!(call(:post, "/legal-entities", ctx.admin_b, body), 201)
      assert {:ok, _} = Org.lookup(ctx.b.schema, created["record_id"])
      assert {:error, :not_found} = Org.lookup(ctx.a.schema, created["record_id"])

      src = File.read!(Path.join(File.cwd!(), "lib/letflow/modules/org/router.ex"))
      refute src =~ ~s(params["tenant)
    end

    test "T3 a tenant without org answers the dispatcher 404" do
      t = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "gh3613n")
      slug = Repo.get!(Letflow.Identity.Tenant, t.tenant_id).slug
      u = user!(%{schema: t.schema_name, slug: slug}, ["TENANT_ADMIN"])
      body = %{"idempotency_key" => key()}
      unknown = call(:post, "/nothing-here", u, body)

      for {m, path} <- [
            {:post, "/legal-entities"},
            {:post, "/units/x/move"},
            {:patch, "/employees/x"}
          ] do
        conn = call(m, path, u, body)
        assert conn.status == 404, path
        assert strip(json(conn)) == strip(json(unknown))
      end
    end
  end
end
