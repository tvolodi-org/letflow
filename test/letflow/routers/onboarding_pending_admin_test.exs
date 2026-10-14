defmodule Letflow.Routers.OnboardingPendingAdminTest do
  @moduledoc """
  ISS-1030 PR 2 -- `POST /api/v1/onboarding` storing the named administrator as a pending grant,
  and the operator's list/revoke routes `GET /api/v1/onboarding/:id/pending-admins` and
  `DELETE /api/v1/onboarding/:id/pending-admins/:grant_id`. Design:
  `lib/letflow/design/iss1030-onboarding-administrator.md` sections 5.1, 5.2, 10.2; mapping in
  `test/specs/ISS-1030-PR2.md`.

  Every request goes through the real `Letflow.Router` pipeline with a real API token of a
  PLATFORM_ADMIN of the pinned platform tenant (the harness of
  `onboarding_administrator_fields_test.exs`), against real Postgres and real tenant schemas.
  The realm probe is the deterministic `Letflow.Oidc.RealmProbeDouble` (`config/test.exs`).

  `async: false`: tenant provisioning flips the SQL sandbox to `:auto`, and the platform-tenant
  pin and the realm-probe adapter are VM-global.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.TenantSlugFixture

  @runbook "docs/runbooks/onboarding-new-tenant-realm.md"

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-pa-plat")
    Fixture.pin!(platform.tenant_id)
    token = Fixture.mint_token!(platform, ["PLATFORM_ADMIN"])

    # `mint_token!/2` creates exactly one user in the platform tenant's schema: the operator.
    operator_id =
      Repo.one!(
        from(u in User, where: like(u.username, "scope-caller-%"), select: u.id),
        prefix: platform.schema_name
      )

    %{platform: platform, token: token, operator_id: operator_id}
  end

  # --- helpers ---------------------------------------------------------------

  defp call(ctx, method, path, body) do
    method
    |> Fixture.api_conn(path, ctx.token, ctx.platform.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp stable_body(conn), do: Regex.replace(~r/"trace_id":"[^"]*",?/, conn.resp_body, "")

  defp new_body(extra) do
    Map.merge(
      %{
        "slug" => TenantSlugFixture.unique_slug("iss1030pa"),
        "display_name" => "ISS-1030 PR2 Tenant",
        "hostname" => "iss1030pa-#{Ecto.UUID.generate()}.example.com"
      },
      extra
    )
  end

  defp onboard!(ctx, extra) do
    conn = call(ctx, :post, "/api/v1/onboarding", new_body(extra))
    assert conn.status == 201, conn.resp_body
    resp = json(conn)
    cleanup_onboarded_tenant!(resp["tenant_id"])
    resp
  end

  defp refused!(ctx, extra, status) do
    body = new_body(extra)
    conn = call(ctx, :post, "/api/v1/onboarding", body)

    if tenant = Repo.get_by(Tenant, slug: body["slug"]), do: cleanup_onboarded_tenant!(tenant.id)

    assert conn.status == status, conn.resp_body
    assert Repo.get_by(Tenant, slug: body["slug"]) == nil, "a tenant row was created"
    assert Repo.get_by(OnboardingRecord, hostname: String.trim(body["hostname"])) == nil
    conn
  end

  defp field_error_on?(conn, field) do
    conn |> json() |> Map.get("errors", []) |> Enum.any?(&(&1["field"] == field))
  end

  defp schema_of(tenant_id) do
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    schema_name
  end

  defp entries(schema_name, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema_name)

  defp grants_of(tenant_id),
    do: Repo.all(PendingAdminGrant, prefix: schema_of(tenant_id))

  # The onboarded tenant seen as a `PendingAdminHelper` world (same platform tenant).
  defp world_of(ctx, resp) do
    tenant_id = resp["tenant_id"]

    %{
      platform: ctx.platform,
      tenant: %{
        tenant_id: tenant_id,
        schema_name: schema_of(tenant_id),
        tenant: Repo.get!(Tenant, tenant_id)
      },
      realm: Repo.get!(Tenant, tenant_id).idp_realm_id,
      operator_id: ctx.operator_id
    }
  end

  defp realm, do: TenantSlugFixture.unique_realm("iss1030pa")

  defp cleanup_onboarded_tenant!(tenant_id) do
    on_exit(fn -> drop_tenant_rows!(tenant_id) end)
  end

  defp drop_tenant_rows!(tenant_id) do
    Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
      {:error, :invalid_tenant_id} -> :ok
    end

    Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  defp ascii_address(total) do
    domain_length = total - 64 - 1
    String.duplicate("a", 64) <> "@" <> String.duplicate("d", domain_length - 4) <> ".com"
  end

  # --- creation (design 5.1) -----------------------------------------------------

  test "POST /onboarding without admin_email (absent, null or blank) answers 201 with administrator.state none and the plain no-administrator message",
       ctx do
    variants = [
      %{},
      %{"admin_email" => nil},
      %{"admin_email" => ""},
      %{"admin_email" => "   \t"}
    ]

    for extra <- variants do
      resp = onboard!(ctx, extra)
      administrator = resp["administrator"]

      assert administrator["state"] == "none", inspect(extra)
      refute Map.has_key?(administrator, "grant_id")
      assert administrator["not_provisioned"] == []
      assert administrator["message"] =~ "no administrator"
      assert administrator["message"] =~ @runbook
      refute administrator["message"] =~ "pending"
      assert Enum.any?(administrator["next_steps"], &(&1 =~ "TENANT_ADMIN"))

      # Nothing was stored, in the tenant or in either chain.
      assert grants_of(resp["tenant_id"]) == []
      assert entries(schema_of(resp["tenant_id"]), "tenant.admin_grant.created") == []
    end

    assert entries(ctx.platform.schema_name, "platform.tenant_admin_grant.created") == []
  end

  test "POST /onboarding with admin_email stores a normalised pending grant and answers state pending with next steps",
       ctx do
    sent = "  Ada.Admin+Ops@Example.COM \t"
    resp = onboard!(ctx, %{"admin_email" => sent})

    administrator = resp["administrator"]
    assert administrator["state"] == "pending"
    assert administrator["message"] =~ "pending TENANT_ADMIN"
    assert administrator["message"] =~ "VERIFIED"
    assert is_binary(administrator["grant_id"])
    assert administrator["not_provisioned"] == []

    steps = administrator["next_steps"]
    assert is_list(steps) and length(steps) == 3
    assert Enum.any?(steps, &(&1 =~ "bind-realm"))
    assert Enum.any?(steps, &(&1 =~ "TENANT_ADMIN"))

    # The stored key: trim + lower-case, the +tag preserved. Open, TENANT_ADMIN, onboarding.
    assert [grant] = grants_of(resp["tenant_id"])
    assert grant.id == administrator["grant_id"]
    assert grant.email_key == "ada.admin+ops@example.com"
    assert grant.role_name == "TENANT_ADMIN"
    assert PendingAdminGrant.state(grant) == :open

    # Nothing about the address in the response, in any spelling.
    encoded = resp |> Jason.encode!() |> String.downcase()
    refute encoded =~ "ada.admin"
    refute encoded =~ "example.com\\t"

    # The audit split: operator-free tenant entry, operator-bearing platform entry.
    assert [tenant_entry] = entries(schema_of(resp["tenant_id"]), "tenant.admin_grant.created")
    assert tenant_entry.actor_id == nil
    assert tenant_entry.resource_id == grant.id
    refute inspect(tenant_entry) =~ ctx.operator_id

    assert [platform_entry] =
             ctx.platform.schema_name
             |> entries("platform.tenant_admin_grant.created")
             |> Enum.filter(&(&1.resource_id == grant.id))

    assert platform_entry.actor_id == ctx.operator_id
    assert platform_entry.after_state["tenant_id"] == resp["tenant_id"]
    assert platform_entry.after_state["onboarding_id"] == resp["id"]
    assert platform_entry.after_state["grant_id"] == grant.id
  end

  test "POST /onboarding with an invalid admin_email answers 422 and creates no tenant row",
       ctx do
    for value <- [
          "not-an-email-zzLEAKzz",
          "zzLEAKzz@@example.com",
          "zzLEAKzz@example",
          "zz LEAKzz@example.com",
          "zzLEAKzz@exämple.com",
          "KzzLEAKzz@example.com",
          String.duplicate("a", 65) <> "zzLEAKzz@example.com"
        ] do
      conn = refused!(ctx, %{"admin_email" => value}, 422)

      assert field_error_on?(conn, "admin_email"), "value #{inspect(value)}: #{conn.resp_body}"
      refute conn.resp_body =~ "zzLEAKzz"
    end

    # Nothing reached either chain.
    assert entries(ctx.platform.schema_name, "platform.tenant_admin_grant.created") == []
  end

  test "POST /onboarding with a 254-character admin_email stores the grant and with a 255-character admin_email answers 422 before any tenant row exists",
       ctx do
    at_limit = ascii_address(254)
    over = ascii_address(255)

    resp = onboard!(ctx, %{"admin_email" => at_limit})
    assert resp["administrator"]["state"] == "pending"
    assert [grant] = grants_of(resp["tenant_id"])
    assert grant.email_key == at_limit

    conn = refused!(ctx, %{"admin_email" => over}, 422)
    assert field_error_on?(conn, "admin_email")
  end

  test "POST /onboarding with only admin_username and admin_display_name still answers state none and stores no grant",
       ctx do
    resp = onboard!(ctx, %{"admin_username" => "grace", "admin_display_name" => "Grace Hopper"})

    assert resp["administrator"]["state"] == "none"
    assert grants_of(resp["tenant_id"]) == []

    assert entries(schema_of(resp["tenant_id"]), "tenant.admin_grant.created") == []
    assert entries(ctx.platform.schema_name, "platform.tenant_admin_grant.created") == []
  end

  test "POST /onboarding with admin_email plus admin_username returns state pending and echoes only admin_username as not_provisioned",
       ctx do
    resp = onboard!(ctx, %{"admin_email" => "ada@example.com", "admin_username" => "ada-admin"})

    assert resp["administrator"]["state"] == "pending"

    assert resp["administrator"]["not_provisioned"] == [
             %{"field" => "admin_username", "value" => "ada-admin"}
           ]

    assert [_one] = grants_of(resp["tenant_id"])
  end

  test "POST /onboarding still echoes admin_username and admin_display_name as not_provisioned",
       ctx do
    resp =
      onboard!(ctx, %{
        "admin_email" => "ada@example.com",
        "admin_username" => "ada-admin",
        "admin_display_name" => "Ada Admin"
      })

    echoed = Map.new(resp["administrator"]["not_provisioned"], &{&1["field"], &1["value"]})
    assert echoed == %{"admin_username" => "ada-admin", "admin_display_name" => "Ada Admin"}
    assert resp["administrator"]["message"] =~ "NOT used"

    # Neither became a user or a membership: only the pending grant exists.
    schema = schema_of(resp["tenant_id"])
    assert Repo.aggregate(User, :count, :id, prefix: schema) == 0
    assert Repo.aggregate(Letflow.Identity.GroupMember, :count, :user_id, prefix: schema) == 0
  end

  test "POST /onboarding existing clients that send no admin fields behave as in PR 1", ctx do
    body = new_body(%{})
    conn = call(ctx, :post, "/api/v1/onboarding", body)

    assert conn.status == 201
    resp = json(conn)
    cleanup_onboarded_tenant!(resp["tenant_id"])

    assert Enum.sort(Map.keys(resp)) ==
             Enum.sort([
               "id",
               "tenant_id",
               "slug",
               "hostname",
               "created_at",
               "login",
               "administrator",
               "ignored_fields"
             ])

    assert resp["administrator"]["state"] == "none"
    refute Map.has_key?(resp["administrator"], "grant_id")
    assert resp["ignored_fields"] == []
    assert resp["login"]["loginable"] == false
    assert grants_of(resp["tenant_id"]) == []
  end

  test "POST /onboarding answers 201 with state not_stored when the grant insert fails", ctx do
    slug = TenantSlugFixture.unique_slug("iss1030pa")
    email = "owner.not.stored@example.com"
    handler_id = {__MODULE__, make_ref()}

    # The grants table is removed right after the onboarding record commits and just before the grant
    # insert: a real database failure of the insert, not a stub.
    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.drop_grants_table_on_registry_insert/4,
      {self(), slug}
    )

    {conn, log} =
      with_log(fn ->
        try do
          call(
            ctx,
            :post,
            "/api/v1/onboarding",
            new_body(%{"slug" => slug, "admin_email" => email})
          )
        after
          :telemetry.detach(handler_id)
        end
      end)

    resp = json(conn)
    cleanup_onboarded_tenant!(resp["tenant_id"])

    assert conn.status == 201, conn.resp_body

    administrator = resp["administrator"]
    assert administrator["state"] == "not_stored"
    assert administrator["message"] =~ "could NOT be stored"
    assert administrator["message"] =~ "no administrator"
    refute Map.has_key?(administrator, "grant_id")

    # The tenant and its onboarding record exist and are usable; only the grant is missing.
    assert %Tenant{status: :active} = Repo.get_by(Tenant, slug: slug)
    assert Repo.get_by(OnboardingRecord, tenant_id: resp["tenant_id"])

    # Nothing reached the platform chain, and the failure is logged without the address.
    assert entries(ctx.platform.schema_name, "platform.tenant_admin_grant.created") == []

    assert log =~
             "pending administrator grant not stored (tenant_id=#{inspect(resp["tenant_id"])})"

    refute log =~ ~r/\[(warning|error)\][^\n]*owner\.not\.stored@example\.com/
  end

  @doc false
  def drop_grants_table_on_registry_insert(_event, _measurements, metadata, {test_pid, slug}) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == test_pid and String.starts_with?(query, ~s(INSERT INTO "onboarding_registry")) and
         match?({:ok, _}, Map.get(metadata, :result)) do
      tenant = Repo.get_by!(Tenant, slug: slug)
      {:ok, schema} = TenantProvisioning.schema_name_for_tenant(tenant.id)
      Repo.query!(~s(DROP TABLE "#{schema}".pending_tenant_admin_grants))
    end
  end

  # --- operator list (design 5.2) -------------------------------------------------

  test "GET /onboarding/:id/pending-admins shows each grant's age_seconds and the creator read from the platform chain",
       ctx do
    resp = onboard!(ctx, %{"admin_email" => "Owner@Example.com"})
    [grant] = grants_of(resp["tenant_id"])

    # Backdate the grant by 90 minutes so the age is a real, checkable number.
    backdated = DateTime.add(DateTime.utc_now(), -5_400, :second)

    Repo.update_all(
      from(g in PendingAdminGrant, where: g.id == ^grant.id),
      [set: [inserted_at: backdated]],
      prefix: schema_of(resp["tenant_id"])
    )

    conn = call(ctx, :get, "/api/v1/onboarding/#{resp["id"]}/pending-admins", nil)
    assert conn.status == 200, conn.resp_body

    assert %{"pending_admins" => [item]} = json(conn)

    assert Enum.sort(Map.keys(item)) ==
             Enum.sort([
               "id",
               "email",
               "state",
               "age_seconds",
               "created_at",
               "created_by_user_id",
               "bound_at",
               "bound_user_id",
               "revoked_at"
             ])

    assert item["id"] == grant.id
    assert item["email"] == "owner@example.com"
    assert item["state"] == "open"
    assert is_integer(item["age_seconds"])
    assert item["age_seconds"] >= 5_400 and item["age_seconds"] < 5_400 + 600

    # The creator comes from the PLATFORM chain (the operator's own user id).
    assert item["created_by_user_id"] == ctx.operator_id
    assert item["bound_at"] == nil and item["bound_user_id"] == nil and item["revoked_at"] == nil

    # An unknown onboarding id is the plain 404.
    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      assert call(ctx, :get, "/api/v1/onboarding/#{id}/pending-admins", nil).status == 404
    end
  end

  # --- operator revoke (design 5.2) -----------------------------------------------

  test "DELETE /onboarding/:id/pending-admins/:grant_id revokes with an audit entry and a matching login then does not bind",
       ctx do
    email = "owner@example.com"
    revoked_resp = onboard!(ctx, %{"admin_email" => email, "idp_realm_id" => realm()})
    control_resp = onboard!(ctx, %{"admin_email" => email, "idp_realm_id" => realm()})
    [grant] = grants_of(revoked_resp["tenant_id"])

    # REQ-497 PR 1b N1: a second open grant, so this is not the refused last-open-grant revoke
    # of a tenant with no counted admin (that refusal is T-G5).
    _other_open = H.create_grant!(world_of(ctx, revoked_resp), "other.owner@example.com")

    conn =
      call(
        ctx,
        :delete,
        "/api/v1/onboarding/#{revoked_resp["id"]}/pending-admins/#{grant.id}",
        nil
      )

    assert conn.status == 204
    assert conn.resp_body == ""

    # The row: revoked, e-mail scrubbed.
    stored = Repo.get!(PendingAdminGrant, grant.id, prefix: schema_of(revoked_resp["tenant_id"]))
    assert PendingAdminGrant.state(stored) == :revoked
    assert stored.email_key == nil

    # Audited in both chains (NIL actor tenant side, the operator platform side).
    assert [tenant_entry] =
             entries(schema_of(revoked_resp["tenant_id"]), "tenant.admin_grant.revoked")

    assert tenant_entry.actor_id == nil
    assert tenant_entry.resource_id == grant.id
    refute inspect(tenant_entry) =~ ctx.operator_id

    assert [platform_entry] =
             ctx.platform.schema_name
             |> entries("platform.tenant_admin_grant.revoked")
             |> Enum.filter(&(&1.resource_id == grant.id))

    assert platform_entry.actor_id == ctx.operator_id

    # The matching, verified login now binds nothing ...
    revoked_world = world_of(ctx, revoked_resp)
    assert %{result: :noop} = H.login(revoked_world, email: email, verified: true)
    assert H.member_count(revoked_world) == 0

    # ... while the SAME login on the tenant whose grant was not revoked does (the control).
    control_world = world_of(ctx, control_resp)
    assert %{result: :bound} = H.login(control_world, email: email, verified: true)
    assert H.member_count(control_world) == 1
  end

  test "DELETE of an unknown grant id answers the same 404 bytes as an unknown onboarding id",
       ctx do
    resp = onboard!(ctx, %{"admin_email" => "owner@example.com"})
    [grant] = grants_of(resp["tenant_id"])

    unknown_onboarding =
      call(
        ctx,
        :delete,
        "/api/v1/onboarding/#{Ecto.UUID.generate()}/pending-admins/#{grant.id}",
        nil
      )

    unknown_grant =
      call(
        ctx,
        :delete,
        "/api/v1/onboarding/#{resp["id"]}/pending-admins/#{Ecto.UUID.generate()}",
        nil
      )

    malformed_grant =
      call(ctx, :delete, "/api/v1/onboarding/#{resp["id"]}/pending-admins/not-a-uuid", nil)

    malformed_onboarding =
      call(ctx, :delete, "/api/v1/onboarding/not-a-uuid/pending-admins/#{grant.id}", nil)

    for conn <- [unknown_onboarding, unknown_grant, malformed_grant, malformed_onboarding] do
      assert conn.status == 404, conn.resp_body
    end

    assert stable_body(unknown_grant) == stable_body(unknown_onboarding)
    assert stable_body(malformed_grant) == stable_body(unknown_onboarding)
    assert stable_body(malformed_onboarding) == stable_body(unknown_onboarding)

    # None of those touched the real grant.
    assert [still] = grants_of(resp["tenant_id"])
    assert PendingAdminGrant.state(still) == :open
    assert still.email_key == "owner@example.com"
  end

  test "DELETE of a bound grant answers 409", ctx do
    email = "owner@example.com"
    resp = onboard!(ctx, %{"admin_email" => email, "idp_realm_id" => realm()})
    world = world_of(ctx, resp)
    [grant] = grants_of(resp["tenant_id"])

    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(world, email: email, verified: true)

    path = "/api/v1/onboarding/#{resp["id"]}/pending-admins/#{grant.id}"
    conn = call(ctx, :delete, path, nil)

    assert conn.status == 409
    assert json(conn)["detail"] == "grant is not open"

    # Refused and unchanged: still bound, still a member, no revoke entry in either chain.
    stored = Repo.get!(PendingAdminGrant, grant.id, prefix: world.tenant.schema_name)
    assert PendingAdminGrant.state(stored) == :bound
    assert stored.consumed_by_user_id == user.id
    assert "TENANT_ADMIN" in H.roles(world, user.id)
    assert entries(world.tenant.schema_name, "tenant.admin_grant.revoked") == []
    assert entries(ctx.platform.schema_name, "platform.tenant_admin_grant.revoked") == []

    # An already revoked grant answers the same way.
    second = onboard!(ctx, %{"admin_email" => "second@example.com"})
    [open] = grants_of(second["tenant_id"])
    # REQ-497 PR 1b N1: a second open grant, so the first revoke is not the refused last one.
    _other_open = H.create_grant!(world_of(ctx, second), "other.second@example.com")
    second_path = "/api/v1/onboarding/#{second["id"]}/pending-admins/#{open.id}"
    assert call(ctx, :delete, second_path, nil).status == 204

    again = call(ctx, :delete, second_path, nil)
    assert again.status == 409
    assert json(again)["detail"] == "grant is not open"
  end

  test "an admin of another tenant gets the uniform 403 on both new routes, byte-identical for a matched and an unmatched path",
       ctx do
    resp = onboard!(ctx, %{"admin_email" => "owner@example.com"})
    [grant] = grants_of(resp["tenant_id"])

    outsider = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030pa-outsider")
    outsider_token = Fixture.mint_token!(outsider, ["TENANT_ADMIN"])
    # A TENANT_ADMIN of the platform tenant itself: not the operator role, so not platform scope.
    platform_admin_token = Fixture.mint_token!(ctx.platform, ["TENANT_ADMIN"])

    as = fn token, slug, method, path ->
      method |> Fixture.api_conn(path, token, slug, nil) |> Fixture.dispatch_api()
    end

    callers = [
      {outsider_token, outsider.tenant.slug},
      {platform_admin_token, ctx.platform.tenant.slug}
    ]

    for {token, slug} <- callers do
      list = as.(token, slug, :get, "/api/v1/onboarding/#{resp["id"]}/pending-admins")

      revoke =
        as.(token, slug, :delete, "/api/v1/onboarding/#{resp["id"]}/pending-admins/#{grant.id}")

      unknown_list =
        as.(token, slug, :get, "/api/v1/onboarding/#{Ecto.UUID.generate()}/pending-admins")

      unknown_revoke =
        as.(
          token,
          slug,
          :delete,
          "/api/v1/onboarding/#{Ecto.UUID.generate()}/pending-admins/#{Ecto.UUID.generate()}"
        )

      unmatched = as.(token, slug, :delete, "/api/v1/onboarding/x/y/z/w")

      all = [list, revoke, unknown_list, unknown_revoke, unmatched]
      for conn <- all, do: assert(conn.status == 403, conn.resp_body)

      # One answer for a real and an unknown onboarding, a grant or none, a matched or unmatched path.
      for conn <- all do
        assert stable_body(conn) == stable_body(list)
        refute conn.resp_body =~ resp["tenant_id"]
        refute conn.resp_body =~ grant.id
      end
    end

    # INV-10: nothing was written for the target tenant.
    [still] = grants_of(resp["tenant_id"])
    assert PendingAdminGrant.state(still) == :open
    assert entries(schema_of(resp["tenant_id"]), "tenant.admin_grant.revoked") == []
    assert entries(ctx.platform.schema_name, "platform.tenant_admin_grant.revoked") == []
    assert entries(outsider.schema_name, "platform.tenant_admin_grant.revoked") == []
  end
end
