Code.require_file("register_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.StorekeeperAssetsTest do
  @moduledoc """
  C19 and T-1570 (D-097, owner-approved): the STOREKEEPER reads and posts assets only where the
  tenant switched it on (a per-tenant overlay, `Letflow.Api.TenantGrants`; the manifest `role_grants`
  stays empty, so the baseline matrix of 0055 D7 / 0081 D3 is unchanged: SA-1). The tenant administrator
  holds all five asset permissions. A tenant that installs `assets` now gets read and post (G1);
  a tenant without the key stays off (G3). Everything goes through the full `Letflow.Router` with real
  OIDC bearer tokens on committed tenants (Sandbox `:auto`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity.User
  alias Letflow.Modules.TenantModule
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @a1 "11111111-1111-4111-8111-111111111111"
  @a2 "12121212-1212-4212-8212-121212121212"
  @u1 "44444444-4444-4444-8444-444444444444"
  @u2 "46464646-4646-4646-8646-464646464646"
  @p "47474747-4747-4747-8747-474747474747"
  @l1 "33333333-3333-4333-8333-333333333333"
  @r1 "55555555-5555-4555-8555-555555555555"

  @all [:AssetsRead, :AssetsPost, :AssetsReverse, :AssetsReconcile, :AssetsCardWrite]

  test "SA-1 the baseline matrix: storekeeper holds no asset atom; the administrators hold all five" do
    for p <- @all, do: refute(Authorization.role_allows?(:STOREKEEPER, p), inspect(p))

    for role <- [:TENANT_ADMIN, :PLATFORM_ADMIN], p <- @all do
      assert Authorization.role_allows?(role, p), "#{role} #{p}"
    end
  end

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    a = S.tenant!("sk-a", ctx.names.a)
    b = S.tenant!("sk-b", ctx.names.b)

    Map.merge(ctx, %{
      a: a,
      b: b,
      sk_a: S.token(ctx, :a, ["STOREKEEPER"], sub: "sk-a"),
      sk_b: S.token(ctx, :b, ["STOREKEEPER"], sub: "sk-b")
    })
  end

  defp seed!(schema) do
    here = S.side(@u1, @r1, %{location: @l1})

    S.post!(schema, "commission", %{
      document_type: "commission_doc",
      document_id: "doc-1",
      lines: [S.line(@a1, "3", %{to: here})]
    })

    S.post!(schema, "commission", %{
      document_id: "doc-2",
      lines: [S.line(@a2, "2", %{to: S.side(@u2, @r1)})]
    })
  end

  defp call(method, path, token, body \\ %{}) do
    Plug.Test.conn(method, S.base() <> path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp api(method, path, token, body \\ %{}) do
    Plug.Test.conn(method, "/api/v1" <> path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  @routes [
    {:get, "/balances"},
    {:get, "/movements"},
    {:get, "/documents"},
    {:post, "/documents"},
    {:get, "/reconcile"},
    {:post, "/cards"}
  ]

  test "SA-2 the tenant administrator reads the register", ctx do
    seed!(ctx.a.schema_name)
    admin = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-a")

    for path <- ["/balances", "/movements", "/documents"] do
      conn = S.get(path, admin)
      assert conn.status == 200, "#{path}: #{conn.status} #{conn.resp_body}"
    end

    assert length(S.json(S.get("/balances", admin))["rows"]) == 2
  end

  defp set_settings!(schema, fun) do
    row = Letflow.Repo.get_by!(TenantModule, [module_id: "assets"], prefix: schema)

    row
    |> TenantModule.settings_changeset(%{settings: fun.(row.settings)})
    |> Letflow.Repo.update!(prefix: schema)
  end

  defp off!(schema), do: set_settings!(schema, &Map.delete(&1, "storekeeper_grants"))

  defp grants_json(conn), do: S.json(conn)["storekeeper"]

  test "G1 a tenant that installs assets now gets read and post for the storekeeper only", ctx do
    seed!(ctx.a.schema_name)
    row = Letflow.Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.a.schema_name)
    assert row.settings["storekeeper_grants"] == ["AssetsRead", "AssetsPost"]

    for path <- ["/balances", "/movements", "/documents"] do
      conn = call(:get, path, ctx.sk_a)
      assert conn.status == 200, "#{path}: #{conn.status} #{conn.resp_body}"
    end

    # post passes the gate (the empty body is then refused on its merits, not with 403)
    refute call(:post, "/documents", ctx.sk_a).status == 403
  end

  test "G2 reverse, reconcile and card write stay administrator-only with the grant on", ctx do
    seed!(ctx.a.schema_name)

    for {method, path} <- [
          {:get, "/reconcile"},
          {:post, "/cards"},
          {:post, "/documents/#{S.uuid()}/reverse"}
        ] do
      conn = call(method, path, ctx.sk_a)
      assert conn.status == 403, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
    end
  end

  test "G3 SA-3 a tenant without the key (existing tenant) refuses every asset route", ctx do
    seed!(ctx.a.schema_name)
    off!(ctx.a.schema_name)

    for {method, path} <- @routes do
      conn = call(method, path, ctx.sk_a)
      assert conn.status == 403, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
    end
  end

  test "G4 G5 the tenant administrator switches the grant on and off", ctx do
    seed!(ctx.a.schema_name)
    off!(ctx.a.schema_name)
    admin = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-a")

    got = api(:get, "/tenant/role-grants", admin)
    assert got.status == 200, got.resp_body
    assert grants_json(got) == []
    assert S.json(got)["grantable"] == %{"storekeeper" => ["AssetsRead", "AssetsPost"]}

    on = api(:put, "/tenant/role-grants", admin, %{"storekeeper" => ["AssetsRead"]})
    assert on.status == 200, on.resp_body
    assert grants_json(on) == ["AssetsRead"]
    assert call(:get, "/balances", ctx.sk_a).status == 200
    assert call(:post, "/documents", ctx.sk_a).status == 403

    both =
      api(:put, "/tenant/role-grants", admin, %{"storekeeper" => ["AssetsPost", "AssetsRead"]})

    assert grants_json(both) == ["AssetsRead", "AssetsPost"]
    refute call(:post, "/documents", ctx.sk_a).status == 403

    offc = api(:put, "/tenant/role-grants", admin, %{"storekeeper" => []})
    assert offc.status == 200
    assert call(:get, "/balances", ctx.sk_a).status == 403

    # other settings keys survive, and the change is audited
    set_settings!(ctx.a.schema_name, &Map.put(&1, "currency", "USD"))
    _ = api(:put, "/tenant/role-grants", admin, %{"storekeeper" => ["AssetsRead"]})
    row = Letflow.Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.a.schema_name)
    assert row.settings["currency"] == "USD"

    assert Letflow.Repo.exists?(
             from(e in Letflow.Audit.Entry, where: e.action == "tenant.role_grants_changed"),
             prefix: ctx.a.schema_name
           )
  end

  test "G8 the list is closed: reverse, reconcile, card write and junk are 422", ctx do
    admin = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-a")

    for bad <- [
          ["AssetsReverse"],
          ["AssetsReconcile"],
          ["AssetsCardWrite"],
          ["Nope"],
          ["AssetsRead", "AssetsReverse"]
        ] do
      conn = api(:put, "/tenant/role-grants", admin, %{"storekeeper" => bad})
      assert conn.status == 422, "#{inspect(bad)}: #{conn.status}"
    end

    assert api(:put, "/tenant/role-grants", admin, %{"x" => 1}).status == 422
    row = Letflow.Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.a.schema_name)
    assert row.settings["storekeeper_grants"] == ["AssetsRead", "AssetsPost"]
  end

  test "G10 only a tenant administrator may read or switch the grant", ctx do
    for role <- ["STOREKEEPER", "TENANT_AUDITOR", "PROCESS_DESIGNER"] do
      tok = S.token(ctx, :a, [role], sub: "u-" <> String.downcase(role))
      assert api(:get, "/tenant/role-grants", tok).status == 403, role
      assert api(:put, "/tenant/role-grants", tok, %{"storekeeper" => []}).status == 403, role
    end

    row = Letflow.Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.a.schema_name)
    assert row.settings["storekeeper_grants"] == ["AssetsRead", "AssetsPost"]
  end

  test "G10b assets not installed: 404", ctx do
    {:ok, _} =
      Letflow.Modules.Installs.uninstall("assets", Ecto.UUID.generate(),
        prefix: ctx.a.schema_name,
        rationale: "test"
      )

    admin = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-a")

    assert api(:put, "/tenant/role-grants", admin, %{"storekeeper" => []}).status in [404, 409]
  end

  test "G7 INV-10 A on, B off: B's storekeeper is refused; A's admin cannot reach B", ctx do
    seed!(ctx.a.schema_name)
    seed!(ctx.b.schema_name)
    off!(ctx.b.schema_name)
    admin_a = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-a")

    assert call(:get, "/balances", ctx.sk_a).status == 200
    assert call(:get, "/balances", ctx.sk_b).status == 403

    # A's admin switching "its" grant (on or off) never changes B
    _ = api(:put, "/tenant/role-grants", admin_a, %{"storekeeper" => []})
    assert call(:get, "/balances", ctx.sk_a).status == 403

    _ =
      api(:put, "/tenant/role-grants", admin_a, %{"storekeeper" => ["AssetsRead", "AssetsPost"]})

    assert call(:get, "/balances", ctx.sk_b).status == 403

    brow = Letflow.Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.b.schema_name)
    refute Map.has_key?(brow.settings, "storekeeper_grants")

    # a tenant-A token for the realm of A cannot read B's overlay by any body field
    conn =
      api(:put, "/tenant/role-grants", admin_a, %{
        "storekeeper" => [],
        "tenant_id" => ctx.b.tenant_id
      })

    assert conn.status == 200
    brow = Letflow.Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.b.schema_name)
    refute Map.has_key?(brow.settings, "storekeeper_grants")
  end

  test "G11 /me/access (and so the sidebar) follows the grant", ctx do
    on = S.json(api(:get, "/me/access", ctx.sk_a))["permissions"]
    assert "AssetsRead" in on and "AssetsPost" in on
    for p <- ["AssetsReverse", "AssetsReconcile", "AssetsCardWrite"], do: refute(p in on, p)

    off!(ctx.a.schema_name)
    offp = S.json(api(:get, "/me/access", ctx.sk_a))["permissions"]
    refute "AssetsRead" in offp or "AssetsPost" in offp

    # the list equals what the gate allows for the same roles
    ctx_a = %Authorization.AccessContext{
      user_id: "u",
      roles: [:STOREKEEPER],
      role_overlay: %{STOREKEEPER: [:AssetsRead]}
    }

    assert Authorization.evaluate_access(ctx_a, :AssetsRead).kind == :Allow
    assert Authorization.evaluate_access(ctx_a, :AssetsPost).kind == :Deny403
  end

  test "SA-4 INV-10: B's administrator sees none of A's rows, also by A's ids", ctx do
    seed!(ctx.a.schema_name)
    seed!(ctx.b.schema_name)
    admin_a = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-a")
    admin_b = S.token(ctx, :b, ["TENANT_ADMIN"], sub: "admin-b")

    assert length(S.json(S.get("/balances", admin_a))["rows"]) == 2

    for path <- ["/balances", "/movements", "/documents"] do
      refute inspect(S.json(S.get(path, admin_b))) =~ ctx.a.schema_name, path
    end

    # an id from A's tenant opens nothing in B
    assert S.get("/documents/#{S.uuid()}", admin_b).status in [403, 404]

    # B's storekeeper is refused as well once B is off
    off!(ctx.b.schema_name)
    assert S.get("/balances", ctx.sk_b).status == 403
  end

  test "SA-5 scoped caller: a storekeeper granted on U1 is still refused", ctx do
    s = S.tenant!("sk-s", ctx.names.s)
    schema = s.schema_name
    seed!(schema)

    {:ok, _} = ScopeNodePaths.write({:insert, @p, nil}, schema)
    {:ok, _} = ScopeNodePaths.write({:insert, @u1, @p}, schema)
    {:ok, _} = ScopeNodePaths.write({:insert, @u2, @p}, schema)

    off!(schema)
    tok = S.token(ctx, :s, ["STOREKEEPER"], sub: "sk-scoped")
    assert S.get("/balances", tok).status == 403

    _ = RSG.raw_delete_rows!(schema, RSG.group_of!(schema, "STOREKEEPER"), "STOREKEEPER")
    user = Letflow.Repo.one!(from(u in User, where: u.username == "sk-scoped"), prefix: schema)
    :ok = RSG.raw_user_row!(schema, user.id, "STOREKEEPER", @u1)

    assert S.get("/balances", tok).status == 403
  end
end
