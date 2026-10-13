defmodule Letflow.Api.PlatformScopeNotConferredTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 10 and section 12 items 10(b), 10(d), 10(f) (spec
  `test/specs/ISS-0993-A2.md`): the three facts platform scope depends on (the database-resolved
  tenant, the configured platform tenant id, `PLATFORM_ADMIN` in that tenant's own schema) cannot
  be produced from inside an ordinary tenant.

    * 10(b) `Identity.sync_role_claims_from_token/3` with a claimed `PLATFORM_ADMIN` in an
      ordinary tenant A: REQ-447 PR 2 changed this from "writes the membership, yet every platform
      route is 403" to "the claim is ignored outright" (no membership, marker left nil), even
      with a legacy binding present; a legacy STORED membership (a raw row) is still 403 on all
      21 platform routes; the same role list held in the platform tenant is let through (control);
    * 10(d) a group named `PLATFORM_ADMIN` in A (with the user as a member), and edits to A's
      display name and settings, confer no platform scope: the 21 routes stay 403 for A's caller,
      and `PlatformTenant` still reports A as a non-platform tenant;
    * 10(f) a token verified for realm X resolves ONLY to X's tenant. Three tenants are bound
      to three realms of a local mock OIDC provider (platform P, A, B); each realm's token, which
      claims `PLATFORM_ADMIN`, goes through the real `AuthPipeline` and the full `Letflow.Router`:
      it resolves to its own tenant, A's and B's tokens are never the platform tenant (403 on
      `GET /tenants`, whatever slug header they carry), only P's is (200), and a token whose `iss`
      names one realm but is signed with another realm's key is a 401. (The realm-routing
      isolation of the verifier itself is in `test/letflow/oidc/provider_registry_multi_realm_test.exs`
      AC2/AC3; this file adds the tenant resolution and platform-fact assertions on top.)

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin and OIDC config).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.TokenVerifier.Oidcc
  alias Letflow.PlatformTenant
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.Support.MockOidcProvider
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture

  @unused_uuid "00000000-0000-4000-8000-000000000004"

  # The 24 platform routes (design 7.1 plus ISS-1030's bind-realm and, in PR 2, the pending-admins list and revoke): {router, method, concrete local path, body}.
  @routes [
    {Letflow.Routers.Tenants, :post, "/", %{}},
    {Letflow.Routers.Tenants, :get, "/", nil},
    {Letflow.Routers.Tenants, :get, "/no-such-slug", nil},
    {Letflow.Routers.Tenants, :patch, "/no-such-slug", %{}},
    {Letflow.Routers.Tenants, :post, "/no-such-slug/deactivate", nil},
    {Letflow.Routers.Tenants, :post, "/no-such-slug/reactivate", nil},
    {Letflow.Routers.Onboarding, :post, "/", %{}},
    {Letflow.Routers.Onboarding, :get, "/" <> @unused_uuid, nil},
    {Letflow.Routers.Onboarding, :post, "/" <> @unused_uuid <> "/bind-realm",
     %{"idp_realm_id" => "iss1030-not-conferred"}},
    {Letflow.Routers.Onboarding, :get, "/", nil},
    {Letflow.Routers.Onboarding, :get, "/" <> @unused_uuid <> "/pending-admins", nil},
    {Letflow.Routers.Onboarding, :delete,
     "/" <> @unused_uuid <> "/pending-admins/" <> @unused_uuid, nil},
    {Letflow.Routers.PlatformMigrations, :post, "/rollouts", %{}},
    {Letflow.Routers.PlatformMigrations, :get, "/rollouts/" <> @unused_uuid, nil},
    {Letflow.Routers.PlatformMigrations, :post, "/rollouts/" <> @unused_uuid <> "/resume", nil},
    {Letflow.Routers.EventRetention, :get, "/summary", nil},
    {Letflow.Routers.EventRetention, :post, "/retirements", %{}},
    {Letflow.Routers.EventRetention, :get, "/retirements/" <> @unused_uuid, nil},
    {Letflow.Routers.AdminServices, :get, "/", nil},
    {Letflow.Routers.AdminServices, :post, "/", %{}},
    {Letflow.Routers.AdminServices, :patch, "/no-such-service", %{}},
    {Letflow.Routers.AdminServices, :delete, "/no-such-service", nil},
    {Letflow.Routers.AdminServices, :post, "/no-such-service/versions", %{}},
    {Letflow.Routers.AdminServices, :post, "/no-such-service/retire", nil}
  ]

  defp dispatch(router, conn), do: router.call(conn, router.init([]))

  # Every platform route as `fixture`'s caller holding `roles`; returns [{label, status}].
  defp platform_route_statuses(fixture, roles) do
    for {router, method, path, body} <- @routes do
      conn =
        Fixture.router_conn(method, path, fixture, roles, body)

      {"#{method} #{inspect(router)} #{path}", dispatch(router, conn).status}
    end
  end

  defp assert_all_forbidden(fixture, roles) do
    assert length(@routes) == 24

    for {label, status} <- platform_route_statuses(fixture, roles) do
      assert status == 403, "#{label}: expected 403, got #{status}"
    end
  end

  defp tenant_row_state(fixture) do
    t = Repo.get!(Letflow.Identity.Tenant, fixture.tenant_id)
    {t.slug, t.status, t.idp_realm_id}
  end

  defp insert_user!(fixture) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "not-conferred-#{Ecto.UUID.generate()}",
      display_name: "Not Conferred",
      email: "not-conferred-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  describe "10(b): a claimed PLATFORM_ADMIN synced into an ordinary tenant" do
    setup do
      tenants = Fixture.three_tenants!()
      Fixture.pin!(tenants.p.tenant_id)
      {:ok, tenants}
    end

    defp claim(user, roles) do
      %IdentityContext{
        external_user_id: Ecto.UUID.generate(),
        tenant_id: nil,
        realm: "claims-realm-#{Ecto.UUID.generate()}",
        roles: roles,
        email: user.email,
        preferred_username: user.username,
        display_name: user.display_name
      }
    end

    # A LEGACY `PLATFORM_ADMIN` binding (a tenant onboarded before REQ-447, not yet migrated). A raw
    # insert: REQ-447 PR 2's `upsert_role/4` refuses to create one outside the platform tenant.
    defp legacy_binding!(fixture) do
      {:ok, %Group{id: group_id} = group} =
        RoleRegistry.get_or_create_group_by_name("PLATFORM_ADMIN", prefix: fixture.schema_name)

      %Letflow.Identity.TenantRole{}
      |> Letflow.Identity.TenantRole.changeset(%{
        name: "PLATFORM_ADMIN",
        kind: :platform_role,
        group_id: group_id
      })
      |> Repo.insert!(prefix: fixture.schema_name)

      group
    end

    test "REQ-447 PR 2 (changed): the claim is IGNORED in A (no membership written, marker left nil); the platform tenant honours it",
         ctx do
      user = insert_user!(ctx.a)

      # the onboarding step that binds each role literal to a group of the same name
      assert {:ok, _roles} =
               RoleRegistry.seed_default_platform_role_groups(prefix: ctx.a.schema_name)

      legacy_binding!(ctx.a)

      synced =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:synced,
             Identity.sync_role_claims_from_token(user, claim(user, ["PLATFORM_ADMIN"]),
               prefix: ctx.a.schema_name
             )}
          )
        end)

      assert is_binary(synced)
      assert_received {:synced, %User{role_claims_synced_at: nil}}

      # old assertion ("PLATFORM_ADMIN" in roles after the sync) is now its opposite
      roles = Identity.list_effective_role_names(user.id, prefix: ctx.a.schema_name)
      refute "PLATFORM_ADMIN" in roles
      assert_all_forbidden(ctx.a, roles)

      # the same claim in the platform tenant's schema is honoured (control: the role is real)
      assert {:ok, _roles} =
               RoleRegistry.seed_default_platform_role_groups(prefix: ctx.p.schema_name)

      user_p = insert_user!(ctx.p)

      Identity.sync_role_claims_from_token(user_p, claim(user_p, ["PLATFORM_ADMIN"]),
        prefix: ctx.p.schema_name
      )

      roles_p = Identity.list_effective_role_names(user_p.id, prefix: ctx.p.schema_name)
      assert "PLATFORM_ADMIN" in roles_p

      listing =
        dispatch(
          Letflow.Routers.Tenants,
          Fixture.router_conn(:get, "/", ctx.p, roles_p, nil)
        )

      assert listing.status == 200

      # and the tenant itself is not the platform tenant
      refute PlatformTenant.platform_tenant?(ctx.a.tenant_id)
      refute PlatformTenant.scope_facts(ctx.a.tenant_id, roles).platform_scope?
    end

    test "a LEGACY stored membership of PLATFORM_ADMIN in A (written before PR 2) opens no platform route",
         ctx do
      user = insert_user!(ctx.a)
      group = legacy_binding!(ctx.a)

      assert {:ok, _member} =
               Identity.add_group_member(group.id, user.id, prefix: ctx.a.schema_name)

      roles = Identity.list_effective_role_names(user.id, prefix: ctx.a.schema_name)
      assert "PLATFORM_ADMIN" in roles

      assert_all_forbidden(ctx.a, roles)
      refute PlatformTenant.scope_facts(ctx.a.tenant_id, roles).platform_scope?
    end
  end

  describe "10(d): a PLATFORM_ADMIN group, display-name and settings edits in an ordinary tenant" do
    setup do
      tenants = Fixture.three_tenants!()
      Fixture.pin!(tenants.p.tenant_id)
      {:ok, tenants}
    end

    test "confer no platform scope", ctx do
      user = insert_user!(ctx.a)

      # (1) a group named PLATFORM_ADMIN in A, bound to the role and holding the user
      {:ok, %Group{} = group} =
        RoleRegistry.get_or_create_group_by_name("PLATFORM_ADMIN", prefix: ctx.a.schema_name)

      assert {:ok, _member} =
               Identity.add_group_member(group.id, user.id, prefix: ctx.a.schema_name)

      # REQ-447 PR 2: the write path refuses the binding in an ordinary tenant ...
      assert {:error, :platform_admin_outside_platform_tenant} =
               RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group.id,
                 prefix: ctx.a.schema_name
               )

      # ... so a binding can only be a pre-existing legacy row: insert one directly.
      %Letflow.Identity.TenantRole{}
      |> Letflow.Identity.TenantRole.changeset(%{
        name: "PLATFORM_ADMIN",
        kind: :platform_role,
        group_id: group.id
      })
      |> Repo.insert!(prefix: ctx.a.schema_name)

      roles = Identity.list_effective_role_names(user.id, prefix: ctx.a.schema_name)
      assert "PLATFORM_ADMIN" in roles
      assert_all_forbidden(ctx.a, roles)

      # (2) A edits its own settings (an ordinary tenant admin, TENANT_ADMIN, may) ...
      settings =
        Letflow.Routers.TenantSettings.call(
          Fixture.router_conn(:patch, "/", ctx.a, ["TENANT_ADMIN"], %{"app_name" => "Renamed A"}),
          Letflow.Routers.TenantSettings.init([])
        )

      assert settings.status == 200

      # ... and the operator renames A's display name
      renamed =
        Letflow.Routers.Tenants.call(
          Fixture.router_conn(:patch, "/#{ctx.a.tenant.slug}", ctx.p, ["PLATFORM_ADMIN"], %{
            "display_name" => "Platform Looking Name"
          }),
          Letflow.Routers.Tenants.init([])
        )

      assert renamed.status == 200

      # nothing changed about A's platform standing
      assert_all_forbidden(ctx.a, roles)
      refute PlatformTenant.platform_tenant?(ctx.a.tenant_id)
      refute PlatformTenant.scope_facts(ctx.a.tenant_id, roles).platform_scope?
      assert PlatformTenant.configured_id() == String.downcase(ctx.p.tenant_id)
    end
  end

  describe "10(f): a token verified for realm X resolves only to X's tenant" do
    setup do
      original = Application.fetch_env!(:letflow, :oidc)
      on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)

      realm_p = Letflow.TenantSlugFixture.unique_realm("nc-platform")
      realm_a = Letflow.TenantSlugFixture.unique_realm("nc-a")
      realm_b = Letflow.TenantSlugFixture.unique_realm("nc-b")

      %{base_url: base_url, realms: realms} = MockOidcProvider.start([realm_p, realm_a, realm_b])

      Application.put_env(
        :letflow,
        :oidc,
        Keyword.merge(original, keycloak_base_url: base_url, token_verifier: Oidcc)
      )

      tenant = fn prefix, realm ->
        TenantFixture.provisioned_tenant!(
          slug_prefix: prefix,
          idp_realm_id: realm,
          oidc_mode: :enabled
        )
      end

      p = tenant.("nc-p", realm_p)
      a = tenant.("nc-a", realm_a)
      b = tenant.("nc-b", realm_b)
      Fixture.pin!(p.tenant_id)

      # the role literals are bound to groups in every tenant (onboarding does this; REQ-447 binds
      # PLATFORM_ADMIN only in P), and the claimed PLATFORM_ADMIN of A's and B's tokens is dropped
      for fixture <- [p, a, b] do
        assert {:ok, _roles} =
                 RoleRegistry.seed_default_platform_role_groups(prefix: fixture.schema_name)
      end

      {:ok,
       p: p, a: a, b: b, realm_p: realm_p, realm_a: realm_a, realm_b: realm_b, realms: realms}
    end

    defp bearer(realms, realm, opts \\ []) do
      MockOidcProvider.sign_token(
        realms,
        realm,
        Keyword.put_new(opts, :roles, ["PLATFORM_ADMIN"])
      )
    end

    defp pipeline(token, extra_headers) do
      conn =
        Enum.reduce(
          [{"authorization", "Bearer " <> token} | extra_headers],
          Plug.Test.conn(:get, "/api/v1/tenants"),
          fn {k, v}, acc -> put_req_header(acc, k, v) end
        )

      AuthPipeline.call(conn, AuthPipeline.init([]))
    end

    defp full_router(token, extra_headers) do
      conn =
        Enum.reduce(
          [{"authorization", "Bearer " <> token} | extra_headers],
          Plug.Test.conn(:get, "/api/v1/tenants"),
          fn {k, v}, acc -> put_req_header(acc, k, v) end
        )

      Letflow.Router.call(conn, Letflow.Router.init([]))
    end

    test "each realm's token resolves to its own tenant; only the platform realm's is the platform tenant",
         ctx do
      for {fixture, realm, platform?} <- [
            {ctx.p, ctx.realm_p, true},
            {ctx.a, ctx.realm_a, false},
            {ctx.b, ctx.realm_b, false}
          ] do
        conn = pipeline(bearer(ctx.realms, realm), [])

        refute conn.halted, "#{realm}: #{conn.status} #{conn.resp_body}"
        assert conn.assigns.auth_context.tenant_id == fixture.tenant_id
        assert conn.assigns.auth_context.platform_tenant? == platform?
      end
    end

    test "a slug header naming another tenant (the platform tenant included) does not redirect the token",
         ctx do
      for {fixture, realm} <- [{ctx.a, ctx.realm_a}, {ctx.b, ctx.realm_b}],
          slug <- [ctx.p.tenant.slug, ctx.b.tenant.slug, ctx.a.tenant.slug] do
        conn = pipeline(bearer(ctx.realms, realm), [{"x-tenant-slug", slug}])

        if conn.halted do
          assert conn.status in [400, 401, 403]
        else
          assert conn.assigns.auth_context.tenant_id == fixture.tenant_id
          refute conn.assigns.auth_context.platform_tenant?
        end
      end
    end

    test "through the full router: A's and B's PLATFORM_ADMIN tokens are 403 on a platform route, P's is 200",
         ctx do
      for {realm, expected} <- [{ctx.realm_a, 403}, {ctx.realm_b, 403}, {ctx.realm_p, 200}] do
        resp = full_router(bearer(ctx.realms, realm), [])
        assert resp.status == expected, "#{realm}: #{resp.status} #{resp.resp_body}"
      end

      # a slug header naming the platform tenant does not lift A's token into it
      resp =
        full_router(bearer(ctx.realms, ctx.realm_a), [{"x-tenant-slug", ctx.p.tenant.slug}])

      refute resp.status == 200
    end

    test "a token claiming realm A's issuer but signed with another realm's key is rejected 401",
         ctx do
      for signer <- [ctx.realm_b, ctx.realm_p] do
        forged = bearer(ctx.realms, ctx.realm_a, signing_realm: signer)
        conn = pipeline(forged, [])

        assert conn.halted
        assert conn.status == 401
      end
    end

    test "tenant rows are untouched by the logins", ctx do
      before = {tenant_row_state(ctx.p), tenant_row_state(ctx.a), tenant_row_state(ctx.b)}

      for realm <- [ctx.realm_p, ctx.realm_a, ctx.realm_b],
          do: pipeline(bearer(ctx.realms, realm), [])

      assert {tenant_row_state(ctx.p), tenant_row_state(ctx.a), tenant_row_state(ctx.b)} == before
    end
  end
end
