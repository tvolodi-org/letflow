defmodule Letflow.Identity.LastInteractiveAdminControlsTest do
  @moduledoc """
  GH #2869 part (a) (design `lib/letflow/design/gh2869-last-interactive-admin-guard.md` r4,
  section 3.6 and section 5; spec `test/specs/GH2869-last-interactive-admin-guard.md`): the
  positive controls of the guard. Every write path that takes lock A but CANNOT lower the
  interactive explicit tenant-wide admin count (classes N, P7 to P17) gets ONE test that the
  write is allowed and the count does not drop, so a guard that over-reaches (blocks the add
  paths, the recovery moves, or acts at zero) fails here:

    * T-LA-P7 to T-LA-P17: add a member, delete a memberless group, role-claim sync, token mint
      and create, scoping (create) and make-tenant-wide, token revoke, pending-grant revoke and
      bind, platform-role seeding, TenantAdminMigration and Backfill in an `on` tenant;
    * T-LA-17 divergence: the gate's fact 4 input and the guard's before-count are the SAME
      function, equal for every shape of a matrix;
    * T-LA-29 recovery: in an `on` tenant at zero interactive admins a TENANT_ADMIN token can
      add a member (the count is restored), cannot flip the flag (403), and the break-glass
      flips it down.

  `async: false`: committed state in real tenant schemas, VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrants.Backfill
  alias Letflow.Identity.ScopedGrants
  alias Letflow.Identity.TenantAdminGuard
  alias Letflow.Identity.TenantAdminMigration, as: Migration
  alias Letflow.Identity.User
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.OnGate
  alias Letflow.Support.EnforcedWritersFixture, as: EW
  alias Letflow.Support.LastInteractiveAdminFixture, as: LIA
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: SG
  alias Letflow.Support.SyncScopeFixture, as: Sync
  alias Letflow.Support.TenantAdminMigrationFixture, as: Mig

  @identity Letflow.Routers.Identity
  @enforcement Letflow.Routers.TenantScopeEnforcement

  setup do
    LIA.purge_stale!()
    :ok
  end

  # ===========================================================================================
  describe "T-LA-P7 adding a member (the recovery move) and the transition rule at zero" do
    test "in an on tenant at ZERO interactive admins add_group_member succeeds and restores the count" do
      fx = LIA.on_tenant!("p7") |> LIA.at_zero!()
      newcomer = RSG.user!(fx.schema_name)

      assert {:ok, _member} = Identity.add_group_member(fx.ta_group_id, newcomer.id, LIA.opts(fx))

      assert LIA.interactive(fx) == 1
      assert LIA.refusals(fx) == []
    end

    test "at zero, unrelated writes are NOT refused either (transition rule, not state rule): deactivating a stranger, removing a non-admin membership" do
      fx = LIA.on_tenant!("p7b") |> LIA.at_zero!()
      stranger = RSG.user!(fx.schema_name)
      other = RSG.fresh_group!(fx.schema_name)
      _member = RSG.member!(fx.schema_name, other.id, stranger)

      assert :ok = Identity.remove_group_member(other.id, stranger.id, LIA.opts(fx))

      assert {:ok, %User{status: :inactive}} =
               Identity.update_user_status(
                 stranger.id,
                 :inactive,
                 LIA.opts(fx) ++ [login_directory: :skip]
               )

      assert LIA.interactive(fx) == 0
      assert LIA.refusals(fx) == []
    end

    test "with admins present an add changes no other member and never lowers the count" do
      fx = LIA.on_tenant!("p7c")
      newcomer = RSG.user!(fx.schema_name)

      assert {:ok, _member} = Identity.add_group_member(fx.ta_group_id, newcomer.id, LIA.opts(fx))

      assert LIA.member?(fx, fx.ta_group_id, fx.admin.id)
      assert LIA.interactive(fx) == 2
    end
  end

  describe "T-LA-P8 delete_group" do
    test "a memberless group is deleted and the count is unchanged; the populated admin group is refused" do
      fx = LIA.on_tenant!("p8")
      empty = RSG.fresh_group!(fx.schema_name)

      assert :ok = Identity.delete_group(empty.id, prefix: fx.schema_name)
      assert LIA.interactive(fx) == 1

      # the admin group has a member: refused, nothing deleted
      assert {:error, :not_found_or_has_members} =
               Identity.delete_group(fx.ta_group_id, prefix: fx.schema_name)

      assert LIA.interactive(fx) == 1
      assert LIA.member?(fx, fx.ta_group_id, fx.admin.id)

      # a memberless group bound to a role cannot be deleted either
      bound = RSG.fresh_group!(fx.schema_name)

      assert {:ok, _role} =
               RoleRegistry.upsert_role(
                 "AGENT_RUNNER",
                 :process_routing_role,
                 bound.id,
                 LIA.opts(fx)
               )

      assert {:error, :bound_to_role} = Identity.delete_group(bound.id, prefix: fx.schema_name)
      assert LIA.interactive(fx) == 1
    end
  end

  describe "T-LA-P9 role-claim sync" do
    test "a sync whose claims no longer include the admin role removes nothing: A1 stays a member, the count is unchanged" do
      fx = LIA.on_tenant!("p9")

      assert {:ok, _user} = Sync.sync(fx.schema_name, fx.admin, [])

      assert LIA.member?(fx, fx.ta_group_id, fx.admin.id)
      assert LIA.interactive(fx) == 1
    end

    test "a sync that claims the admin role for a newcomer never lowers the count" do
      fx = LIA.on_tenant!("p9b")
      newcomer = RSG.user!(fx.schema_name)
      before = LIA.interactive(fx)

      _result = Sync.sync(fx.schema_name, newcomer, ["TENANT_ADMIN"])

      assert LIA.interactive(fx) >= before
    end
  end

  describe "T-LA-P10 tokens are never in the interactive count" do
    test "P10a: mint_token for an admin leaves the count unchanged" do
      fx = LIA.on_tenant!("p10a")
      issuer = LIA.add_admin!(fx)
      before = LIA.interactive(fx)
      assert before == 2

      assert {:ok, %{token: _token}} =
               Identity.mint_token(
                 issuer.id,
                 fx.admin.id,
                 %{roles: ["TENANT_ADMIN"], expires_at: nil},
                 LIA.opts(fx)
               )

      assert LIA.interactive(fx) == before
    end

    test "P10b: create_token for A1 leaves the count unchanged" do
      fx = LIA.on_tenant!("p10b")
      before = LIA.interactive(fx)

      assert {:ok, %{token: _token}} =
               Identity.create_token(fx.admin.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
                 prefix: fx.schema_name
               )

      assert LIA.interactive(fx) == before
    end
  end

  describe "T-LA-P11 scoping and make-tenant-wide" do
    test "P11a create (scoping) never lowers the count in four shapes, including a member of the admin group scoped while the group holds the tenant-wide row" do
      fx = LIA.on_tenant!("p11a")
      node = RSG.node!(fx.schema_name)
      actor = LIA.actor(fx)

      attrs = fn type, id ->
        %{principal_type: type, principal_id: id, role: "TENANT_ADMIN", scope_node_id: node}
      end

      # (4) A1 is a member of the admin group which holds the tenant-wide row; a scoped
      # TENANT_ADMIN row for HIM must not take him out of the interactive count
      before = LIA.interactive(fx)
      assert before == 1
      _result = ScopedGrants.create(attrs.(:user, fx.admin.id), actor, fx.schema_name)
      assert LIA.interactive(fx) == before
      assert LIA.member?(fx, fx.ta_group_id, fx.admin.id)

      # (2) a user without any row
      plain = RSG.user!(fx.schema_name)
      _result = ScopedGrants.create(attrs.(:user, plain.id), actor, fx.schema_name)
      assert LIA.interactive(fx) == before

      # (3) a group with no rows
      group = RSG.fresh_group!(fx.schema_name)
      _result = ScopedGrants.create(attrs.(:group, group.id), actor, fx.schema_name)
      assert LIA.interactive(fx) == before
    end

    test "P11a (1): a principal that already holds a tenant-wide row is refused tenant_wide_row_exists and the count is unchanged" do
      fx = LIA.on_tenant!("p11a1")
      _row_id = LIA.userize_admin_row!(fx)
      node = RSG.node!(fx.schema_name)
      before = LIA.interactive(fx)

      assert {:error, :tenant_wide_row_exists} =
               ScopedGrants.create(
                 %{
                   principal_type: :user,
                   principal_id: fx.admin.id,
                   role: "TENANT_ADMIN",
                   scope_node_id: node
                 },
                 LIA.actor(fx),
                 fx.schema_name
               )

      assert LIA.interactive(fx) == before
    end

    test "P11b make_tenant_wide never lowers the count" do
      fx = LIA.on_tenant!("p11b")
      node = RSG.node!(fx.schema_name)
      plain = RSG.user!(fx.schema_name)
      before = LIA.interactive(fx)

      assert {:ok, _row} =
               ScopedGrants.create(
                 %{
                   principal_type: :user,
                   principal_id: plain.id,
                   role: "TENANT_ADMIN",
                   scope_node_id: node
                 },
                 LIA.actor(fx),
                 fx.schema_name
               )

      _result =
        ScopedGrants.make_tenant_wide(
          %{principal_type: :user, principal_id: plain.id, role: "TENANT_ADMIN"},
          LIA.actor(fx),
          fx.schema_name
        )

      assert LIA.interactive(fx) >= before
    end
  end

  describe "T-LA-P12 to P14 revoking a token, revoking and binding a pending grant" do
    test "P12: revoking T1's token is allowed and the interactive count is unchanged" do
      fx = LIA.on_tenant!("p12")

      assert {:ok, _token} = Identity.revoke_token(fx.t1_token.id, LIA.opts(fx))

      assert LIA.interactive(fx) == 1
      assert LIA.refusals(fx) == []
    end

    test "P13: revoking the last PENDING grant while A1 exists is allowed and the count is unchanged" do
      w = H.world!()
      fx = LIA.decorate!(w.tenant, :on)
      grant = H.create_grant!(w, "pending.p13@example.com")

      assert :ok = PendingAdminGrants.revoke(grant.id, %{user_id: w.operator_id}, write_opts(w))

      assert LIA.interactive(fx) == 1
    end

    test "P14: bind_on_login for a pending grant in an on tenant at zero interactive admins restores one" do
      w = H.world!()
      fx = LIA.decorate!(w.tenant, :on) |> LIA.at_zero!()
      _grant = H.create_grant!(w, "pending.p14@example.com")

      assert %{result: :bound} = H.login(w, email: "pending.p14@example.com", verified: true)

      assert LIA.interactive(fx) == 1
    end
  end

  describe "T-LA-P15 to P17 platform-role seeding, TenantAdminMigration and Backfill in an on tenant" do
    test "P15: seeding in on removes no admin and leaves the count unchanged" do
      fx = LIA.on_tenant!("p15")

      assert {:ok, _roles} =
               RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)

      assert LIA.interactive(fx) == 1
      assert LIA.member?(fx, fx.ta_group_id, fx.admin.id)
    end

    test "P16: TenantAdminMigration skips the on tenant (skipped_enforced) and the count is unchanged" do
      p = Mig.operator_tenant!()
      a = Mig.tenant!("gh2869-p16")
      fx = LIA.decorate!(a, :on)

      assert {:ok, report} = Migration.run(Mig.good_opts(p))

      assert [rep] = Enum.filter(report.migrated, &(&1.tenant_id == fx.tenant_id))
      assert rep.rows == :skipped_enforced
      assert LIA.interactive(fx) == 1
      assert LIA.member?(fx, fx.ta_group_id, fx.admin.id)
    end

    test "P17: Backfill.run_tenant skips the on tenant (skipped_enforced) and the count is unchanged" do
      fx = LIA.on_tenant!("p17")

      assert {:ok, %{skipped_enforced: true, group_rows_inserted: 0}} =
               Backfill.run_tenant(fx.schema_name, [])

      assert LIA.interactive(fx) == 1
    end
  end

  defp write_opts(w) do
    [
      prefix: w.tenant.schema_name,
      platform_prefix: w.platform.schema_name,
      trace_id: LIA.trace(),
      onboarding_id: nil
    ]
  end

  # ===========================================================================================
  describe "T-LA-17 divergence: the gate's fact 4 and the guard's before-count are one function" do
    test "equal for every shape of the matrix, and equal to the expected count" do
      fx = LIA.tenant_in_mode!("l17", :off)
      s = fx.schema_name

      # 1. one explicit member (+ T1 token owner, who is in neither count)
      assert_same!(fx, 1)

      # 2. two explicit members
      a2 = LIA.add_admin!(fx)
      assert_same!(fx, 2)

      # 3. a flagged service principal does not count
      s1 = LIA.add_flagged_member!(fx)
      assert_same!(fx, 2)

      # 4. an inactive member does not count
      :ok = F.set_status!(s, a2.id, :inactive)
      assert_same!(fx, 1)

      # 5. a token owner only: no membership left
      :ok = F.remove_memberships!(s, fx.admin.id)
      assert_same!(fx, 0)

      # 6. a zero-row member (the group rows are gone, nobody holds a user row)
      assert RSG.raw_delete_rows!(s, fx.ta_group_id, "TENANT_ADMIN") >= 1
      z1 = LIA.add_admin!(fx)
      assert LIA.counted(fx) >= 2
      assert_same!(fx, 0)

      # 7. a scoped-only holder (a scoped user row, no tenant-wide row) does not count
      node = RSG.node!(s)
      :ok = RSG.raw_user_row!(s, z1.id, "TENANT_ADMIN", node)
      assert_same!(fx, 0)

      # 8. a tenant-wide user row of an active member counts again
      :ok = RSG.raw_user_row!(s, s1.id, "TENANT_ADMIN", nil)
      assert_same!(fx, 0)
      :ok = RSG.raw_user_row!(s, z1.id, "TENANT_ADMIN", nil)
      assert_same!(fx, 1)
    end
  end

  # The gate's input (OnGate.evaluate's explicit_tenant_wide_admins) and the guard's before-count
  # (TenantAdminGuard.count_before!/2 with :interactive_explicit, inside a transaction) are equal
  # to each other and to `expected`.
  defp assert_same!(fx, expected) do
    {report, _failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, DateTime.utc_now())

    assert {:ok, guard_count} =
             Repo.transaction(fn ->
               TenantAdminGuard.count_before!(fx.schema_name, :interactive_explicit)
             end)

    assert report.explicit_tenant_wide_admins == guard_count
    assert guard_count == expected
  end

  # ===========================================================================================
  describe "T-LA-29 recovery of an on tenant at zero interactive admins" do
    test "a TENANT_ADMIN token adds a member (restores the count), cannot flip the flag (403), and the break-glass flips it down" do
      fx = LIA.on_tenant!("l29") |> LIA.at_zero!()
      newcomer = RSG.user!(fx.schema_name)
      token_ctx = SG.ctx(fx, fx.t1.id, ["TENANT_ADMIN"], :api_token)

      flip =
        SG.call(@enforcement, :put, "/", fx, token_ctx, %{
          "mode" => "shadow",
          "reason" => "gh2869 token cannot flip"
        })

      assert flip.status == 403, flip.resp_body
      assert EW.stored_mode(fx) == "on"

      add =
        SG.call(@identity, :post, "/groups/#{fx.ta_group_id}/members", fx, token_ctx, %{
          "user_id" => newcomer.id
        })

      assert add.status in [200, 201], add.resp_body
      assert LIA.interactive(fx) == 1

      # the break-glass is the recovery for the flag; it is untouched by the guard
      assert {:ok, %{mode: :shadow}} =
               ScopeEnforcement.flip_out_of_band(fx.tenant_id, :shadow, %{
                 operator: "ops.handle-2869",
                 reason: "gh2869 recovery drill"
               })

      assert EW.stored_mode(fx) == "shadow"
    end
  end
end
