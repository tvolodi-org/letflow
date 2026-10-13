defmodule Letflow.Routers.AuditPlatformEntriesIsolationTest do
  @moduledoc """
  ISS-1030 PR 2 (design 7a, N7) -- the PLATFORM audit chain, which now carries entries that name
  customer tenants (`tenant_id`, `bound_user_id`) and the operator, is readable only through the
  platform tenant's own `GET /api/v1/audit`; an administrator of any other tenant reads that
  tenant's own schema only and can never reach a platform-chain entry.

  Real Postgres, real tenant schemas, real API tokens through the real `Letflow.Router`.
  `async: false`: the platform pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  defp get_audit(token, slug, query \\ "?page_size=200") do
    :get
    |> Fixture.api_conn("/api/v1/audit" <> query, token, slug, nil)
    |> Fixture.dispatch_api()
  end

  defp actions(conn),
    do: conn.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["action"])

  test "GET /audit as an admin of a non-platform tenant never returns platform-chain entries of any tenant" do
    w = H.world!()
    other = H.second_tenant!(w)

    # Platform-chain entries that name the customer tenant, from every operation that writes one:
    # created, bound (a verified login), revoked.
    _bound = H.create_grant!(w, "owner@example.com")
    revoked = H.create_grant!(w, "withdrawn@example.com")
    _other_grant = H.create_grant!(other, "other.owner@example.com")

    assert %{result: :bound, provisioned: %{user: bound_user}} =
             H.login(w, email: "owner@example.com", verified: true)

    assert :ok =
             Letflow.Identity.PendingAdminGrants.revoke(revoked.id, %{user_id: w.operator_id},
               prefix: w.tenant.schema_name,
               platform_prefix: w.platform.schema_name
             )

    # Positive control: the platform chain really holds them, and the PLATFORM admin reads them.
    platform_token = Fixture.mint_token!(w.platform, ["PLATFORM_ADMIN"])
    platform_view = get_audit(platform_token, w.platform.tenant.slug)
    assert platform_view.status == 200, platform_view.resp_body
    platform_seen = actions(platform_view)

    for action <- [
          "platform.tenant_admin_grant.created",
          "platform.tenant_admin_grant.bound",
          "platform.tenant_admin_grant.revoked"
        ] do
      assert action in platform_seen, "control: #{action} is not in the platform chain view"
    end

    # Customer tenant admins: their own chain, and nothing of the platform's.
    for {world, label} <- [{w, "the tenant the entries are about"}, {other, "another tenant"}] do
      token = Fixture.mint_token!(world.tenant, ["TENANT_ADMIN"])
      conn = get_audit(token, world.tenant.tenant.slug)

      assert conn.status == 200, "#{label}: #{conn.resp_body}"
      items = Jason.decode!(conn.resp_body)["items"]
      assert items != [], "#{label}: the customer chain is empty, so this proves nothing"

      for item <- items do
        refute String.starts_with?(item["action"], "platform."),
               "#{label} read a platform-chain entry: #{item["action"]}"

        refute item["actor_id"] == w.operator_id, "#{label} read the operator's id"
      end

      refute conn.resp_body =~ w.operator_id
      refute conn.resp_body =~ w.platform.tenant_id
      refute conn.resp_body =~ w.platform.schema_name
    end

    # The tenant it is about does see ITS OWN entries (created/bound/revoked), without the operator.
    own = get_audit(Fixture.mint_token!(w.tenant, ["TENANT_ADMIN"]), w.tenant.tenant.slug)

    for action <- [
          "tenant.admin_grant.created",
          "tenant.admin_grant.bound",
          "tenant.admin_grant.revoked"
        ] do
      assert action in actions(own), action
    end

    bound_entry =
      own.resp_body
      |> Jason.decode!()
      |> Map.fetch!("items")
      |> Enum.find(&(&1["action"] == "tenant.admin_grant.bound"))

    assert bound_entry["actor_id"] == bound_user.id

    # And a tenant admin cannot point the read at the platform chain by any request parameter.
    token = Fixture.mint_token!(w.tenant, ["TENANT_ADMIN"])

    for query <- [
          "?resource_type=pending_admin_grant&actor_id=#{w.operator_id}",
          "?tenant_id=#{w.platform.tenant_id}",
          "?prefix=#{w.platform.schema_name}"
        ] do
      conn = get_audit(token, w.tenant.tenant.slug, query)

      assert conn.status in [200, 400, 422], "#{query}: #{conn.status}"
      refute conn.resp_body =~ "platform.tenant_admin_grant", query
      refute conn.resp_body =~ w.operator_id, query
    end
  end
end
