defmodule Letflow.ApiTokenAuthPipelineTest do
  @moduledoc """
  End-to-end HTTP-level tests for REQ-076's API-token branch of
  `Letflow.Plugs.AuthPipeline` (design §3.5) — the real request path AC4 and AC5
  actually depend on, not just the underlying `Letflow.Identity.verify_api_token/2`
  primitive (that primitive-level coverage lives in `test/letflow/identity_test.exs`).
  See `test/specs/REQ-076.md` for the full AC-to-test mapping.

  Dispatches through the **real** `Letflow.Router.call/2` (the full
  `AuthPipeline` -> `TenantStatus` -> `Letflow.Routers.Identity` chain), mirroring
  `test/letflow/plugs/api_pipeline_integration_test.exs`'s own established
  full-pipeline dispatch convention, with `Authorization: Bearer <plaintext>` +
  `X-Tenant-Slug: <slug>` headers (the API-token branch's own tenant-identification
  mechanism, design §3.5 step 1) rather than an OIDC bearer token.

  Uses `Letflow.TenantFixture.provisioned_tenant!/1` for a real, provisioned tenant
  schema — `Letflow.Identity.create_token/3` requires an existing `user_id` in that
  schema, and `Letflow.Plugs.AuthPipeline`'s API-token branch itself does a real
  `Repo` round trip against it. `async: false` for the whole module (ExUnit's
  `async` setting is module-wide) — `TenantFixture.provisioned_tenant!/1` switches
  `Ecto.Adapters.SQL.Sandbox` to global `:auto` mode, same reasoning as every other
  `async: false` module in this suite that provisions a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp insert_user!(tenant, attrs \\ []) do
    default = %{
      username: "api-token-user-#{Ecto.UUID.generate()}",
      display_name: "API Token Test User",
      email: "api-token-user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp api_token_request(method, path, plaintext, tenant_slug) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant_slug)
  end

  describe "REQ-076 AC4: revoked token rejected with 401 on the very next HTTP request, no sleep or cache flush" do
    test "a valid API token authenticates GET /api/v1/identity/tokens; the identical token is rejected 401 immediately after revocation" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-ac4-http")
      user = insert_user!(tenant)

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: tenant.schema_name
        )

      first_conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, tenant.tenant.slug)
        |> dispatch()

      assert first_conn.status == 200
      assert first_conn.assigns.auth_context.user_id == user.id
      # REQ-447 PR 2: the ordinary tenant's admin identity is TENANT_ADMIN (a
      # PLATFORM_ADMIN token cannot be minted for a non-platform schema any more).
      assert first_conn.assigns.auth_context.roles == ["TENANT_ADMIN"]

      # REQ-497 PR 1b N1: another counted admin, so revoking this (counted) TA token is not
      # refused as the removal of the last tenant-wide admin.
      _remaining_admin = gh2557_admin_token!(tenant, insert_user!(tenant))

      {:ok, _revoked} = Identity.revoke_token(token.id, prefix: tenant.schema_name)

      # No Process.sleep/1, no cache-clear call, no process restart between the
      # two requests -- this is a plain second request with the identical
      # plaintext, immediately after revoke_token/2 returns.
      second_conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, tenant.tenant.slug)
        |> dispatch()

      assert second_conn.status == 401
    end
  end

  describe "REQ-076 AC5/INV-1: a tenant-A-minted token cannot authenticate a tenant-B request (HTTP level)" do
    test "the identical plaintext, sent with tenant B's own X-Tenant-Slug header, is rejected 401" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req076-ac5-http-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req076-ac5-http-b")
      user_a = insert_user!(tenant_a)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user_a.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: tenant_a.schema_name
        )

      own_tenant_conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, tenant_a.tenant.slug)
        |> dispatch()

      assert own_tenant_conn.status == 200

      cross_tenant_conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, tenant_b.tenant.slug)
        |> dispatch()

      assert cross_tenant_conn.status == 401
    end
  end

  describe "REQ-076 §3.5: the API-token branch's own failure modes are byte-identical 401s" do
    test "a missing X-Tenant-Slug header is rejected 401, distinct message text not leaked" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-header-missing")
      user = insert_user!(tenant)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: tenant.schema_name
        )

      conn =
        conn(:get, "/api/v1/identity/tokens")
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> dispatch()

      assert conn.status == 401
    end

    test "an unresolvable X-Tenant-Slug value is rejected 401" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-header-unresolvable")
      user = insert_user!(tenant)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: tenant.schema_name
        )

      conn =
        api_token_request(:get, "/api/v1/identity/tokens", plaintext, "no-such-tenant-slug")
        |> dispatch()

      assert conn.status == 401
    end

    test "a syntactically-lf_tok_-shaped but never-issued plaintext is rejected 401" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-header-garbage")

      conn =
        api_token_request(
          :get,
          "/api/v1/identity/tokens",
          "lf_tok_" <> String.duplicate("0", 64),
          tenant.tenant.slug
        )
        |> dispatch()

      assert conn.status == 401
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # GH-2557 — a token whose owning user is inactive is refused exactly like a
  # revoked token. Design: lib/letflow/design/gh2557-inactive-user-api-token.md
  # §3/§4/§6. Spec: test/specs/GH-2557.md.
  # ══════════════════════════════════════════════════════════════════════

  @gh2557_admin_route "/api/v1/identity/tokens"
  @gh2557_plain_route "/api/v1/me/memberships"

  defp gh2557_admin_token!(tenant, user) do
    {:ok, %{token: token, plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    {token, plaintext}
  end

  defp gh2557_set_status!(tenant, user, status) do
    {:ok, updated} =
      Identity.update_user_status(user.id, status,
        prefix: tenant.schema_name,
        login_directory: :skip
      )

    assert updated.status == status
    updated
  end

  defp gh2557_get(path, plaintext, tenant),
    do: api_token_request(:get, path, plaintext, tenant.tenant.slug) |> dispatch()

  defp gh2557_json_request(method, path, plaintext, tenant, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant.tenant.slug)
    |> dispatch()
  end

  defp gh2557_audit_actions(tenant) do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(e in Letflow.Audit.Entry, order_by: [asc: e.inserted_at], select: e.action),
      prefix: tenant.schema_name
    )
  end

  # Status, body and every header are compared for equality. The one exception
  # is the VALUE of `x-trace-id`: it is a fresh UUID minted per request (two
  # revoked-token requests differ in it too), so it carries no token or user
  # state. The header must be present on both, and both values must be UUIDs.
  defp gh2557_assert_same_response!(left, right) do
    assert List.keymember?(left.resp_headers, "x-trace-id", 0)
    assert List.keymember?(right.resp_headers, "x-trace-id", 0)
    assert left.status == right.status
    assert left.resp_body == right.resp_body
    assert gh2557_normalised_headers(left) == gh2557_normalised_headers(right)
  end

  defp gh2557_normalised_headers(conn) do
    conn.resp_headers
    |> Enum.map(fn
      {"x-trace-id", value} ->
        assert {:ok, _} = Ecto.UUID.cast(value)
        {"x-trace-id", :per_request_uuid}

      header ->
        header
    end)
    |> Enum.sort()
  end

  # GH-2564 (ruling: issue #2564 comment 6174049298, option 3; 0051 N1): deactivating
  # the only tenant-wide admin is now refused 409. Tests that deactivate a sole
  # token-held admin first add this second, unrelated tenant-wide admin.
  defp gh2564_second_admin!(tenant) do
    {_token, _plaintext} = gh2557_admin_token!(tenant, insert_user!(tenant))
    :ok
  end

  # A revoked token's response on `path`, used as the byte-identity reference.
  defp gh2557_revoked_reference(tenant, path) do
    referee = insert_user!(tenant)
    {token, plaintext} = gh2557_admin_token!(tenant, referee)
    # REQ-497 PR 1b N1: another counted admin, so this revoke is not the refused last one.
    _remaining_admin = gh2557_admin_token!(tenant, insert_user!(tenant))
    {:ok, _} = Identity.revoke_token(token.id, prefix: tenant.schema_name)
    conn = gh2557_get(path, plaintext, tenant)
    assert conn.status == 401
    conn
  end

  describe "GH-2557 AC1: an inactive owner's token is refused like a revoked one" do
    test "deactivated owner's TENANT_ADMIN token is refused 401 on GET /identity/tokens and GET /me/memberships" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2557-ac1-routes")
      user = insert_user!(tenant)
      {_token, plaintext} = gh2557_admin_token!(tenant, user)
      gh2564_second_admin!(tenant)

      # Positive control: the same token works on both routes while the owner is active.
      assert gh2557_get(@gh2557_admin_route, plaintext, tenant).status == 200
      assert gh2557_get(@gh2557_plain_route, plaintext, tenant).status == 200

      gh2557_set_status!(tenant, user, :inactive)

      assert gh2557_get(@gh2557_admin_route, plaintext, tenant).status == 401
      assert gh2557_get(@gh2557_plain_route, plaintext, tenant).status == 401
    end

    test "inactive-owner rejection is byte-identical to a revoked token" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2557-ac1-bytes")
      user = insert_user!(tenant)
      {_token, plaintext} = gh2557_admin_token!(tenant, user)
      gh2564_second_admin!(tenant)
      gh2557_set_status!(tenant, user, :inactive)

      for path <- [@gh2557_admin_route, @gh2557_plain_route] do
        inactive_conn = gh2557_get(path, plaintext, tenant)
        revoked_conn = gh2557_revoked_reference(tenant, path)

        assert inactive_conn.status == 401
        gh2557_assert_same_response!(inactive_conn, revoked_conn)
      end
    end
  end

  describe "GH-2557 AC3: reactivation, revoked and expired" do
    # GH-2564 supersedes GH-2557's "reactivation restores the token" (ruling: issue
    # #2564 comment 6174049298, option 3): deactivation revokes the token, so it stays
    # 401 after the owner is reactivated.
    test "reactivating the owner does not resurrect the token: still 401, revoked_at set" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2557-ac3-react")
      user = insert_user!(tenant)
      {token, plaintext} = gh2557_admin_token!(tenant, user)
      gh2564_second_admin!(tenant)

      assert gh2557_get(@gh2557_admin_route, plaintext, tenant).status == 200

      gh2557_set_status!(tenant, user, :inactive)
      assert gh2557_get(@gh2557_admin_route, plaintext, tenant).status == 401

      gh2557_set_status!(tenant, user, :active)
      assert gh2557_get(@gh2557_admin_route, plaintext, tenant).status == 401
      assert gh2557_get(@gh2557_plain_route, plaintext, tenant).status == 401

      persisted = Repo.get!(Identity.ApiToken, token.id, prefix: tenant.schema_name)
      assert %DateTime{} = persisted.revoked_at
    end

    # GH-2564: deactivation already revokes the token, so the explicit revoke below lands
    # on an already-revoked row; this no longer isolates "revoked" from "inactive owner".
    test "token revoked by deactivation, explicitly revoked again, owner reactivated: still 401" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2557-ac3-revoked")
      user = insert_user!(tenant)
      {token, plaintext} = gh2557_admin_token!(tenant, user)
      gh2564_second_admin!(tenant)

      gh2557_set_status!(tenant, user, :inactive)

      assert %DateTime{} =
               Repo.get!(Identity.ApiToken, token.id, prefix: tenant.schema_name).revoked_at

      {:ok, _} = Identity.revoke_token(token.id, prefix: tenant.schema_name)
      gh2557_set_status!(tenant, user, :active)

      assert gh2557_get(@gh2557_admin_route, plaintext, tenant).status == 401
      assert gh2557_get(@gh2557_plain_route, plaintext, tenant).status == 401
    end

    # GH-2564: deactivation already revokes the token, so the expiry below is set on an
    # already-revoked row; this no longer isolates "expired" from "inactive owner".
    test "token revoked by deactivation, then expired, owner reactivated: still 401" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2557-ac3-expired")
      user = insert_user!(tenant)
      {token, plaintext} = gh2557_admin_token!(tenant, user)
      gh2564_second_admin!(tenant)

      gh2557_set_status!(tenant, user, :inactive)

      assert %DateTime{} =
               Repo.get!(Identity.ApiToken, token.id, prefix: tenant.schema_name).revoked_at

      past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

      token
      |> Ecto.Changeset.change(%{expires_at: past})
      |> Repo.update!(prefix: tenant.schema_name)

      gh2557_set_status!(tenant, user, :active)

      assert gh2557_get(@gh2557_admin_route, plaintext, tenant).status == 401
      assert gh2557_get(@gh2557_plain_route, plaintext, tenant).status == 401
    end
  end

  # GH-2564 supersedes GH-2557 AC4's "deactivation changes no token row" (ruling: issue
  # #2564 comment 6174049298, option 3): deactivation now revokes the owner's tokens in
  # the same transaction, with one token.revoke each. The target and the actor are both
  # tenant-wide admins (token-held), so the 0051 N1 guard lets the deactivation through.
  describe "GH-2557 AC4 as amended by GH-2564: deactivation revokes the owner's tokens" do
    test "deactivate via POST /users/:id/status: token.revoke + user.update_status audit, revoked_at set, 401 like a revoked token" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2557-ac4-status")
      target = insert_user!(tenant)
      actor = insert_user!(tenant)
      {target_token, target_plaintext} = gh2557_admin_token!(tenant, target)
      {_actor_token, actor_plaintext} = gh2557_admin_token!(tenant, actor)

      assert gh2557_get(@gh2557_admin_route, target_plaintext, tenant).status == 200
      audit_before = gh2557_audit_actions(tenant)

      conn =
        gh2557_json_request(
          :post,
          "/api/v1/identity/users/#{target.id}/status",
          actor_plaintext,
          tenant,
          %{"status" => "inactive"}
        )

      assert conn.status == 200
      assert Repo.get!(User, target.id, prefix: tenant.schema_name).status == :inactive

      audit_after = gh2557_audit_actions(tenant)
      assert Enum.sort(audit_after -- audit_before) == ["token.revoke", "user.update_status"]
      refute "token.revoked" in audit_after

      persisted = Repo.get!(Identity.ApiToken, target_token.id, prefix: tenant.schema_name)
      assert %DateTime{} = persisted.revoked_at

      inactive_conn = gh2557_get(@gh2557_admin_route, target_plaintext, tenant)
      assert inactive_conn.status == 401

      gh2557_assert_same_response!(
        inactive_conn,
        gh2557_revoked_reference(tenant, @gh2557_admin_route)
      )
    end

    test "deactivate via PATCH /users/:id status=inactive: token.revoke + user.update_profile audit, revoked_at set, 401 like a revoked token" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2557-ac4-patch")
      target = insert_user!(tenant)
      actor = insert_user!(tenant)
      {target_token, target_plaintext} = gh2557_admin_token!(tenant, target)
      {_actor_token, actor_plaintext} = gh2557_admin_token!(tenant, actor)

      assert gh2557_get(@gh2557_admin_route, target_plaintext, tenant).status == 200
      audit_before = gh2557_audit_actions(tenant)

      conn =
        gh2557_json_request(
          :patch,
          "/api/v1/identity/users/#{target.id}",
          actor_plaintext,
          tenant,
          %{"status" => "inactive"}
        )

      assert conn.status == 200
      assert Repo.get!(User, target.id, prefix: tenant.schema_name).status == :inactive

      audit_after = gh2557_audit_actions(tenant)
      assert Enum.sort(audit_after -- audit_before) == ["token.revoke", "user.update_profile"]
      refute "token.revoked" in audit_after

      persisted = Repo.get!(Identity.ApiToken, target_token.id, prefix: tenant.schema_name)
      assert %DateTime{} = persisted.revoked_at

      inactive_conn = gh2557_get(@gh2557_admin_route, target_plaintext, tenant)
      assert inactive_conn.status == 401

      gh2557_assert_same_response!(
        inactive_conn,
        gh2557_revoked_reference(tenant, @gh2557_admin_route)
      )
    end
  end
end
