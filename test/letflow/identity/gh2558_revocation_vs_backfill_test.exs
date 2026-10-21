defmodule Letflow.Identity.Gh2558RevocationVsBackfillTest do
  @moduledoc """
  GH 2558: an explicit revocation (`remove_group_member/3`) survives a `RoleBackfill` marker
  reset: the next IdP role sync withholds the revoked group (`Letflow.Identity.RoleRevocations`),
  audits that as `grant.sync_revocation_honored`, and the backfill reports the users concerned in
  its `role_claims_sync.reset` row. Decision: option 1, see the moduledoc of `RoleRevocations`.

    * AC2: the main scenario, its forced-nil-marker, re-add and pending-grant-bind variants, and
      the newly seeded role variant.
    * AC3: audit content of the reset row and of the honoured entry.
    * AC4: users without a conflict are unchanged.
    * AC5: cross-tenant negative (INV-1, INV-10).

  Real Postgres, real tenant schemas. `async: false`: the backfill sweeps every registration (all
  but the kept ones are hidden for the test), the platform pin and the OIDC verifier are global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleBackfill
  alias Letflow.Identity.RoleRevocations
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PendingAdminTokenVerifierDouble, as: Double
  alias Letflow.TenantProvisioning.Registration

  @trace "gh2558-login-trace-0001"

  defp group_of!(schema, role_name) do
    Repo.one!(from(t in TenantRole, where: t.name == ^role_name, select: t.group_id),
      prefix: schema
    )
  end

  defp member?(schema, group_id, user_id) do
    Repo.exists?(from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id),
      prefix: schema
    )
  end

  defp marker(schema, user_id), do: Repo.get!(User, user_id, prefix: schema).role_claims_synced_at

  defp entries(schema, action), do: H.entries(schema, action)

  defp user!(schema) do
    n = System.unique_integer([:positive])

    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2558-#{n}",
      display_name: "GH2558 #{n}",
      email: "gh2558-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  # Hides every registration but those of `worlds`' tenants (RoleBackfill.run/0 sweeps all).
  defp isolate_registrations!(tenants) do
    keep_ids = Enum.map(tenants, & &1.tenant_id)

    others =
      Repo.all(
        from(r in Registration,
          where: r.tenant_id not in ^keep_ids,
          select: %{
            id: r.id,
            tenant_id: r.tenant_id,
            schema_name: r.schema_name,
            migrations_applied_at: r.migrations_applied_at,
            provisioned_at: r.provisioned_at
          }
        )
      )

    Repo.delete_all(from(r in Registration, where: r.id in ^Enum.map(others, & &1.id)))
    on_exit(fn -> Repo.insert_all(Registration, others, on_conflict: :nothing) end)
    :ok
  end

  # Makes the tenant classify as `:seeded`: one platform-role binding is missing, so the
  # backfill re-creates it and resets the markers.
  defp drop_binding!(schema, role_name) do
    Repo.delete_all(from(t in TenantRole, where: t.name == ^role_name), prefix: schema)
  end

  defp oidc_request(token) do
    conn(:get, "/api/v1/identity/users")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-trace-id", @trace)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  # A TENANT_ADMIN user U (synced in through the real sync) plus a second admin so U's removal
  # is not refused as the last tenant-wide admin. Returns U.
  defp synced_admin!(w, sub) do
    %{provisioned: %{user: user}} =
      H.login(w, sub: sub, email: sub <> "@example.com", roles: ["TENANT_ADMIN"])

    ta = group_of!(w.tenant.schema_name, "TENANT_ADMIN")
    other = user!(w.tenant.schema_name)
    :ok = Identity.add_group_member(ta, other.id, prefix: w.tenant.schema_name) |> ok!()
    assert member?(w.tenant.schema_name, ta, user.id)
    user
  end

  defp ok!(:ok), do: :ok
  defp ok!({:ok, _}), do: :ok

  defp revoke!(w, user) do
    ta = group_of!(w.tenant.schema_name, "TENANT_ADMIN")
    assert :ok = Identity.remove_group_member(ta, user.id, prefix: w.tenant.schema_name)
    ta
  end

  describe "revocation vs. backfill (AC2, AC3)" do
    test "an admin revokes TENANT_ADMIN, the backfill runs, U logs in over OIDC with the claim: no re-grant" do
      H.use_double!()
      w = H.world!()
      schema = w.tenant.schema_name
      isolate_registrations!([w.tenant, w.platform])

      sub = "sub-gh2558-main"
      u = synced_admin!(w, sub)
      assert %DateTime{} = marker(schema, u.id)
      ta = revoke!(w, u)
      refute member?(schema, ta, u.id)

      drop_binding!(schema, "PROCESS_DESIGNER")
      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()
      assert w.tenant.tenant_id in seeded
      assert marker(schema, u.id) == nil

      # AC3: the reset row.
      assert [reset] = entries(schema, "role_claims_sync.reset")
      assert reset.actor_id == nil
      assert reset.after_state["source"] == "role_backfill"
      assert u.id in reset.after_state["reset_user_ids"]
      assert reset.after_state["reset_count"] == length(reset.after_state["reset_user_ids"])
      assert reset.after_state["revocation_honored_user_ids"] == [u.id]
      assert reset.after_state["revocation_honored_count"] == 1
      assert is_binary(reset.trace_id) and reset.trace_id != ""

      conn =
        w.realm
        |> Double.token(sub: sub, email: sub <> "@example.com", roles: ["TENANT_ADMIN"])
        |> oidc_request()

      assert conn.status < 500, conn.resp_body

      refute member?(schema, ta, u.id)
      refute "TENANT_ADMIN" in H.roles(w, u.id)
      assert %DateTime{} = marker(schema, u.id)

      assert [honored] = entries(schema, "grant.sync_revocation_honored")
      assert honored.actor_id == u.id
      assert honored.resource_type == "group_member"
      assert honored.resource_id == u.id
      assert honored.trace_id == @trace
      assert honored.after_state["withheld_group_ids"] == [ta]
      assert honored.after_state["withheld_roles"] == ["TENANT_ADMIN"]
      assert honored.after_state["source"] == "idp_sync"
      assert {:ok, :valid} = Letflow.Audit.verify_chain(schema)
    end

    test "without any backfill: a nil marker alone does not re-grant a revoked role" do
      w = H.world!()
      schema = w.tenant.schema_name
      sub = "sub-gh2558-nil"
      u = synced_admin!(w, sub)
      ta = revoke!(w, u)

      u |> Ecto.Changeset.change(role_claims_synced_at: nil) |> Repo.update!(prefix: schema)

      H.login(w, sub: sub, email: sub <> "@example.com", roles: ["TENANT_ADMIN"])

      refute member?(schema, ta, u.id)
      assert [_one] = entries(schema, "grant.sync_revocation_honored")
      assert %DateTime{} = marker(schema, u.id)

      # A later login does not sync again, so no second entry.
      H.login(w, sub: sub, email: sub <> "@example.com", roles: ["TENANT_ADMIN"])
      assert [_one] = entries(schema, "grant.sync_revocation_honored")
    end

    test "an explicit re-add by an admin lifts the revocation" do
      w = H.world!()
      schema = w.tenant.schema_name
      isolate_registrations!([w.tenant, w.platform])
      u = synced_admin!(w, "sub-gh2558-readd")
      ta = revoke!(w, u)

      assert :ok = Identity.add_group_member(ta, u.id, prefix: schema) |> ok!()
      assert MapSet.size(RoleRevocations.revoked_group_ids(u.id, schema)) == 0

      drop_binding!(schema, "PROCESS_DESIGNER")
      assert {:ok, _} = RoleBackfill.run()
      assert [reset] = entries(schema, "role_claims_sync.reset")
      assert reset.after_state["revocation_honored_user_ids"] == []

      H.login(w,
        sub: "sub-gh2558-readd",
        email: "sub-gh2558-readd@example.com",
        roles: ["TENANT_ADMIN"]
      )

      assert member?(schema, ta, u.id)
      assert entries(schema, "grant.sync_revocation_honored") == []
    end

    test "remove, then a pending TENANT_ADMIN grant bind: the membership lifts the revocation" do
      w = H.world!()
      schema = w.tenant.schema_name
      sub = "sub-gh2558-bind"
      email = sub <> "@example.com"
      u = synced_admin!(w, sub)
      ta = revoke!(w, u)

      _grant = H.create_grant!(w, email)
      u |> Ecto.Changeset.change(role_claims_synced_at: nil) |> Repo.update!(prefix: schema)
      assert %{result: :bound} = H.login(w, sub: sub, email: email, roles: [])
      assert member?(schema, ta, u.id)
      assert MapSet.size(RoleRevocations.revoked_group_ids(u.id, schema)) == 0

      u |> Ecto.Changeset.change(role_claims_synced_at: nil) |> Repo.update!(prefix: schema)
      assert RoleRevocations.users_with_revocation([u.id], schema) == MapSet.new()

      H.login(w, sub: sub, email: email, roles: ["TENANT_ADMIN"])
      assert member?(schema, ta, u.id)
      assert "TENANT_ADMIN" in H.roles(w, u.id)
      assert entries(schema, "grant.sync_revocation_honored") == []
    end

    test "a user with a revoked group A still receives a role the backfill newly seeded" do
      w = H.world!()
      schema = w.tenant.schema_name
      isolate_registrations!([w.tenant, w.platform])
      sub = "sub-gh2558-newrole"
      email = sub <> "@example.com"
      u = synced_admin!(w, sub)
      ta = revoke!(w, u)

      drop_binding!(schema, "PROCESS_DESIGNER")
      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()
      assert w.tenant.tenant_id in seeded
      assert marker(schema, u.id) == nil

      H.login(w, sub: sub, email: email, roles: ["TENANT_ADMIN", "PROCESS_DESIGNER"])

      refute member?(schema, ta, u.id)
      assert member?(schema, group_of!(schema, "PROCESS_DESIGNER"), u.id)
      assert "PROCESS_DESIGNER" in H.roles(w, u.id)
      refute "TENANT_ADMIN" in H.roles(w, u.id)

      assert [honored] = entries(schema, "grant.sync_revocation_honored")
      assert honored.after_state["withheld_roles"] == ["TENANT_ADMIN"]
    end
  end

  describe "no change without a conflict (AC4)" do
    test "users never removed keep today's reset payload and still sync their claims" do
      w = H.world!()
      schema = w.tenant.schema_name
      isolate_registrations!([w.tenant, w.platform])

      u1 = synced_admin!(w, "sub-gh2558-ok1")
      %{provisioned: %{user: u2}} = H.login(w, sub: "sub-gh2558-ok2", roles: ["PROCESS_DESIGNER"])
      never = user!(schema)

      drop_binding!(schema, "PROCESS_DESIGNER")
      assert {:ok, result} = RoleBackfill.run()
      assert w.tenant.tenant_id in result.seeded

      assert [reset] = entries(schema, "role_claims_sync.reset")

      assert reset.after_state["reset_user_ids"] |> Enum.sort() ==
               Enum.sort([u1.id, u2.id, never.id] ++ other_ids(schema, [u1, u2, never]))

      assert reset.after_state["reset_count"] == length(reset.after_state["reset_user_ids"])
      assert result.role_claims_markers_reset == reset.after_state["reset_count"]
      assert reset.after_state["revocation_honored_user_ids"] == []
      assert reset.after_state["revocation_honored_count"] == 0

      H.login(w,
        sub: "sub-gh2558-ok1",
        email: "sub-gh2558-ok1@example.com",
        roles: ["TENANT_ADMIN"]
      )

      assert "TENANT_ADMIN" in H.roles(w, u1.id)
      assert entries(schema, "grant.sync_revocation_honored") == []
    end
  end

  describe "cross-tenant negative (AC5, INV-1 / INV-10)" do
    test "a revocation in tenant A is invisible in tenant B and does not affect B's sync" do
      wa = H.world!()
      wb = H.second_tenant!(wa)
      sa = wa.tenant.schema_name
      sb = wb.tenant.schema_name
      isolate_registrations!([wa.tenant, wb.tenant, wa.platform])

      ua = synced_admin!(wa, "sub-gh2558-xa")
      ub = synced_admin!(wb, "sub-gh2558-xb")
      ta_a = revoke!(wa, ua)
      ta_b = group_of!(sb, "TENANT_ADMIN")

      # The same user id read under the other tenant's prefix finds nothing.
      assert MapSet.size(RoleRevocations.revoked_group_ids(ua.id, sb)) == 0
      assert MapSet.size(RoleRevocations.revoked_group_ids(ub.id, sa)) == 0
      assert RoleRevocations.users_with_revocation([ua.id, ub.id], sb) == MapSet.new()
      assert RoleRevocations.users_with_revocation([ua.id, ub.id], sa) == MapSet.new([ua.id])

      drop_binding!(sa, "PROCESS_DESIGNER")
      drop_binding!(sb, "PROCESS_DESIGNER")
      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()
      assert wa.tenant.tenant_id in seeded and wb.tenant.tenant_id in seeded

      assert marker(sa, ua.id) == nil
      assert marker(sb, ub.id) == nil

      [ra] = entries(sa, "role_claims_sync.reset")
      [rb] = entries(sb, "role_claims_sync.reset")
      assert ra.after_state["revocation_honored_user_ids"] == [ua.id]
      assert rb.after_state["revocation_honored_user_ids"] == []
      refute ua.id in rb.after_state["reset_user_ids"]
      refute ub.id in ra.after_state["reset_user_ids"]

      H.login(wa,
        sub: "sub-gh2558-xa",
        email: "sub-gh2558-xa@example.com",
        roles: ["TENANT_ADMIN"]
      )

      H.login(wb,
        sub: "sub-gh2558-xb",
        email: "sub-gh2558-xb@example.com",
        roles: ["TENANT_ADMIN"]
      )

      refute member?(sa, ta_a, ua.id)
      assert member?(sb, ta_b, ub.id)
      assert [_one] = entries(sa, "grant.sync_revocation_honored")
      assert entries(sb, "grant.sync_revocation_honored") == []

      # Audit rows stay in the owning tenant's chain.
      refute Repo.exists?(
               from(e in Entry, where: e.action == "grant.sync_revocation_honored"),
               prefix: sb
             )
    end
  end

  defp other_ids(schema, known) do
    known_ids = Enum.map(known, & &1.id)

    Repo.all(from(u in User, where: u.id not in ^known_ids, select: u.id), prefix: schema)
  end
end
