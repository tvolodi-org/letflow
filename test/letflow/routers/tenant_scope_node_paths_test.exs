defmodule Letflow.Routers.TenantScopeNodePathsTest do
  @moduledoc """
  REQ-496 / GH #2530 AC7, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §6.5, D11 and §9 T-29 (spec `test/specs/REQ-496.md`):
  `GET /api/v1/tenant/scope-node-paths/consistency`.

    * TENANT_ADMIN (holds `:UsersGroupsRolesManage`) gets 200 with the documented string-keyed
      shape; clean data reports `"ok"`; each seeded defect (orphan, cycle, depth 13) is reported.
    * PROCESS_DESIGNER, PROCESS_OPERATOR and TENANT_AUDITOR get the generic 403.
    * The tenant comes from auth only: `?tenant=` / `?prefix=` naming tenant B are ignored, and
      tenant B's seeded orphan never appears in tenant A's answer (INV-1/INV-5).
    * Read-only: rows are unchanged after the call; a POST to the path is not a 200.
    * Once through the full `Letflow.Router` pipeline with a real API token (the mount).

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.TenantFixture

  @router_opts Letflow.Routers.TenantScopeNodePaths.init([])
  @list_keys ["orphans", "cycles", "depth_exceeded", "malformed", "stale_paths"]

  setup do
    a = TenantFixture.provisioned_tenant!(slug_prefix: "req496-snp-a")
    b = TenantFixture.provisioned_tenant!(slug_prefix: "req496-snp-b")
    {:ok, a: a, b: b}
  end

  defp call(tenant, roles, method, path) do
    Plug.Test.conn(method, path)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req496-snp-router-trace")
    |> Letflow.Routers.TenantScopeNodePaths.call(@router_opts)
  end

  defp consistency(tenant, roles), do: call(tenant, roles, :get, "/consistency")

  defp seed!(schema, rows) do
    now = NaiveDateTime.utc_now()

    entries =
      for {node_id, path, depth} <- rows do
        %{node_id: node_id, path: path, depth: depth, inserted_at: now, updated_at: now}
      end

    {_count, _} = Repo.insert_all("scope_node_paths", entries, prefix: schema)
    :ok
  end

  defp seed_defects!(schema) do
    deep =
      for k <- 1..13 do
        segments = for i <- 1..k, do: "d#{i}"
        {"d#{k}", "/" <> Enum.join(segments, "/") <> "/", k}
      end

    seed!(
      schema,
      [{"orphan_a", "/ghost/orphan_a/", 2}, {"A", "/B/A/", 2}, {"B", "/A/B/", 2}] ++ deep
    )
  end

  defp rows(schema) do
    Repo.all(Node, prefix: schema) |> Enum.map(&{&1.node_id, &1.path, &1.depth}) |> Enum.sort()
  end

  test "TENANT_ADMIN gets 200 with the documented shape; clean data is ok", %{a: a} do
    for {id, parent} <- [{"r", nil}, {"c", "r"}] do
      {:ok, _} = ScopeNodePaths.write({:insert, id, parent}, a.schema_name)
    end

    conn = consistency(a, ["TENANT_ADMIN"])
    assert conn.status == 200, conn.resp_body
    body = Jason.decode!(conn.resp_body)

    assert Enum.sort(Map.keys(body)) ==
             Enum.sort([
               "status",
               "checked_nodes",
               "max_depth",
               "counts",
               "truncated" | @list_keys
             ])

    assert body["status"] == "ok"
    assert body["checked_nodes"] == 2
    assert body["max_depth"] == 12
    assert body["truncated"] == false
    assert body["counts"] == Map.new(@list_keys, &{&1, 0})
    for key <- @list_keys, do: assert(body[key] == [], key)
  end

  test "each seeded defect is reported", %{a: a} do
    seed_defects!(a.schema_name)

    body = Jason.decode!(consistency(a, ["TENANT_ADMIN"]).resp_body)

    assert body["status"] == "inconsistent"
    assert body["orphans"] == ["orphan_a"]
    assert body["cycles"] == ["A", "B"]
    assert body["depth_exceeded"] == ["d13"]
    assert body["counts"]["orphans"] == 1
    assert body["counts"]["cycles"] == 2
    assert body["counts"]["depth_exceeded"] == 1
    assert body["checked_nodes"] == 16
  end

  test "403 without :UsersGroupsRolesManage", %{a: a} do
    for roles <- [["PROCESS_DESIGNER"], ["PROCESS_OPERATOR"], ["TENANT_AUDITOR"], ["TASK_WORKER"]] do
      conn = consistency(a, roles)
      assert conn.status == 403, "#{inspect(roles)}: #{conn.status} #{conn.resp_body}"
      refute conn.resp_body =~ "checked_nodes"
    end
  end

  test "the tenant comes from auth only; tenant B's rows never appear in tenant A's answer", %{
    a: a,
    b: b
  } do
    {:ok, _} = ScopeNodePaths.write({:insert, "a_root", nil}, a.schema_name)
    seed!(b.schema_name, [{"orphan_b", "/ghost/orphan_b/", 2}])

    plain = consistency(a, ["TENANT_ADMIN"])

    steered =
      call(
        a,
        ["TENANT_ADMIN"],
        :get,
        "/consistency?tenant=#{b.tenant.slug}&prefix=#{b.schema_name}&tenant_id=#{b.tenant_id}"
      )

    for conn <- [plain, steered] do
      assert conn.status == 200, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert body["checked_nodes"] == 1
      refute conn.resp_body =~ "orphan_b"
      refute conn.resp_body =~ b.schema_name
      refute conn.resp_body =~ b.tenant_id
    end

    # Tenant B's own answer does report its orphan.
    b_body = Jason.decode!(consistency(b, ["TENANT_ADMIN"]).resp_body)
    assert b_body["orphans"] == ["orphan_b"]
  end

  test "read-only: rows unchanged after the call; POST to the path is not 200", %{a: a} do
    seed_defects!(a.schema_name)
    before = rows(a.schema_name)

    assert consistency(a, ["TENANT_ADMIN"]).status == 200
    post = call(a, ["TENANT_ADMIN"], :post, "/consistency")
    refute post.status == 200, post.resp_body

    assert rows(a.schema_name) == before
  end

  test "mounted at /api/v1/tenant/scope-node-paths in the full pipeline", %{a: a} do
    token = PlatformTenantFixture.mint_token!(a, ["TENANT_ADMIN"])

    conn =
      PlatformTenantFixture.api_conn(
        :get,
        "/api/v1/tenant/scope-node-paths/consistency",
        token,
        a.tenant.slug,
        nil
      )
      |> PlatformTenantFixture.dispatch_api()

    assert conn.status == 200, conn.resp_body
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end
end
