defmodule Letflow.Plugs.Iss0736OidcLiveRevocationTest do
  @moduledoc """
  Regression test for ISS-0736 / REQ-378 AC1 (`lib/letflow/design/req378-oidc-live-revocation-check.md`):
  a `tenant_admin` revoking a signed-in `business_user`'s role/group membership
  takes effect on that user's very next request, with **no** sleep, no token
  refresh, no re-authentication — the identical bearer JWT is reused across the
  before/after requests. See `test/specs/ISS-0736.md` for the full rationale and
  the fail-then-pass proof.

  Follows `test/letflow/api_token_auth_pipeline_test.exs`'s established
  full-pipeline dispatch convention (`Letflow.Router.call/2`, not
  `AuthPipeline.call/2` in isolation) so the request actually exercises the real
  `AuthPipeline -> Authorize -> Letflow.Routers.Identity` chain AC1/AC3 depend
  on, and `test/letflow/plugs/auth_pipeline_test.exs`'s established
  `Letflow.Oidc.TokenVerifierDouble` sentinel-token + real-provisioned-tenant-
  schema fixture pattern (REQ-063's schema-per-tenant shape) for the OIDC half.

  Uses `Letflow.Identity.add_group_member/3` / `Letflow.Identity.remove_group_member/3`
  directly — the exact same `Letflow.Identity` functions the corrected `web/`
  GUI path (design §4.1) now calls — to grant then revoke the role, per the
  handoff's explicit instruction.

  `async: false` for the whole module: `insert_bpm_default_tenant!/0` (ported
  from `auth_pipeline_test.exs`) switches `Ecto.Adapters.SQL.Sandbox` to global
  `:auto` mode and provisions a real tenant schema, same reasoning as every
  other `async: false` module in this suite that does so.

  **REWORK 1 addition (§2.2 one-time sync / one-way gate):** the describe
  block below,
  "REQ-378 §2.2: one-time sync-on-first-login is a one-way gate against
  post-revocation re-sync", closes the coverage gap the rework's handoff
  flagged: every test above pre-seeds `group_members` directly via
  `grant_tenant_admin!/2`, sidestepping
  `Letflow.Identity.sync_role_claims_from_token/3` entirely. The new tests
  exercise that function for real, via
  `Letflow.Oidc.Iss0736RoleClaimTokenVerifierDouble` (`test/support/`) —
  the two existing doubles both hardcode `realm_access.roles: ["VIEWER"]`,
  which is not a role `Letflow.Api.Authorization.role_allows?/2` recognizes
  (design §2.3), so neither can prove a synced role actually unlocks a route.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Oidc.Iss0736RoleClaimTokenVerifierDouble
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  # Provisioned via Letflow.TenantFixture (ISS-0112 / GH#366) — replaces the former
  # hand-rolled `insert_tenant!/1` (Sandbox :auto mode + Tenant.create_changeset/3 +
  # provision_tenant_schema/1 + replay_migrations/1 + on_exit/1 teardown), which
  # TenantFixture.provisioned_tenant!/1 already reproduces statement for statement.
  # `oidc_mode: :enabled` matches this file's original `:enabled` third changeset
  # argument.
  defp insert_bpm_default_tenant! do
    # "bpm-default" is the one realm Letflow.Oidc.TokenVerifierDouble's fixed
    # sentinel token always claims (config/test.exs wires this double in for
    # the whole test env). REQ-370's seed migration permanently binds exactly
    # one tenant to idp_realm_id "bpm-default" -- temporarily displaced here
    # (restored via on_exit/1) so this test can own a fresh, exclusively-owned
    # tenant under that same realm. See Letflow.Support.BpmDefaultRealmDisplacement.
    Letflow.Support.BpmDefaultRealmDisplacement.displace!()

    %{tenant: tenant} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "bpm-default-tenant",
        display_name: "ISS-0736 Live Revocation Test Tenant",
        oidc_mode: :enabled,
        idp_realm_id: "bpm-default"
      )

    tenant
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp oidc_request(method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer valid-test-token")
  end

  defp grant_tenant_admin!(user_id, schema_name) do
    {:ok, group} =
      Identity.create_group(%{"name" => "iss0736-admins-#{Ecto.UUID.generate()}"},
        prefix: schema_name
      )

    {:ok, _role} =
      %TenantRole{}
      |> TenantRole.changeset(%{name: "TENANT_ADMIN", kind: :platform_role, group_id: group.id})
      |> Repo.insert(prefix: schema_name)

    {:ok, %{member: _member, created: true}} =
      Identity.add_group_member(group.id, user_id, prefix: schema_name)

    group
  end

  # REWORK 1 (§2.2 one-time sync coverage): swaps in
  # Iss0736RoleClaimTokenVerifierDouble for the caller's own test, restoring
  # config/test.exs's default Letflow.Oidc.TokenVerifierDouble via on_exit/1
  # -- same scoped Application-config-swap mechanism
  # test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs already
  # uses, safe here because this whole module is already `async: false`.
  defp use_role_claim_token_verifier! do
    original_oidc_config = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original_oidc_config, :token_verifier, Iss0736RoleClaimTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)
  end

  defp role_claim_request(method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer iss0736-role-claim-token")
  end

  # Binds a real, closed-set-recognized role name (Letflow.Api.Authorization's
  # role()) to a fresh group WITHOUT inserting any group_members row --
  # unlike grant_tenant_admin!/2 above, this deliberately leaves membership
  # unseeded so the first OIDC login below must go through
  # Identity.sync_role_claims_from_token/3 to populate it, not a
  # test-fixture shortcut.
  defp bind_role_to_new_group!(role_name, schema_name) do
    {:ok, group} =
      Identity.create_group(%{"name" => "iss0736-sync-#{role_name}-#{Ecto.UUID.generate()}"},
        prefix: schema_name
      )

    {:ok, _role} =
      %TenantRole{}
      |> TenantRole.changeset(%{name: role_name, kind: :platform_role, group_id: group.id})
      |> Repo.insert(prefix: schema_name)

    group
  end

  defp group_member_rows(user_id, schema_name) do
    Repo.all(from(gm in GroupMember, where: gm.user_id == ^user_id), prefix: schema_name)
  end

  describe "REQ-378 AC1: role revocation takes effect on the user's very next request, same JWT, no sleep/refresh" do
    test "an OIDC session with TENANT_ADMIN succeeds on a TENANT_ADMIN-only route; revoking group membership (no re-auth) makes the identical bearer token fail 403 on the very next identical request" do
      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      # First call: no role granted yet, but its only purpose here is to JIT-
      # provision the OIDC user (same external identity every call, fixed by
      # the sentinel token's claims) so its user_id is known before the role
      # is granted. Status/result of this call is not asserted -- it is setup,
      # not part of the AC1 proof.
      setup_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      user_id = setup_conn.assigns.auth_context.user_id
      assert is_binary(user_id)

      group = grant_tenant_admin!(user_id, schema_name)

      # Same bearer token, same route: now succeeds, proving the live role
      # query (not the JWT's own claims) is what authenticate_oidc/2 hands to
      # evaluate_access/2.
      granted_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      assert granted_conn.status == 200
      assert granted_conn.assigns.auth_context.user_id == user_id
      assert "TENANT_ADMIN" in granted_conn.assigns.auth_context.roles

      # The tenant_admin action under test: revoke the membership via the
      # exact same Identity function the corrected web/ GUI path now calls
      # (Identity.remove_group_member/3). No token re-mint, no sleep, no
      # process restart, no cache-clear call between this and the next
      # request below.
      assert :ok = Identity.remove_group_member(group.id, user_id, prefix: schema_name)

      # Immediately retry with the SAME still-valid JWT ("Bearer
      # valid-test-token" -- unchanged, not re-minted). This is the AC1 proof:
      # the very next request after revocation, with no sleep and no token
      # refresh, is denied.
      revoked_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      assert revoked_conn.status == 403
    end

    test "deactivating the account (users.status) also takes effect on the very next request, same JWT" do
      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      setup_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      user_id = setup_conn.assigns.auth_context.user_id

      group = grant_tenant_admin!(user_id, schema_name)

      granted_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      assert granted_conn.status == 200

      # GH-2564 (ruling: issue #2564 comment 6174049298; 0051 N1): deactivating the
      # tenant's only tenant-wide admin is refused 409, so a second member of the same
      # TENANT_ADMIN group keeps the tenant administered.
      second_admin =
        %User{}
        |> Ecto.Changeset.change(%{
          username: "iss0736-second-admin-#{Ecto.UUID.generate()}",
          display_name: "ISS-0736 Second Admin",
          email: "iss0736-second-admin-#{Ecto.UUID.generate()}@example.com",
          password_hash: "__NO_PASSWORD_SET__",
          status: :active,
          auth_source: :internal
        })
        |> Repo.insert!(prefix: schema_name)

      {:ok, %{member: _member, created: true}} =
        Identity.add_group_member(group.id, second_admin.id, prefix: schema_name)

      # tenant_admin deactivates the account -- the same status-update write
      # PATCH /users/:id -> Identity.update_user_profile/3 (design §4's
      # table) performs on the same field; called directly here at the
      # Identity level per the handoff's instruction to reuse "the same
      # Identity functions the GUI fix now calls".
      assert {:ok, _user} =
               Identity.update_user_status(user_id, :inactive,
                 prefix: schema_name,
                 login_directory: :skip
               )

      deactivated_conn = oidc_request(:get, "/api/v1/identity/tokens") |> dispatch()
      assert deactivated_conn.status == 403

      # group membership left untouched -- proves the deactivation short-
      # circuit itself (not merely an empty role list) is what denies here.
      _ = group
    end
  end

  describe "REQ-378 §2.2: one-time sync-on-first-login is a one-way gate against post-revocation re-sync" do
    test "first-ever login seeds group_members from the JWT's claimed role, stamps role_claims_synced_at, succeeds with that role; revocation denies immediately; the same still-claiming JWT does NOT re-sync on a later request" do
      use_role_claim_token_verifier!()

      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      # The role-bearing group/tenant_role exists BEFORE anyone logs in, but
      # no group_members row exists for anyone yet in this freshly
      # provisioned tenant -- the only thing that can populate one is
      # Identity.sync_role_claims_from_token/3, exercised here via the real
      # JIT-provisioning path (Iss0736RoleClaimTokenVerifierDouble claims
      # PROCESS_OPERATOR, a real Letflow.Api.Authorization role, unlike both
      # sibling doubles' inert "VIEWER").
      group = bind_role_to_new_group!("PROCESS_OPERATOR", schema_name)

      # ── (1) first-ever login: sync-on-first-login ──────────────────────
      first_conn = role_claim_request(:get, "/api/v1/audit") |> dispatch()
      user_id = first_conn.assigns.auth_context.user_id
      assert is_binary(user_id)

      # The request succeeds with the synced role -- PROCESS_OPERATOR holds
      # :AuditRead (lib/letflow/api/authorization.ex), so GET /audit 200s
      # only if the live role query actually sees a group_members row that
      # did not exist before this request began.
      assert first_conn.status == 200
      assert "PROCESS_OPERATOR" in first_conn.assigns.auth_context.roles

      # group_members actually got a row (proves the write, not merely that
      # the request happened to pass).
      assert [%GroupMember{user_id: ^user_id}] = group_member_rows(user_id, schema_name)

      # role_claims_synced_at got stamped.
      synced_user = Repo.get!(User, user_id, prefix: schema_name)
      assert %DateTime{} = synced_user.role_claims_synced_at
      first_synced_at = synced_user.role_claims_synced_at

      # ── (2) tenant_admin revokes -- same 403-on-next-request property as
      # the AC1 tests above, now proven via the real sync path instead of a
      # pre-seeded fixture ──────────────────────────────────────────────
      assert :ok = Identity.remove_group_member(group.id, user_id, prefix: schema_name)

      revoked_conn = role_claim_request(:get, "/api/v1/audit") |> dispatch()
      assert revoked_conn.status == 403

      # ── (3) the critical regression-proof: the SAME still-role-claiming
      # JWT hits the pipeline again after revocation -- the one-way gate
      # must NOT re-fire and silently resurrect the revoked access ────────
      regate_conn = role_claim_request(:get, "/api/v1/audit") |> dispatch()
      assert regate_conn.status == 403

      # role_claims_synced_at is unchanged (not re-stamped) -- proves the
      # sync genuinely did not re-run, not merely that its effect was
      # coincidentally invisible.
      still_synced_user = Repo.get!(User, user_id, prefix: schema_name)
      assert still_synced_user.role_claims_synced_at == first_synced_at

      # No new group_members row appeared for this user (still zero -- the
      # revoke above deleted the only one, and the one-way gate must not
      # have written a fresh one).
      assert group_member_rows(user_id, schema_name) == []
    end
  end
end
