defmodule Letflow.Routers.IntegrationMappingsTest do
  @moduledoc """
  REQ-565 slice 1 (GH #3201): the five `/integration-mappings` routes. Each `describe` names its
  acceptance criterion (R-P criterion 10, R-N criterion 11, R-X criterion 13, R-Au criterion 14,
  R-V criterion 2/3).

  Dispatch: real `Letflow.Routers.IntegrationMappings.call/2`. `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Audit
  alias Letflow.Routers.IntegrationMappings, as: Router
  alias Letflow.TenantFixture

  @opts Router.init([])
  @admin ["TENANT_ADMIN"]
  @denied [["TASK_WORKER"], ["TENANT_AUDITOR"], ["PROCESS_DESIGNER"], ["PROCESS_OPERATOR"]]

  defp call(method, path, tenant, roles, body \\ %{}) do
    conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:scoped_opts, prefix: tenant.schema_name)
    |> assign(:trace_id, "req565-trace")
    |> Router.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp body(name, rules \\ [%{"const" => "v", "to" => "x"}]),
    do: %{"name" => name, "direction" => "outbound", "rules" => rules}

  defp create!(tenant, name \\ "m1", rules \\ [%{"const" => "v", "to" => "x"}]) do
    conn = call(:post, "/", tenant, @admin, body(name, rules))
    assert conn.status == 201
    json(conn)
  end

  defp tenant!(slug), do: TenantFixture.provisioned_tenant!(slug_prefix: slug)

  defp audit_entries(tenant) do
    {:ok, %{items: items}} =
      Audit.list_entries(%{
        prefix: tenant.schema_name,
        page_size: 100,
        resource_type: "integration_mapping"
      })

    items
  end

  defp count(tenant), do: length(Letflow.IntegrationMappings.list(tenant.schema_name))

  describe "R-P1 the admin may use all five routes" do
    test "201 / 200 / 200 / 200 / 204 with the documented fields" do
      t = tenant!("r565-p1")
      m = create!(t)

      assert Enum.sort(Map.keys(m)) ==
               ~w(direction id inserted_at name rules updated_at updated_by)

      assert call(:get, "/", t, @admin) |> then(&{&1.status, json(&1)["items"]}) ==
               {200, [m]}

      assert call(:get, "/#{m["id"]}", t, @admin) |> then(&{&1.status, json(&1)}) == {200, m}

      put = call(:put, "/#{m["id"]}", t, @admin, body("m2", [%{"const" => 1, "to" => "y"}]))
      assert put.status == 200
      assert %{"name" => "m2", "rules" => [%{"const" => 1, "to" => "y"}]} = json(put)

      assert call(:delete, "/#{m["id"]}", t, @admin).status == 204
      assert count(t) == 0
    end
  end

  describe "R-P2 other roles get 403 on all five routes" do
    test "TASK_WORKER, TENANT_AUDITOR, PROCESS_DESIGNER, PROCESS_OPERATOR" do
      t = tenant!("r565-p2")
      m = create!(t)
      id = m["id"]

      for roles <- @denied,
          {method, path, b} <- [
            {:post, "/", body("zz")},
            {:get, "/", %{}},
            {:get, "/#{id}", %{}},
            {:put, "/#{id}", body("zz")},
            {:delete, "/#{id}", %{}}
          ] do
        assert call(method, path, t, roles, b).status == 403,
               "#{inspect(roles)} #{method} #{path}"
      end

      assert count(t) == 1
    end

    test "the permission is held by TENANT_ADMIN and PLATFORM_ADMIN (platform tenant) only" do
      holders =
        for r <- Authorization.roles(),
            Authorization.has_permission_in_scope?([r], :IntegrationMappingsManage, true),
            do: r

      assert Enum.sort(holders) == [:PLATFORM_ADMIN, :TENANT_ADMIN]
      assert :IntegrationMappingsManage in Authorization.core_permissions()
      assert Authorization.permission_scope(:IntegrationMappingsManage) == :tenant
    end
  end

  describe "R-N INV-5: not-found and forbidden are indistinguishable" do
    test "R-N1 a role without the permission sees identical replies for existing and absent ids" do
      t = tenant!("r565-n1")
      m = create!(t)
      absent = Ecto.UUID.generate()

      for roles <- @denied, {method, b} <- [{:get, %{}}, {:put, body("q")}, {:delete, %{}}] do
        e = call(method, "/#{m["id"]}", t, roles, b)
        a = call(method, "/#{absent}", t, roles, b)
        assert e.status == 403

        assert {e.status, e.resp_body, get_resp_header(e, "content-type")} ==
                 {a.status, a.resp_body, get_resp_header(a, "content-type")}
      end
    end

    test "R-N2 a holder gets one fixed 404 for absent, malformed and other-tenant ids" do
      a = tenant!("r565-n2a")
      b = tenant!("r565-n2b")
      other = create!(b)

      replies =
        for id <- [Ecto.UUID.generate(), "not-a-uuid", other["id"]],
            {method, bd} <- [{:get, %{}}, {:put, body("q")}, {:delete, %{}}] do
          c = call(method, "/#{id}", a, @admin, bd)
          assert c.status == 404
          {method, c.resp_body}
        end

      for method <- [:get, :put, :delete],
          do:
            assert(
              replies |> Enum.filter(&(elem(&1, 0) == method)) |> Enum.uniq() |> length() == 1
            )
    end
  end

  describe "R-X INV-10 cross-tenant negatives" do
    test "R-X1 tenant B cannot GET, PUT or DELETE A's mapping; A's row is unchanged" do
      a = tenant!("r565-x1a")
      b = tenant!("r565-x1b")
      m = create!(a, "only-a", [%{"const" => "keep", "to" => "x"}])

      unknown = Ecto.UUID.generate()

      for {method, bd} <- [{:get, %{}}, {:put, body("hijack")}, {:delete, %{}}] do
        c = call(method, "/#{m["id"]}", b, @admin, bd)
        u = call(method, "/#{unknown}", b, @admin, bd)
        assert {c.status, c.resp_body} == {u.status, u.resp_body}
        assert c.status == 404
      end

      assert json(call(:get, "/#{m["id"]}", a, @admin)) == m
      assert json(call(:get, "/", b, @admin))["items"] == []
      assert count(b) == 0
    end

    test "R-X2 a tenant_id in the query or body is ignored" do
      a = tenant!("r565-x2a")
      b = tenant!("r565-x2b")

      c =
        conn(:post, "/?tenant_id=#{a.tenant_id}")
        |> Map.put(:body_params, Map.put(body("viaB"), "tenant_id", a.tenant_id))
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: b.tenant_id,
          roles: @admin
        })
        |> assign(:scoped_opts, prefix: b.schema_name)
        |> Router.call(@opts)

      assert c.status == 201
      refute Map.has_key?(json(c), "tenant_id")
      assert count(b) == 1
      assert count(a) == 0

      assert {:ok, %{tenant_id: tid}} =
               Letflow.IntegrationMappings.get(json(c)["id"], b.schema_name)

      assert tid == b.tenant_id
    end
  end

  describe "R-V validation over HTTP (criteria 2 and 3)" do
    test "each bad definition is one uniform 422 and nothing is stored" do
      t = tenant!("r565-v")
      create!(t, "taken")

      bad = [
        body(""),
        body(String.duplicate("a", 101)),
        body("taken"),
        Map.put(body("d1"), "direction", "sideways"),
        body("d2", for(i <- 1..101, do: %{"const" => 1, "to" => "k#{i}"})),
        body("d3", [%{"from" => String.duplicate("a", 201), "to" => "x"}]),
        body("d4", [%{"from" => "a.b.c.d.e.f.g.h.i", "to" => "x"}]),
        body("d5", [%{"to" => "x"}]),
        body("d6", [%{"from" => "a b", "to" => "x"}]),
        body("d7", [%{"const" => 1, "to" => "a"}, %{"const" => 2, "to" => "a.b"}]),
        body("d8", [%{"const" => 1, "to" => "a", "expr" => "1"}])
      ]

      replies =
        for b <- bad do
          c = call(:post, "/", t, @admin, b)
          assert c.status == 422, inspect(b) |> String.slice(0, 80)
          c.resp_body
        end

      assert replies |> Enum.uniq() |> length() == 1
      assert count(t) == 1
      assert length(audit_entries(t)) == 1
    end

    test "boundaries 100 rules and 8 segments are accepted" do
      t = tenant!("r565-vb")
      rules = for i <- 1..100, do: %{"const" => 1, "to" => "k#{i}"}
      assert call(:post, "/", t, @admin, body("big", rules)).status == 201

      deep = [%{"from" => "a.b.c.d.e.f.g.h", "to" => "x"}]
      assert call(:post, "/", t, @admin, body("deep", deep)).status == 201
    end

    test "PUT with a bad definition changes nothing" do
      t = tenant!("r565-vp")
      m = create!(t)
      c = call(:put, "/#{m["id"]}", t, @admin, Map.put(body("m1"), "direction", "x"))
      assert c.status == 422
      assert json(call(:get, "/#{m["id"]}", t, @admin)) == m
    end

    test "inert text is stored and returned verbatim as a const" do
      t = tenant!("r565-vi")

      rules =
        for {s, i} <- Enum.with_index(["\#{1+1}", "{{x}}", "$(x)"]),
            do: %{"const" => s, "to" => "k#{i}"}

      m = create!(t, "inert", rules)
      assert m["rules"] == rules
      assert json(call(:get, "/#{m["id"]}", t, @admin))["rules"] == rules
    end
  end

  describe "R-Au audit in the same transaction (criterion 14), no secrets (criterion 9)" do
    test "create, update, delete each leave one entry; no constants in the event" do
      t = tenant!("r565-au")
      marker = "CONST-MARKER-77"
      m = create!(t, "au", [%{"const" => marker, "to" => "x"}])
      id = m["id"]

      assert call(:put, "/#{id}", t, @admin, body("au2", [%{"const" => marker, "to" => "x"}])).status ==
               200

      assert call(:delete, "/#{id}", t, @admin).status == 204

      entries = audit_entries(t)
      assert Enum.sort(Enum.map(entries, & &1.action)) == ["create", "delete", "update"]
      assert Enum.all?(entries, &(&1.resource_id == id and is_binary(&1.actor_id)))
      refute inspect(entries) =~ marker
      refute inspect(entries) =~ "rules"
    end

    test "R-Au2 a duplicate-name create rolls back and leaves no audit entry" do
      t = tenant!("r565-au2")
      create!(t, "dup")
      before = length(audit_entries(t))
      assert call(:post, "/", t, @admin, body("dup")).status == 422
      assert length(audit_entries(t)) == before
    end

    test "R-C1 a tenant with a webhook secret_ref leaks nothing into mapping responses or audit" do
      t = tenant!("r565-c1")
      m = create!(t)
      text = inspect([m, audit_entries(t), call(:get, "/", t, @admin).resp_body])
      refute text =~ "sec://"
      refute text =~ ~r/secret/i
    end
  end

  describe "route table" do
    test "the five routes map to :IntegrationMappingsManage" do
      keys = for r <- Router.__authz_routes__(), do: {elem(r, 0), elem(r, 1), elem(r, 2)}
      assert length(keys) == 5
      assert Enum.all?(keys, fn {_m, _p, k} -> k == :IntegrationMappingsManage end)
    end
  end
end
