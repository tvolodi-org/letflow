defmodule Letflow.Routers.MeAccessTest do
  @moduledoc """
  REQ-449 (GH #2237): `GET /me/access` on `Letflow.Routers.Me`, the caller's effective roles,
  permissions and platform-tenant flag.

  Two dispatch styles, as elsewhere in this suite:

    * direct `Letflow.Routers.Me.call/2` with a hand-set `auth_context` (the router's own
      `:match` -> `Letflow.Plugs.Authorize` -> `:dispatch` chain runs for real), for the role
      grid, the exact body shape and the cross-tenant checks;
    * the full `Letflow.Router.call/2` pipeline with the OIDC sentinel token, for the 401 case
      and for the no-cache criterion (a role removed from the caller's group between two
      requests with the identical JWT), following
      `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs`.

  The expected permission set is computed here from `Authorization.permissions/0` and
  `Authorization.has_permission?/2` (plus the platform-scope filter), independently of the
  handler.

  `async: false`: tenant provisioning and the platform-tenant pin are VM-global.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Identity
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @opts Letflow.Routers.Me.init([])

  defp access(ctx) do
    conn(:get, "/access")
    |> assign(:auth_context, ctx)
    |> assign(:trace_id, "req449-me-access-test-trace-id")
    |> then(&Letflow.Routers.Me.call(&1, @opts))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # Independent of the handler: platform-scope permissions only in the platform tenant.
  defp expected_permissions(role_names, platform_tenant?) do
    roles = Authorization.effective_roles(role_names, platform_tenant?)

    # no roles: only what every role holds (the role-agnostic grants)
    holders = if roles == [], do: Authorization.roles(), else: roles

    for permission <- Authorization.permissions(),
        if(roles == [],
          do: Enum.all?(holders, &Authorization.role_allows?(&1, permission)),
          else: Authorization.has_permission?(holders, permission)
        ),
        platform_tenant? or Authorization.permission_scope(permission) == :tenant,
        do: Atom.to_string(permission)
  end

  defp sorted_expected(role_names, platform_tenant?),
    do: role_names |> expected_permissions(platform_tenant?) |> Enum.sort()

  describe "AC1/AC2: the eight roles and the empty role list, non-platform tenant" do
    setup do
      Fixture.unpin!()
      %{a: tenant} = Fixture.two_tenants!()
      {:ok, tenant: tenant}
    end

    for role_atom <- Authorization.roles(),
        role_atom != :PLATFORM_ADMIN,
        role = Atom.to_string(role_atom) do
      test "#{role}: 200, roles == [role], permissions equal the computed set, platform_tenant false",
           %{tenant: tenant} do
        role = unquote(role)
        conn = access(Fixture.auth_context(tenant, [role]))

        assert conn.status == 200
        body = json(conn)
        assert body["roles"] == [role]
        assert body["permissions"] == sorted_expected([role], false)
        assert body["platform_tenant"] == false

        platform = Authorization.platform_permissions() |> Enum.map(&Atom.to_string/1)
        assert body["permissions"] -- platform == body["permissions"]
      end
    end

    test "PLATFORM_ADMIN outside the platform tenant: 200, role dropped (REQ-447), no platform scope",
         %{tenant: tenant} do
      conn = access(Fixture.auth_context(tenant, ["PLATFORM_ADMIN"]))

      assert conn.status == 200
      body = json(conn)
      assert body["roles"] == []
      assert body["permissions"] == ["MyAccessRead", "MyModulesRead"]
      assert body["platform_tenant"] == false
    end

    test "an empty role list: 200 and only the role-agnostic permissions", %{tenant: tenant} do
      conn = access(Fixture.auth_context(tenant, []))

      assert conn.status == 200

      assert json(conn) == %{
               "roles" => [],
               "permissions" => ["MyAccessRead", "MyModulesRead"],
               "platform_tenant" => false
             }

      assert json(conn)["permissions"] == sorted_expected([], false)
    end

    test "TENANT_ADMIN has no platform-scope permission", %{tenant: tenant} do
      body = json(access(Fixture.auth_context(tenant, ["TENANT_ADMIN"])))

      for permission <- Authorization.platform_permissions() do
        refute Atom.to_string(permission) in body["permissions"]
      end

      assert body["platform_tenant"] == false
      assert "TokensManage" in body["permissions"]
    end

    test "duplicate and unknown role strings are collapsed or dropped", %{tenant: tenant} do
      body =
        json(access(Fixture.auth_context(tenant, ["TASK_WORKER", "TASK_WORKER", "NOT_A_ROLE"])))

      assert body["roles"] == ["TASK_WORKER"]
      assert body["permissions"] == sorted_expected(["TASK_WORKER"], false)
    end
  end

  describe "AC2: platform tenant" do
    test "a platform-tenant PLATFORM_ADMIN has every permission and platform_tenant true" do
      %{p: platform} = Fixture.three_tenants!()
      Fixture.pin!(platform.tenant_id)

      conn = access(Fixture.auth_context(platform, ["PLATFORM_ADMIN"]))

      assert conn.status == 200
      body = json(conn)
      assert body["roles"] == ["PLATFORM_ADMIN"]
      assert body["platform_tenant"] == true

      assert body["permissions"] ==
               Authorization.permissions() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert body["permissions"] == sorted_expected(["PLATFORM_ADMIN"], true)
    end

    test "a TENANT_ADMIN of the platform tenant still has no platform-scope permission" do
      %{p: platform} = Fixture.three_tenants!()
      Fixture.pin!(platform.tenant_id)

      body = json(access(Fixture.auth_context(platform, ["TENANT_ADMIN"])))

      assert body["platform_tenant"] == true
      assert body["roles"] == ["TENANT_ADMIN"]

      for permission <- Authorization.platform_permissions() do
        refute Atom.to_string(permission) in body["permissions"]
      end
    end
  end

  describe "AC3: exact body shape" do
    test "exactly roles, permissions, platform_tenant; full-body equality for TENANT_AUDITOR" do
      Fixture.unpin!()
      %{a: tenant} = Fixture.two_tenants!()
      ctx = Fixture.auth_context(tenant, ["TENANT_AUDITOR"])

      conn = access(ctx)
      body = json(conn)

      assert Enum.sort(Map.keys(body)) == ["permissions", "platform_tenant", "roles"]

      assert body == %{
               "roles" => ["TENANT_AUDITOR"],
               "permissions" => sorted_expected(["TENANT_AUDITOR"], false),
               "platform_tenant" => false
             }

      assert body["permissions"] == Enum.sort(body["permissions"])
      refute conn.resp_body =~ ctx.user_id
      refute conn.resp_body =~ tenant.tenant_id
    end
  end

  describe "AC5: cross-tenant (INV-10)" do
    test "a caller of tenant A never sees tenant B's roles or permissions, whatever the request carries" do
      Fixture.unpin!()
      %{a: a, b: b} = Fixture.two_tenants!()

      a_ctx = Fixture.auth_context(a, ["TENANT_AUDITOR"])
      b_ctx = Fixture.auth_context(b, ["TENANT_ADMIN"])

      a_body = json(access(a_ctx))
      b_body = json(access(b_ctx))

      assert a_body["roles"] == ["TENANT_AUDITOR"]
      assert b_body["roles"] == ["TENANT_ADMIN"]
      assert a_body["permissions"] == sorted_expected(["TENANT_AUDITOR"], false)
      assert b_body["permissions"] == sorted_expected(["TENANT_ADMIN"], false)

      only_b = b_body["permissions"] -- a_body["permissions"]
      assert only_b != []
      assert only_b -- a_body["permissions"] == only_b
      refute "TENANT_ADMIN" in a_body["roles"]

      # tenant selectors from header / query / body are never read
      spoofed =
        conn(:get, "/access?tenant_id=#{b.tenant_id}", %{"tenant_id" => b.tenant_id})
        |> put_req_header("x-tenant-id", b.tenant_id)
        |> assign(:auth_context, a_ctx)
        |> assign(:trace_id, "req449-me-access-spoof")
        |> then(&Letflow.Routers.Me.call(&1, @opts))

      assert spoofed.status == 200
      assert json(spoofed) == a_body
    end
  end

  # ── Full pipeline (OIDC sentinel token) ──────────────────────────────────

  describe "AC4/AC5: full pipeline, same JWT" do
    setup do
      Fixture.unpin!()
      Letflow.Support.BpmDefaultRealmDisplacement.displace!()

      %{tenant: tenant} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "bpm-default-tenant",
          display_name: "REQ-449 Me Access Test Tenant",
          oidc_mode: :enabled,
          idp_realm_id: "bpm-default"
        )

      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)
      {:ok, tenant: tenant, schema_name: schema_name}
    end

    defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

    defp oidc_get(path) do
      conn(:get, path)
      |> put_req_header("authorization", "Bearer valid-test-token")
      |> dispatch()
    end

    defp grant_role!(role_name, user_id, schema_name) do
      {:ok, group} =
        Identity.create_group(%{"name" => "req449-#{role_name}-#{Ecto.UUID.generate()}"},
          prefix: schema_name
        )

      {:ok, _role} =
        %TenantRole{}
        |> TenantRole.changeset(%{name: role_name, kind: :platform_role, group_id: group.id})
        |> Repo.insert(prefix: schema_name)

      {:ok, %{member: _member, created: true}} =
        Identity.add_group_member(group.id, user_id, prefix: schema_name)

      group
    end

    # A second counted tenant-wide admin, so removing the caller from the TENANT_ADMIN group is
    # not refused as the removal of the last admin (REQ-497).
    defp other_admin_member!(group_id, schema_name) do
      n = Ecto.UUID.generate()

      user =
        %User{}
        |> Ecto.Changeset.change(%{
          username: "req449-other-admin-#{n}",
          display_name: "REQ-449 Other Admin",
          email: "req449-other-admin-#{n}@example.com",
          password_hash: "__NO_PASSWORD_SET__",
          status: :active,
          auth_source: :internal
        })
        |> Repo.insert!(prefix: schema_name)

      Repo.insert!(%GroupMember{group_id: group_id, user_id: user.id}, prefix: schema_name)
      user
    end

    test "a role removed from the caller's group is absent from the next response (no cache)",
         %{schema_name: schema_name} do
      # JIT-provision the OIDC user so its id is known before the roles are granted.
      user_id = oidc_get("/api/v1/me/access").assigns.auth_context.user_id
      assert is_binary(user_id)

      admin_group = grant_role!("TENANT_ADMIN", user_id, schema_name)
      _worker_group = grant_role!("TASK_WORKER", user_id, schema_name)
      _other = other_admin_member!(admin_group.id, schema_name)

      first = oidc_get("/api/v1/me/access")
      assert first.status == 200
      first_body = json(first)
      assert first_body["roles"] == ["TASK_WORKER", "TENANT_ADMIN"]
      assert first_body["permissions"] == sorted_expected(["TASK_WORKER", "TENANT_ADMIN"], false)

      assert :ok = Identity.remove_group_member(admin_group.id, user_id, prefix: schema_name)

      second = oidc_get("/api/v1/me/access")
      assert second.status == 200
      second_body = json(second)
      assert second_body["roles"] == ["TASK_WORKER"]
      assert second_body["permissions"] == sorted_expected(["TASK_WORKER"], false)

      admin_only = first_body["permissions"] -- second_body["permissions"]
      assert "TokensManage" in admin_only
      assert admin_only -- second_body["permissions"] == admin_only
    end

    test "a request without a bearer token answers 401" do
      conn = conn(:get, "/api/v1/me/access") |> dispatch()
      assert conn.status == 401
    end

    test "a request with a garbage bearer token answers 401" do
      conn =
        conn(:get, "/api/v1/me/access")
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> dispatch()

      assert conn.status == 401
    end
  end
end
