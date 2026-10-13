defmodule Letflow.Routers.IdentityPendingAdminGrantsTest do
  @moduledoc """
  ISS-1030 PR 2 (design 5.3, decision B) -- `GET /api/v1/identity/pending-admin-grants`: the
  tenant's own `TENANT_ADMIN` READS (never writes) its tenant's pending administrator grants,
  under the existing `:UsersManage` permission.

  Real Postgres, real tenant schemas, real API tokens through the real `Letflow.Router`.
  `async: false`: the fixture flips the sandbox to `:auto`, and the platform pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/identity/pending-admin-grants"

  setup do
    w = H.world!()
    %{w: w, token: Fixture.mint_token!(w.tenant, ["TENANT_ADMIN"])}
  end

  defp get(w, token, path \\ @path) do
    :get
    |> Fixture.api_conn(path, token, w.tenant.tenant.slug, nil)
    |> Fixture.dispatch_api()
  end

  defp items(conn), do: Jason.decode!(conn.resp_body)["pending_admins"]

  defp revoke!(w, grant) do
    :ok =
      PendingAdminGrants.revoke(grant.id, %{user_id: w.operator_id},
        prefix: w.tenant.schema_name,
        platform_prefix: w.platform.schema_name
      )
  end

  test "a TENANT_ADMIN reads its own tenant's pending grants", %{w: w, token: token} do
    open = H.create_grant!(w, "Open.Owner@Example.com")
    bound = H.create_grant!(w, "bound.owner@example.com")
    assert %{result: :bound} = H.login(w, email: "bound.owner@example.com", verified: true)

    conn = get(w, token)
    assert conn.status == 200, conn.resp_body

    assert [open_item, bound_item] = items(conn)

    allowed = ["age_seconds", "bound_at", "created_at", "created_via", "email", "id", "state"]
    assert Enum.sort(Map.keys(open_item)) == allowed
    assert Enum.sort(Map.keys(bound_item)) == allowed

    # Oldest first. An open grant shows its (normalised) address and its age.
    assert open_item["id"] == open.id
    assert open_item["email"] == "open.owner@example.com"
    assert open_item["state"] == "open"
    assert is_integer(open_item["age_seconds"]) and open_item["age_seconds"] >= 0
    assert open_item["bound_at"] == nil
    assert open_item["created_via"] == "platform_operator_onboarding"
    assert is_binary(open_item["created_at"])

    # A bound grant: scrubbed address, no age, a bound timestamp.
    assert bound_item["id"] == bound.id
    assert bound_item["email"] == nil
    assert bound_item["state"] == "bound"
    assert bound_item["age_seconds"] == nil
    assert is_binary(bound_item["bound_at"])

    # A revoked grant too.
    revoked = H.create_grant!(w, "revoked.owner@example.com")
    revoke!(w, revoked)

    states = w |> get(token) |> items() |> Map.new(&{&1["id"], {&1["state"], &1["email"]}})
    assert states[revoked.id] == {"revoked", nil}
    assert states[open.id] == {"open", "open.owner@example.com"}
  end

  test "a caller without :UsersManage gets 403", %{w: w} do
    _grant = H.create_grant!(w, "owner@example.com")

    for roles <- [["TASK_WORKER"], ["PROCESS_DESIGNER"], ["AGENT_RUNNER"]] do
      token = Fixture.mint_token!(w.tenant, roles)
      conn = get(w, token)

      assert conn.status == 403, "#{inspect(roles)}: #{conn.status} #{conn.resp_body}"
      refute conn.resp_body =~ "owner@example.com"
    end

    # No credentials at all: 401, not an empty list.
    anonymous = Plug.Test.conn(:get, @path) |> Letflow.Router.call(Letflow.Router.init([]))
    assert anonymous.status == 401
  end

  test "the tenant view omits creator, revoker and bound-user ids", %{w: w, token: token} do
    _open = H.create_grant!(w, "open@example.com")
    _bound = H.create_grant!(w, "bound@example.com")
    revoked = H.create_grant!(w, "revoked@example.com")

    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(w, email: "bound@example.com", verified: true)

    revoke!(w, revoked)

    conn = get(w, token)
    assert conn.status == 200
    body = conn.resp_body

    # No key and no value that identifies an operator, a revoker or the bound user.
    for forbidden_key <- [
          "created_by_user_id",
          "created_by",
          "creator",
          "revoked_by",
          "revoked_at",
          "bound_user_id",
          "consumed_by_user_id",
          "consumed_at",
          "actor_id",
          "onboarding_id"
        ] do
      refute body =~ ~s("#{forbidden_key}"), forbidden_key
    end

    refute body =~ w.operator_id
    refute body =~ user.id
    refute body =~ w.platform.tenant_id
    refute body =~ w.platform.schema_name
    refute body =~ "t-op"
  end

  test "the route accepts no write verb", %{w: w, token: token} do
    grant = H.create_grant!(w, "owner@example.com")

    snapshot = fn ->
      w |> H.grants() |> Enum.map(&Map.take(&1, [:id, :email_key, :consumed_at, :revoked_at]))
    end

    before_writes = snapshot.()

    for method <- [:post, :put, :patch, :delete], path <- [@path, @path <> "/" <> grant.id] do
      conn =
        method
        |> Fixture.api_conn(path, token, w.tenant.tenant.slug, %{"email" => "new@example.com"})
        |> Fixture.dispatch_api()

      assert conn.status >= 400, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
    end

    assert snapshot.() == before_writes
    assert PendingAdminGrant.state(H.grant(w, grant.id)) == :open
    assert H.entries(w.tenant.schema_name, "tenant.admin_grant.revoked") == []
  end

  test "a TENANT_ADMIN never sees another tenant's grants", %{w: w, token: token} do
    other = H.second_tenant!(w)
    other_token = Fixture.mint_token!(other.tenant, ["TENANT_ADMIN"])

    mine = H.create_grant!(w, "mine@example.com")
    theirs = H.create_grant!(other, "theirs@example.com")

    mine_view = get(w, token)
    assert [%{"id" => mine_id}] = items(mine_view)
    assert mine_id == mine.id
    refute mine_view.resp_body =~ "theirs@example.com"
    refute mine_view.resp_body =~ theirs.id

    theirs_view = get(other, other_token)
    assert [%{"id" => theirs_id}] = items(theirs_view)
    assert theirs_id == theirs.id
    refute theirs_view.resp_body =~ "mine@example.com"
    refute theirs_view.resp_body =~ mine.id

    # No request value selects a tenant: a tenant identifier in the query changes nothing.
    for query <- ["?tenant_id=#{other.tenant.tenant_id}", "?slug=#{other.tenant.tenant.slug}"] do
      conn = get(w, token, @path <> query)
      assert conn.status in [200, 400, 422]
      refute conn.resp_body =~ theirs.id
      refute conn.resp_body =~ "theirs@example.com"
    end

    # The other tenant's slug with this tenant's token is not authenticated at all.
    crossed = get(other, token)
    assert crossed.status == 401
    refute crossed.resp_body =~ theirs.id
    refute crossed.resp_body =~ "theirs@example.com"
  end
end
