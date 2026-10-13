defmodule Letflow.Plugs.PendingAdminLoginResponseTest do
  @moduledoc """
  ISS-1030 PR 2 -- the binding as seen from OUTSIDE the auth pipeline (design section 7 steps
  11 and 13, AC 7 "response identical with and without a grant").

  Every request here goes through the real `Letflow.Plugs.AuthPipeline` (and, where a response is
  compared, the real `Letflow.Router`) with a bearer token whose claims the test chooses
  (`Letflow.Support.PendingAdminTokenVerifierDouble`), against real Postgres and real tenant schemas.
  There is no Letflow login endpoint (Keycloak signs the user in; Letflow sees bearer requests), so
  "the login response" is the response of the authenticated request (design OQ-4): for every caller
  who does not legitimately bind, status, headers and body are byte-identical with and without a
  pending grant.

  `async: false`: the OIDC verifier selection and the platform pin are VM-global.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PendingAdminTokenVerifierDouble, as: Double

  setup do
    H.use_double!()
    # Tenant A holds a pending grant; tenant B (same platform, own realm) never gets one.
    a = H.world!()
    b = H.second_tenant!(a)
    %{a: a, b: b}
  end

  # --- helpers ---------------------------------------------------------------

  defp authenticated(token, method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp through_router(token, method, path) do
    token
    |> authenticated(method, path)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  # Everything the caller can observe, minus the per-request trace id and request id.
  defp observable(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _value} -> name in ["x-trace-id", "x-request-id"] end)
      |> Enum.sort()

    body = Regex.replace(~r/"trace_id":"[^"]*",?/, conn.resp_body, "")
    {conn.status, headers, body}
  end

  # --- byte-identical responses ----------------------------------------------

  test "a non-matching user's response is byte-identical in a tenant with a pending grant and in a tenant without one",
       %{a: a, b: b} do
    grant = H.create_grant!(a, "owner@example.com")

    for {path, roles} <- [
          {"/api/v1/identity/users", []},
          {"/api/v1/identity/pending-admin-grants", ["TASK_WORKER"]}
        ] do
      with_grant =
        a.realm
        |> Double.token(email: "stranger@example.com", email_verified: true, roles: roles)
        |> through_router(:get, path)

      without_grant =
        b.realm
        |> Double.token(email: "stranger@example.com", email_verified: true, roles: roles)
        |> through_router(:get, path)

      assert with_grant.status == 403, "#{path}: #{with_grant.resp_body}"
      assert observable(with_grant) == observable(without_grant), path
    end

    # The grant is exactly as it was: the stranger bound nothing and consumed nothing.
    assert PendingAdminGrant.state(H.grant(a, grant.id)) == :open

    admin_group = H.admin_group_id!(a)

    assert Repo.aggregate(
             from(m in GroupMember, where: m.group_id == ^admin_group),
             :count,
             :user_id,
             prefix: a.tenant.schema_name
           ) == 0

    assert H.entries(a.tenant.schema_name, "tenant.admin_grant.bound") == []
  end

  test "an unverified user whose e-mail equals the pending key gets a response byte-identical to the no-grant case",
       %{a: a, b: b} do
    grant = H.create_grant!(a, "owner@example.com")

    for email_verified <- [false, "true", :omit] do
      token_a = Double.token(a.realm, email: "owner@example.com", email_verified: email_verified)
      token_b = Double.token(b.realm, email: "owner@example.com", email_verified: email_verified)

      with_grant = through_router(token_a, :get, "/api/v1/identity/users")
      without_grant = through_router(token_b, :get, "/api/v1/identity/users")

      assert with_grant.status == 403, inspect(email_verified)
      assert observable(with_grant) == observable(without_grant), inspect(email_verified)
    end

    # ... and it really was a refusal to bind, not a missing grant.
    stored = H.grant(a, grant.id)
    assert PendingAdminGrant.state(stored) == :open
    assert stored.email_key == "owner@example.com"
    assert H.member_count(a) == 0
    assert H.entries(a.platform.schema_name, "platform.tenant_admin_grant.bound") == []
  end

  # --- logging (INV-4) -------------------------------------------------------

  test "no log line contains the pending e-mail or the claim e-mail on a successful bind, a failed bind or a revoke",
       %{a: a} do
    pending = "pending.owner@example.com"
    other_pending = "withdrawn.owner@example.com"
    stranger = "stranger.claim@example.com"

    _bind = H.create_grant!(a, pending)
    withdrawn = H.create_grant!(a, other_pending)

    {_result, log} =
      with_log(fn ->
        # A failed bind: a verified stranger.
        failed_stranger =
          a.realm
          |> Double.token(email: stranger)
          |> authenticated(:get, "/x")
          |> AuthPipeline.call([])

        # A successful bind.
        success =
          a.realm
          |> Double.token(email: pending)
          |> authenticated(:get, "/x")
          |> AuthPipeline.call([])

        # A failed bind of a second person holding the same address, unverified.
        failed_unverified =
          a.realm
          |> Double.token(email: pending, email_verified: false)
          |> authenticated(:get, "/x")
          |> AuthPipeline.call([])

        # A revoke.
        :ok =
          PendingAdminGrants.revoke(withdrawn.id, %{user_id: a.operator_id},
            prefix: a.tenant.schema_name,
            platform_prefix: a.platform.schema_name
          )

        {failed_stranger.halted, failed_unverified.halted, success.halted}
      end)

    entries = H.non_sql_entries(log)
    assert entries != []

    # The feature's own lines exist (the expected no-op is logged at debug) ...
    assert Enum.any?(entries, &(&1 =~ "pending administrator bind skipped"))

    # ... and no line of anything other than Ecto's SQL echo carries an address.
    for entry <- entries, email <- [pending, other_pending, stranger] do
      refute String.downcase(entry) =~ email,
             "an address was logged: #{String.slice(entry, 0, 160)}"
    end

    # Control: the bind really happened, so this was not a log of a request that did nothing.
    assert [_] = H.entries(a.tenant.schema_name, "tenant.admin_grant.bound")
    assert [_] = H.entries(a.tenant.schema_name, "tenant.admin_grant.revoked")
  end

  # --- the binding request itself ---------------------------------------------

  test "the binding request itself already sees TENANT_ADMIN in the auth context", %{a: a} do
    grant = H.create_grant!(a, "owner@example.com")

    # The pipeline's own output: the FIRST request of a never-seen user, so the user is created, bound
    # and its roles read, all within this one call.
    conn =
      a.realm
      |> Double.token(email: "owner@example.com", email_verified: true)
      |> authenticated(:get, "/anything")
      |> AuthPipeline.call([])

    refute conn.halted
    assert conn.assigns.auth_context.roles == ["TENANT_ADMIN"]
    assert conn.assigns.auth_context.tenant_id == a.tenant.tenant_id
    assert PendingAdminGrant.state(H.grant(a, grant.id)) == :bound
  end

  test "the first request of the bound person is authorised as TENANT_ADMIN end to end", %{a: a} do
    grant = H.create_grant!(a, "owner@example.com")

    # A route only `:UsersManage` may read, as the FIRST request of that person: 200, and the answer
    # already shows the grant as bound.
    conn =
      a.realm
      |> Double.token(email: "owner@example.com", email_verified: true)
      |> through_router(:get, "/api/v1/identity/pending-admin-grants")

    assert conn.status == 200, conn.resp_body
    assert [item] = Jason.decode!(conn.resp_body)["pending_admins"]
    assert item["id"] == grant.id
    assert item["state"] == "bound"
    assert item["email"] == nil

    # Control: the same address, unverified, on a never-seen user is refused on the same route and the
    # grant of a second tenant admin candidate stays pending.
    other = H.create_grant!(a, "second.owner@example.com")

    refused =
      a.realm
      |> Double.token(email: "second.owner@example.com", email_verified: false)
      |> through_router(:get, "/api/v1/identity/pending-admin-grants")

    assert refused.status == 403
    assert PendingAdminGrant.state(H.grant(a, other.id)) == :open
  end
end
