defmodule Letflow.ScopeEnforcementOnE2eTest do
  @moduledoc """
  REQ-519 slice 2f-b (GH #2535), AC 16, AC 17 and AC 22 (the route walk first), plus the platform
  tenant tests T-O7 / T-O8 of SEC C-6 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.2a, 4.8; tests T-Z*; spec
  `test/specs/REQ-519-2f-b.md`): ONE suite, real HTTP through the full `Letflow.Router` (OIDC
  users and API tokens), a real database. T-Z1, T-Z16 and T-Z17 reach `on` through the REAL guarded flip (the PUT, or
  `ScopeEnforcement.flip/4`; shadow evidence satisfied by a backdated raw audit entry and persisted
  counters); T-Z2, T-O7, T-O8 and T-Z15 store the mode directly with `ScopeEnforcementFixture`
  because the flip is not what they test (the gate would refuse their deliberately odd tenants).

    * T-Z0 the route walk is green FIRST (AC 22, SEC C-1);
    * T-Z1 the lifecycle: a scoped TASK_WORKER is served under `shadow`; after the interactive
      tenant-wide admin flips `shadow -> on` the SAME request is a uniform 403, a self-service read
      (`/me/memberships`) still works, a tenant-wide user and an API token are unaffected; the
      binding writers refuse to widen (`scope_required`) and the IdP sync suppresses a tenant-wide
      group for a user with scoped rows; `on -> shadow` with a reason restores today's behaviour
      byte for byte, and so does `-> off`;
    * T-Z2 a scoped-only TENANT_ADMIN is refused on the admin plane and on the flag route under `on`
      while the interactive tenant-wide admin reaches both (the turn-off path);
    * T-O7 / T-O8 the PLATFORM tenant stored `on` does not lock its PLATFORM_ADMIN out of the
      platform-scope routes (even through a group with ZERO rows), the flag route stays
      TENANT_ADMIN-only there, and in an ordinary `on` tenant a PLATFORM_ADMIN role is inert;
    * T-Z15..T-Z17 fail closed in `on`: a binding with zero rows denies (`:no_grant_rows`, uniform 403),
      and neither deleting a user's last scoped row nor retiring a referenced node can make a user
      tenant-wide.

  `async: false`: dedicated provisioned tenants (sandbox `:auto`), the VM-global `:oidc` config swap
  and platform pin.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.RouteScope
  alias Letflow.Api.Scope
  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.User
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.RouteInventory
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.SyncScopeFixture
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @flag_path "/api/v1/tenant/scope-enforcement"
  @tenant_wide_route "/api/v1/definitions"
  @self_service_route "/api/v1/me/memberships"
  @admin_plane_route "/api/v1/identity/tokens"
  @platform_route "/api/v1/tenants"
  @worker "TASK_WORKER"

  setup do
    original = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)
    Fixture.unpin!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp oidc_tenant!(prefix) do
    realm = Letflow.TenantSlugFixture.unique_realm(prefix)

    fx =
      TenantFixture.provisioned_tenant!(
        slug_prefix: prefix,
        display_name: "REQ-519 2f-b e2e tenant",
        oidc_mode: :enabled,
        idp_realm_id: realm
      )

    Map.put(fx, :realm, realm)
  end

  defp bearer(fx, sub), do: "Bearer realm-token:" <> fx.realm <> ":sub=" <> sub

  # One request through the FULL router as the OIDC user `sub` of the tenant.
  defp request(fx, sub, method, path, body) do
    conn = conn(method, path, if(body, do: Jason.encode!(body), else: nil))

    conn =
      if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", bearer(fx, sub))
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp get(fx, sub, path), do: request(fx, sub, :get, path, nil)
  defp json(conn), do: Jason.decode!(conn.resp_body)

  # The JIT-provisioned user of `sub`: the auth pipeline alone provisions it (a role-less user has
  # no permission for any route, so a routed request would only answer 403).
  defp user_of!(fx, sub) do
    conn =
      :get
      |> conn("/whatever")
      |> put_req_header("authorization", bearer(fx, sub))
      |> AuthPipeline.call(AuthPipeline.init([]))

    refute conn.halted, "provisioning failed: #{conn.resp_body}"
    Repo.get!(User, conn.assigns.auth_context.user_id, prefix: fx.schema_name)
  end

  # An OIDC user holding TENANT_ADMIN through the tenant-wide default group.
  defp admin!(fx, sub) do
    user = user_of!(fx, sub)
    _ = TokenMintFixture.grant_roles!(fx.schema_name, user.id, ["TENANT_ADMIN"])
    user
  end

  # An OIDC user holding TASK_WORKER ONLY through a group whose single row is scoped.
  defp scoped_worker!(fx, sub) do
    user = user_of!(fx, sub)
    node = RSG.node!(fx.schema_name)
    group = SyncScopeFixture.platform_group!(fx.schema_name, @worker, [{:node, node}])
    _ = RSG.member!(fx.schema_name, group.id, user)
    %{user: user, group: group, node: node}
  end

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  defp forbidden?(conn),
    do: conn.status == 403 and json(conn)["detail"] == "insufficient permissions"

  # --- T-Z0 ---------------------------------------------------------------------------------------

  describe "T-Z0 the route walk is green first (AC 22)" do
    test "audit_routes/3 is [] and no /me or /help route is default-sourced or pending" do
      routes = RouteInventory.routes()

      assert RouteScope.audit_routes(routes, RouteInventory.read_snapshot()) == []

      self_service =
        Enum.filter(
          routes,
          &(String.starts_with?(&1.path, "/me") or String.starts_with?(&1.path, "/help"))
        )

      assert length(self_service) == 4
      assert Enum.all?(self_service, &(&1.class == :self_service and &1.source == :declared))
      assert Enum.all?(RouteScope.self_service_routes(), &is_binary(&1.ruling))
    end
  end

  # --- T-Z1 ---------------------------------------------------------------------------------------

  describe "T-Z1 a tenant reaches on through the real flip and back" do
    test "scoped users are denied tenant-wide routes under on, nothing else changes, and on -> shadow restores byte for byte" do
      fx = oidc_tenant!("req519-z1")
      s = fx.schema_name

      _admin = admin!(fx, "z1-admin")
      _worker = scoped_worker!(fx, "z1-worker")
      _ = F.backdate_shadow!(fx)

      # an API token owned by the tenant-wide admin (unaffected by on)
      admin_user = user_of!(fx, "z1-admin")

      {:ok, %{plaintext: token}} =
        Identity.create_token(admin_user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: s
        )

      token_get = fn path ->
        conn(:get, path)
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("x-tenant-slug", fx.tenant.slug)
        |> Letflow.Router.call(Letflow.Router.init([]))
      end

      # --- under shadow: nothing is denied, the denial is only counted
      shadow_scoped = get(fx, "z1-worker", @tenant_wide_route)
      assert shadow_scoped.status == 200, shadow_scoped.resp_body
      assert get(fx, "z1-admin", @tenant_wide_route).status == 200
      assert mode!(fx) == :shadow

      # --- the REAL flip, by the interactive tenant-wide admin
      flip =
        request(fx, "z1-admin", :put, @flag_path, %{"mode" => "on", "reason" => "req519 e2e"})

      assert flip.status == 200, flip.resp_body
      assert json(flip) == %{"mode" => "on", "previous" => "shadow", "changed" => true}
      assert mode!(fx) == :on

      # --- under on: the scoped worker is refused with the uniform 403 on a tenant-wide route
      denied = get(fx, "z1-worker", @tenant_wide_route)
      assert forbidden?(denied), denied.resp_body

      # the self-service read still works for a scoped user, and so do the tenant-wide user and the token
      assert get(fx, "z1-worker", @self_service_route).status == 200
      assert get(fx, "z1-admin", @tenant_wide_route).status == 200
      assert token_get.(@tenant_wide_route).status == 200
      assert get(fx, "z1-admin", @admin_plane_route).status == 200

      # --- the scoped worker cannot flip anything, and the flag does not move
      refused = request(fx, "z1-worker", :put, @flag_path, %{"mode" => "off", "reason" => "x"})
      assert forbidden?(refused)
      assert mode!(fx) == :on

      # --- writers refuse to widen (AC 1 in the enforced tenant, reached through the real flip)
      group = RSG.fresh_group!(s)

      assert RoleRegistry.upsert_role_report("PROCESS_DESIGNER", :platform_role, group.id,
               prefix: s
             ) ==
               {:error, :scope_required}

      assert RSG.binding(s, "PROCESS_DESIGNER") == nil

      # --- the IdP sync suppresses a tenant-wide group for a user who holds scoped rows
      sync_group = SyncScopeFixture.platform_group!(s, "SYNC_ROLE_E2E", [:tenant_wide])
      holder = RSG.user!(s)
      :ok = RSG.raw_user_row!(s, holder.id, "SYNC_ROLE_E2E", RSG.node!(s))

      assert {:suppressed, _user, %{suppressed: [%{group_id: group_id, role: "SYNC_ROLE_E2E"}]}} =
               SyncScopeFixture.sync(s, holder, ["SYNC_ROLE_E2E"])

      assert group_id == sync_group.id
      assert SyncScopeFixture.memberships(s, holder.id) == []

      # --- on -> shadow needs a reason, and restores today's behaviour
      no_reason = request(fx, "z1-admin", :put, @flag_path, %{"mode" => "shadow"})
      assert no_reason.status == 422
      assert json(no_reason)["detail"] == "reason_required"
      assert mode!(fx) == :on

      down =
        request(fx, "z1-admin", :put, @flag_path, %{
          "mode" => "shadow",
          "reason" => "req519 e2e down"
        })

      assert down.status == 200, down.resp_body
      assert json(down) == %{"mode" => "shadow", "previous" => "on", "changed" => true}

      restored = get(fx, "z1-worker", @tenant_wide_route)
      assert restored.status == 200
      # byte-identical to the answer the same request got before the flip
      assert restored.resp_body == shadow_scoped.resp_body

      off =
        request(fx, "z1-admin", :put, @flag_path, %{"mode" => "off", "reason" => "req519 e2e off"})

      assert off.status == 200
      assert get(fx, "z1-worker", @tenant_wide_route).resp_body == shadow_scoped.resp_body
    end
  end

  # --- T-Z2 ---------------------------------------------------------------------------------------

  describe "T-Z2 the admin plane under on" do
    test "a scoped-only TENANT_ADMIN is refused the admin plane and the flag route; the interactive tenant-wide admin reaches both" do
      fx = oidc_tenant!("req519-z2")
      s = fx.schema_name

      admin = admin!(fx, "z2-admin")
      # a second OIDC user in the same TENANT_ADMIN group; the group is then made scoped-only, and
      # the admin keeps a tenant-wide USER row, so only the admin is tenant-wide
      scoped = user_of!(fx, "z2-scoped")
      group_id = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.member!(s, group_id, scoped)
      :ok = RSG.raw_user_row!(s, admin.id, "TENANT_ADMIN", nil)
      node = RSG.make_group_scoped_only!(s, group_id, "TENANT_ADMIN")
      assert is_binary(node)

      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      # the scoped member: admin plane and flag route are refused
      assert forbidden?(get(fx, "z2-scoped", @admin_plane_route))

      assert forbidden?(
               request(fx, "z2-scoped", :put, @flag_path, %{"mode" => "off", "reason" => "x"})
             )

      assert mode!(fx) == :on

      # the admin holds a tenant-wide USER row: the admin plane and the turn-off path are open
      assert get(fx, "z2-admin", @admin_plane_route).status == 200

      off =
        request(fx, "z2-admin", :put, @flag_path, %{
          "mode" => "off",
          "reason" => "req519 turn off"
        })

      assert off.status == 200, off.resp_body
      assert mode!(fx) == :off
    end
  end

  # --- T-O7 / T-O8 --------------------------------------------------------------------------------

  describe "T-O7 / T-O8 platform authority never reads grants" do
    test "T-O7 the platform tenant stored on does not lock out its PLATFORM_ADMIN, even through a group with zero rows" do
      p = oidc_tenant!("req519-o7")
      :ok = Fixture.pin!(p.tenant_id)
      s = p.schema_name

      operator = user_of!(p, "o7-operator")
      _ = TokenMintFixture.grant_roles!(s, operator.id, ["PLATFORM_ADMIN"])
      # fail closed for grants: the PLATFORM_ADMIN binding has NO rows at all
      gid = RSG.group_of!(s, "PLATFORM_ADMIN")
      _ = RSG.raw_delete_rows!(s, gid, "PLATFORM_ADMIN")
      assert RSG.rows(s) |> Enum.filter(&match?({:group, ^gid, "PLATFORM_ADMIN", _, _}, &1)) == []

      for mode <- [:off, :shadow, :on] do
        :ok = ScopeEnforcementFixture.set_stored_mode!(p.tenant_id, mode)

        conn = get(p, "o7-operator", @platform_route)

        assert conn.status == 200,
               "platform route under #{mode}: #{conn.status} #{conn.resp_body}"
      end

      # the flag route stays TENANT_ADMIN-only: a PLATFORM_ADMIN without TENANT_ADMIN is refused
      flag = request(p, "o7-operator", :put, @flag_path, %{"mode" => "off", "reason" => "x"})
      assert forbidden?(flag)
      assert mode!(p) == :on
    end

    test "T-O8 in an ordinary tenant stored on, a PLATFORM_ADMIN role is inert" do
      fx = oidc_tenant!("req519-o8")
      user = user_of!(fx, "o8-user")
      _ = TokenMintFixture.grant_roles!(fx.schema_name, user.id, ["PLATFORM_ADMIN"])

      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      assert forbidden?(get(fx, "o8-user", @platform_route))

      assert forbidden?(
               request(fx, "o8-user", :put, @flag_path, %{"mode" => "off", "reason" => "x"})
             )

      assert mode!(fx) == :on
    end
  end

  # --- AC 17: fail closed ------------------------------------------------------------------------------

  describe "T-Z15 / T-Z16 / T-Z17 fail closed in on" do
    test "a principal with a binding but ZERO rows is denied :no_grant_rows and gets the uniform 403 on a tenant-wide route" do
      fx = oidc_tenant!("req519-z15")
      s = fx.schema_name
      _admin = admin!(fx, "z15-admin")
      holder = user_of!(fx, "z15-holder")

      group = SyncScopeFixture.platform_group!(s, @worker, [])
      _ = RSG.member!(s, group.id, holder)
      assert RSG.rows(s) |> Enum.filter(&match?({:group, _, @worker, _, _}, &1)) == []

      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      principal = S.principal(fx, holder.id)
      assert Scope.allowed?(principal, :DefinitionsRead, :tenant_wide) == {:deny, :no_grant_rows}

      assert forbidden?(get(fx, "z15-holder", @tenant_wide_route))
      # the tenant-wide administrator is served by the same route
      assert get(fx, "z15-admin", @tenant_wide_route).status == 200
    end

    test "T-Z16 deleting a user's LAST scoped row is refused (409 last_scoped_row) and the scope is unchanged, in on" do
      fx = on_tenant_via_flip!("req519-z16")
      s = fx.schema_name

      member = TokenMintFixture.role_holder!(s, [@worker])
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)

      created =
        S.as_admin(
          Letflow.Routers.TenantRoleScopeGrants,
          :post,
          "/",
          fx,
          S.create_body(:group, gid, @worker, node)
        )

      assert created.status in [200, 201], created.resp_body
      row_id = S.body(created)["id"]

      conn = S.as_admin(Letflow.Routers.TenantRoleScopeGrants, :delete, "/#{row_id}", fx, nil)
      assert conn.status == 409
      assert S.body(conn)["detail"] == "last_scoped_row"

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, {:node, node}) ==
               {:allow, :subtree}

      assert mode!(fx) == :on
    end

    test "T-Z17 a node that a grant references cannot be retired; nobody becomes tenant-wide by it, in on" do
      fx = on_tenant_via_flip!("req519-z17")
      s = fx.schema_name

      member = TokenMintFixture.role_holder!(s, [@worker])
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)

      created =
        S.as_admin(
          Letflow.Routers.TenantRoleScopeGrants,
          :post,
          "/",
          fx,
          S.create_body(:group, gid, @worker, node)
        )

      assert created.status in [200, 201], created.resp_body

      assert ScopeNodePaths.write({:retire, node}, s) == {:error, :node_has_grants}

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, {:node, node}) ==
               {:allow, :subtree}

      assert Scope.allowed?(S.principal(fx, member.id), :TasksRead, :tenant_wide) |> elem(0) ==
               :deny
    end
  end

  # A tenant (default role groups seeded, admin under :admin) that is on through the REAL flip at
  # the real clock (backdated evidence).
  defp on_tenant_via_flip!(slug_prefix) do
    fx = S.tenant!(slug_prefix)
    _ = F.backdate_shadow!(fx)

    attrs = %{actor_id: fx.admin.id, reason: "req519 e2e", trace_id: "req519-2fb-e2e-trace-0001"}

    assert {:ok, %{mode: :on, previous: :shadow, changed: true}} =
             ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :on, attrs)

    fx
  end
end
