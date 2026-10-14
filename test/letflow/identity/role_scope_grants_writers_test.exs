defmodule Letflow.Identity.RoleScopeGrantsWritersTest do
  @moduledoc """
  REQ-497 / GH #2533 PR 1a, AC2: every binding writer creates, moves or removes the
  `role_scope_grants` group row in the SAME transaction as its binding write, and no membership
  writer creates a row (design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` sections 3 and 6.3,
  T-W1..T-W14; spec `test/specs/REQ-497-1a.md`).

  Rollback forms (design 6.3):

    * R1, forced rollback around the writer: `Repo.transaction(fn -> writer; assert binding AND
      row visible; Repo.rollback(:forced) end)`, then neither persists. Proves both writes are on
      the one transaction.
    * R2, injected failure of the grant write itself: a test-installed
      `BEFORE INSERT/UPDATE/DELETE ON role_scope_grants` trigger that raises (dedicated tenant,
      dropped by the test), after which the writer fails and the binding change did not happen.

  Every gap-free scenario ends with `assert_t9_zero!/1` (no binding without a row, no user row).

  `async: false`: real tenant schemas with committed writes and DDL (triggers); the sweeps
  (`RoleBackfill.run/0`, `TenantAdminMigration.run/1`) read every registration and the platform
  pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Identity
  alias Letflow.Identity.RoleBackfill
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantAdminMigration
  alias Letflow.Identity.TenantRole
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TenantAdminMigrationFixture, as: Mig
  alias Letflow.TenantFixture
  alias Letflow.TenantOnboarding
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # REQ-497 PR 1b: T-W8 R2 changed from assert_raise to the GH #2575 error tuple (spec
  # test/specs/REQ-497-1b.md, "Existing tests changed").

  # --- fixtures --------------------------------------------------------------------------------

  defp tenant!(slug_prefix), do: TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

  defp seeded_tenant!(slug_prefix) do
    fx = tenant!(slug_prefix)
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)
    fx
  end

  defp upsert(schema, name, kind, group_id),
    do: RoleRegistry.upsert_role(name, kind, group_id, prefix: schema)

  defp rebind(schema, role_id, group_id) do
    RoleRegistry.rebind_role(role_id, group_id, %{actor_id: nil, reason: "REQ-497 test move"},
      prefix: schema
    )
  end

  defp with_fault(schema, op, fun) do
    name = install_fault_trigger!(schema, op)

    try do
      fun.()
    after
      drop_fault_trigger!(schema, name)
    end
  end

  # One tenant-wide group row per :platform_role binding of the schema, nothing else.
  defp rows_match_bindings!(schema) do
    expected =
      Repo.all(from(t in TenantRole, where: t.kind == :platform_role), prefix: schema)
      |> Enum.map(&tw(&1.group_id, &1.name))
      |> Enum.sort()

    assert rows(schema) == expected
    expected
  end

  defp grant_ids(schema),
    do: Repo.all(from(g in RoleScopeGrant, select: g.id, order_by: g.id), prefix: schema)

  # A tenant in the `migrating` state exactly as `POST /onboarding` creates it (cleanup mirrors
  # test/letflow/identity/tenant_admin_seeding_test.exs).
  defp new_migrating_tenant! do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("req497-onb"),
          display_name: "REQ-497 onboarding tenant",
          status: "migrating"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    tenant
  end

  defp claims_context(roles) do
    sub = "sub-" <> Ecto.UUID.generate()

    %IdentityContext{
      external_user_id: sub,
      tenant_id: nil,
      realm: "req497-sync-realm",
      roles: roles,
      email: sub <> "@example.com",
      preferred_username: "user-" <> sub,
      display_name: "Display " <> sub,
      email_verified: true
    }
  end

  # ===========================================================================================
  describe "T-W1 / T-W2: upsert_role/4, new binding" do
    test "T-W1 a new :platform_role binding writes exactly one tenant-wide group row" do
      %{schema_name: s} = tenant!("req497-w1")
      g = fresh_group!(s)

      assert {:ok, %TenantRole{kind: :platform_role} = role} =
               upsert(s, "PROCESS_DESIGNER", :platform_role, g.id)

      assert rows(s) == [tw(g.id, "PROCESS_DESIGNER")]
      assert role.group_id == g.id
      assert_t9_zero!(s)
    end

    test "T-W1 R1: a forced rollback around the writer removes the binding AND the row" do
      %{schema_name: s} = tenant!("req497-w1-r1")
      g = fresh_group!(s)

      assert {:error, :forced} =
               Repo.transaction(fn ->
                 assert {:ok, _role} = upsert(s, "TASK_WORKER", :platform_role, g.id)
                 assert %TenantRole{} = binding(s, "TASK_WORKER")
                 assert rows(s) == [tw(g.id, "TASK_WORKER")]
                 Repo.rollback(:forced)
               end)

      assert binding(s, "TASK_WORKER") == nil
      assert rows(s) == []
    end

    test "T-W1 R2: a failing grant insert fails the writer and leaves no binding" do
      %{schema_name: s} = tenant!("req497-w1-r2")
      g = fresh_group!(s)

      with_fault(s, "INSERT", fn ->
        assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
                 upsert(s, "TASK_WORKER", :platform_role, g.id)
      end)

      assert binding(s, "TASK_WORKER") == nil
      assert rows(s) == []

      # Control: without the fault the same call succeeds.
      assert {:ok, _} = upsert(s, "TASK_WORKER", :platform_role, g.id)
      assert rows(s) == [tw(g.id, "TASK_WORKER")]
    end

    test "T-W2 a new :process_routing_role binding writes no row" do
      %{schema_name: s} = tenant!("req497-w2")
      g = fresh_group!(s)

      assert {:ok, %TenantRole{kind: :process_routing_role}} =
               upsert(s, "rsg-routing", :process_routing_role, g.id)

      assert rows(s) == []
      assert_t9_zero!(s)
    end
  end

  # ===========================================================================================
  describe "T-W3 / T-W4 / T-W5: upsert_role/4, existing binding" do
    test "T-W3 kind change routing -> platform inserts the row; R2 keeps the binding routing" do
      %{schema_name: s} = tenant!("req497-w3")
      g = fresh_group!(s)
      {:ok, _} = upsert(s, "TENANT_AUDITOR", :process_routing_role, g.id)
      assert rows(s) == []

      # R2 first: the conversion is refused whole.
      with_fault(s, "INSERT", fn ->
        assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
                 upsert(s, "TENANT_AUDITOR", :platform_role, g.id)
      end)

      assert %TenantRole{kind: :process_routing_role} = binding(s, "TENANT_AUDITOR")
      assert rows(s) == []

      assert {:ok, %TenantRole{kind: :platform_role}} =
               upsert(s, "TENANT_AUDITOR", :platform_role, g.id)

      assert rows(s) == [tw(g.id, "TENANT_AUDITOR")]
      assert_t9_zero!(s)
    end

    test "T-W4 kind change platform -> routing removes the row; R2 keeps the binding platform and its row" do
      %{schema_name: s} = tenant!("req497-w4")
      g = fresh_group!(s)
      {:ok, _} = upsert(s, "AGENT_RUNNER", :platform_role, g.id)
      assert rows(s) == [tw(g.id, "AGENT_RUNNER")]

      with_fault(s, "DELETE", fn ->
        assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
                 upsert(s, "AGENT_RUNNER", :process_routing_role, g.id)
      end)

      assert %TenantRole{kind: :platform_role} = binding(s, "AGENT_RUNNER")
      assert rows(s) == [tw(g.id, "AGENT_RUNNER")]

      assert {:ok, %TenantRole{kind: :process_routing_role}} =
               upsert(s, "AGENT_RUNNER", :process_routing_role, g.id)

      assert rows(s) == []
      assert RoleScopeGrants.orphan_group_rows(s) == []
      assert_t9_zero!(s)
    end

    test "T-W5 a repeated upsert keeps one row, re-creates a deleted one, and :role_already_bound writes none" do
      %{schema_name: s} = tenant!("req497-w5")
      g = fresh_group!(s)
      other = fresh_group!(s)
      {:ok, _} = upsert(s, "CANDIDATE", :platform_role, g.id)
      [first] = group_structs(s, g.id)

      assert {:ok, _} = upsert(s, "CANDIDATE", :platform_role, g.id)
      assert group_structs(s, g.id) == [first]

      # W2 (b): the repair re-creates a row deleted behind the writer's back.
      assert raw_delete_rows!(s, g.id, "CANDIDATE") == 1
      assert RoleScopeGrants.bindings_without_row_count(s) == 1
      assert {:ok, _} = upsert(s, "CANDIDATE", :platform_role, g.id)
      assert rows(s) == [tw(g.id, "CANDIDATE")]

      assert {:error, :role_already_bound} = upsert(s, "CANDIDATE", :platform_role, other.id)
      assert group_structs(s, other.id) == []
      assert rows(s) == [tw(g.id, "CANDIDATE")]
      assert_t9_zero!(s)
    end

    test "T-W5 W2 (b) never widens a group holding only a scoped row for the role (SEC B1)" do
      %{schema_name: s} = tenant!("req497-w5-scoped")
      g = fresh_group!(s)
      node = node!(s)
      # A binding written by a pre-release node, holding a stage-2 scoped row only.
      raw_binding!(s, "TENANT_ADMIN", :platform_role, g.id)
      raw_scoped_row!(s, g.id, "TENANT_ADMIN", node)

      assert {:ok, _} = upsert(s, "TENANT_ADMIN", :platform_role, g.id)
      assert rows(s) == [scoped(g.id, "TENANT_ADMIN", node)]
      assert_t9_zero!(s)
    end
  end

  # ===========================================================================================
  describe "T-W6: provisioning and seeding" do
    test "provision_and_migrate/1 ends with one row per seeded binding, T9 0 and 0 user rows; re-seeding converges" do
      Fixture.unpin!()
      tenant = new_migrating_tenant!()

      assert {:ok, %Registration{schema_name: s}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      expected = rows_match_bindings!(s)
      assert length(expected) == 7
      assert length(expected) == length(RoleRegistry.seedable_role_names(s))
      assert_t9_zero!(s)

      # A second seed keeps the same 7 rows (same ids).
      before_ids = grant_ids(s)
      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: s)
      assert grant_ids(s) == before_ids

      # W4 (b): a row deleted behind the seed's back is restored by the next seed.
      tw_group = group_of!(s, "TASK_WORKER")
      assert raw_delete_rows!(s, tw_group, "TASK_WORKER") == 1
      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: s)
      assert rows(s) == expected
      assert_t9_zero!(s)
    end

    test "R2: a failing grant insert fails the seed and the failing name has no binding" do
      Fixture.unpin!()
      %{schema_name: s} = tenant!("req497-w6-r2")
      [first_name | _] = RoleRegistry.seedable_role_names(s)

      with_fault(s, "INSERT", fn ->
        assert {:error, _reason} = RoleRegistry.seed_default_platform_role_groups(prefix: s)
      end)

      assert binding(s, first_name) == nil
      assert Repo.aggregate(TenantRole, :count, prefix: s) == 0
      assert rows(s) == []
    end
  end

  # ===========================================================================================
  describe "T-W7: RoleBackfill.run/0" do
    test "seeds missing bindings with their rows, and restores a row missing from an existing binding" do
      Fixture.unpin!()
      bare = tenant!("req497-w7-bare")
      Mig.isolate_registrations!(bare)
      gap = seeded_tenant!("req497-w7-gap")
      gap_group = group_of!(gap.schema_name, "PROCESS_OPERATOR")
      assert raw_delete_rows!(gap.schema_name, gap_group, "PROCESS_OPERATOR") == 1
      assert RoleScopeGrants.bindings_without_row_count(gap.schema_name) == 1

      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()
      assert bare.tenant_id in seeded

      for s <- [bare.schema_name, gap.schema_name] do
        assert length(rows_match_bindings!(s)) == 7
        assert_t9_zero!(s)
      end

      assert tw(gap_group, "PROCESS_OPERATOR") in rows(gap.schema_name)
    end
  end

  # ===========================================================================================
  describe "T-W8: rebind_role/4" do
    test "the row follows the binding to B; a same-group rebind writes nothing; a routing rebind leaves zero rows" do
      %{schema_name: s} = tenant!("req497-w8")
      a = fresh_group!(s)
      b = fresh_group!(s)
      {:ok, role} = upsert(s, "PROCESS_OPERATOR", :platform_role, a.id)

      assert {:ok, %TenantRole{group_id: moved_to}} = rebind(s, role.id, b.id)
      assert moved_to == b.id
      assert rows(s) == [tw(b.id, "PROCESS_OPERATOR")]
      assert group_structs(s, a.id) == []
      assert RoleScopeGrants.orphan_group_rows(s) == []
      assert_t9_zero!(s)

      # Same group: nothing written (row untouched, no role.rebound entry).
      [row_before] = group_structs(s, b.id)
      rebound_before = length(entries(s, "role.rebound"))
      assert {:ok, _} = rebind(s, role.id, b.id)
      assert group_structs(s, b.id) == [row_before]
      assert length(entries(s, "role.rebound")) == rebound_before

      # A routing binding: no row before, none after.
      {:ok, routing} = upsert(s, "rsg-route-w8", :process_routing_role, a.id)
      assert {:ok, _} = rebind(s, routing.id, b.id)
      assert rows(s) == [tw(b.id, "PROCESS_OPERATOR")]
      assert_t9_zero!(s)
    end

    test "R1: a forced rollback around the rebind leaves the binding and its row on A" do
      %{schema_name: s} = tenant!("req497-w8-r1")
      a = fresh_group!(s)
      b = fresh_group!(s)
      {:ok, role} = upsert(s, "PROCESS_OPERATOR", :platform_role, a.id)

      assert {:error, :forced} =
               Repo.transaction(fn ->
                 assert {:ok, _} = rebind(s, role.id, b.id)
                 assert binding(s, "PROCESS_OPERATOR").group_id == b.id
                 assert rows(s) == [tw(b.id, "PROCESS_OPERATOR")]
                 Repo.rollback(:forced)
               end)

      assert binding(s, "PROCESS_OPERATOR").group_id == a.id
      assert rows(s) == [tw(a.id, "PROCESS_OPERATOR")]
    end

    # REQ-497 PR 1b (GH #2575, design 1b 6.2 (c)): rebind_role/4 now rescues a raise inside its
    # transaction, so the injected fault comes back as an error tuple instead of a raise. The
    # intent (the failing grant write rolls the binding move back) is unchanged.
    test "R2: a failing grant update returns {:error, {:transaction_failed, %Postgrex.Error{}}} and leaves group_id and the row on A" do
      %{schema_name: s} = tenant!("req497-w8-r2")
      a = fresh_group!(s)
      b = fresh_group!(s)
      {:ok, role} = upsert(s, "PROCESS_OPERATOR", :platform_role, a.id)
      rebound_before = length(entries(s, "role.rebound"))

      with_fault(s, "UPDATE", fn ->
        assert {:error, {:transaction_failed, %Postgrex.Error{}}} = rebind(s, role.id, b.id)
      end)

      assert binding(s, "PROCESS_OPERATOR").group_id == a.id
      assert rows(s) == [tw(a.id, "PROCESS_OPERATOR")]
      assert length(entries(s, "role.rebound")) == rebound_before
    end
  end

  # ===========================================================================================
  describe "T-W9 / T-W14: TenantAdminMigration.run/1" do
    test "the TENANT_ADMIN row is created, the PLATFORM_ADMIN row removed, the member copy writes no user row" do
      p = Mig.operator_tenant!()
      a = Mig.tenant!("req497-w9")
      %{group: pa_group, users: [_u1, _u2]} = Mig.legacy!(a, 2)
      # The legacy binding as the migration backfilled it.
      raw_tenant_wide_row!(a.schema_name, pa_group.id, "PLATFORM_ADMIN")

      assert {:ok, report} = TenantAdminMigration.run(Mig.good_opts(p))

      assert [%{platform_admin_binding_removed: true, members_copied: 2}] =
               Enum.filter(report.migrated, &(&1.tenant_id == a.tenant_id))

      ta_group = group_of!(a.schema_name, "TENANT_ADMIN")
      assert rows(a.schema_name) == [tw(ta_group, "TENANT_ADMIN")]
      assert group_structs(a.schema_name, pa_group.id) == []
      assert RoleScopeGrants.orphan_group_rows(a.schema_name) == []
      # T-W14: the member copy wrote no user row.
      assert_t9_zero!(a.schema_name)
    end

    test "W5 (b): an existing TENANT_ADMIN binding without a row is repaired in the same run" do
      p = Mig.operator_tenant!()
      a = Mig.tenant!("req497-w9-ta")
      %{group: pa_group} = Mig.legacy!(a, 1)
      ta = fresh_group!(a.schema_name)
      raw_binding!(a.schema_name, "TENANT_ADMIN", :platform_role, ta.id)
      raw_tenant_wide_row!(a.schema_name, pa_group.id, "PLATFORM_ADMIN")

      assert {:ok, report} = TenantAdminMigration.run(Mig.good_opts(p))

      assert [%{tenant_admin_binding_created: false}] =
               Enum.filter(report.migrated, &(&1.tenant_id == a.tenant_id))

      assert rows(a.schema_name) == [tw(ta.id, "TENANT_ADMIN")]
      assert_t9_zero!(a.schema_name)
    end

    test "R2 (insert fault): the tenant is reported failed; no TENANT_ADMIN binding or row; PLATFORM_ADMIN binding and row intact" do
      p = Mig.operator_tenant!()
      f = Mig.tenant!("req497-w9-r2")
      %{group: pa_group} = Mig.legacy!(f, 1)
      raw_tenant_wide_row!(f.schema_name, pa_group.id, "PLATFORM_ADMIN")

      report =
        with_fault(f.schema_name, "INSERT", fn ->
          assert {:ok, report} = TenantAdminMigration.run(Mig.good_opts(p))
          report
        end)

      assert [_failure] = Enum.filter(report.failed, &(&1.tenant_id == f.tenant_id))
      assert binding(f.schema_name, "TENANT_ADMIN") == nil
      assert %TenantRole{kind: :platform_role} = binding(f.schema_name, "PLATFORM_ADMIN")
      assert rows(f.schema_name) == [tw(pa_group.id, "PLATFORM_ADMIN")]
    end

    test "R2 (delete fault): the legacy removal fails whole; PLATFORM_ADMIN binding and row intact, no TENANT_ADMIN binding" do
      p = Mig.operator_tenant!()
      f = Mig.tenant!("req497-w9-r2d")
      %{group: pa_group} = Mig.legacy!(f, 1)
      raw_tenant_wide_row!(f.schema_name, pa_group.id, "PLATFORM_ADMIN")

      report =
        with_fault(f.schema_name, "DELETE", fn ->
          assert {:ok, report} = TenantAdminMigration.run(Mig.good_opts(p))
          report
        end)

      assert [_failure] = Enum.filter(report.failed, &(&1.tenant_id == f.tenant_id))
      assert binding(f.schema_name, "TENANT_ADMIN") == nil
      assert %TenantRole{kind: :platform_role} = binding(f.schema_name, "PLATFORM_ADMIN")
      assert rows(f.schema_name) == [tw(pa_group.id, "PLATFORM_ADMIN")]
    end
  end

  # ===========================================================================================
  describe "T-W10: delete_group/2" do
    test "an unbound memberless group's orphan rows go with it; a bound group keeps its row" do
      %{schema_name: s} = tenant!("req497-w10")
      orphan_group = fresh_group!(s)
      raw_tenant_wide_row!(s, orphan_group.id, "TASK_WORKER")
      raw_scoped_row!(s, orphan_group.id, "CANDIDATE", node!(s))

      assert Identity.delete_group(orphan_group.id, prefix: s) == :ok
      assert group_structs(s, orphan_group.id) == []

      bound = fresh_group!(s)
      {:ok, _} = upsert(s, "CANDIDATE", :platform_role, bound.id)
      assert Identity.delete_group(bound.id, prefix: s) == {:error, :bound_to_role}
      assert rows(s) == [tw(bound.id, "CANDIDATE")]

      # A group with a member is not deleted, and neither are its rows.
      busy = fresh_group!(s)
      member!(s, busy.id, user!(s))
      raw_tenant_wide_row!(s, busy.id, "TASK_WORKER")
      assert Identity.delete_group(busy.id, prefix: s) == {:error, :not_found_or_has_members}
      assert group_structs(s, busy.id) |> length() == 1
    end
  end

  # ===========================================================================================
  describe "T-W11..T-W13: membership writers create no row" do
    test "T-W11 add_group_member/3 and remove_group_member/3 leave the row set identical" do
      %{schema_name: s} = seeded_tenant!("req497-w11")
      before = rows_match_bindings!(s)
      user = user!(s)
      group_id = group_of!(s, "TASK_WORKER")

      assert {:ok, %{created: true}} = Identity.add_group_member(group_id, user.id, prefix: s)
      assert rows(s) == before
      assert_t9_zero!(s)

      assert :ok = Identity.remove_group_member(group_id, user.id, prefix: s)
      assert rows(s) == before
      assert_t9_zero!(s)
    end

    test "T-W12 sync_role_claims_from_token/3 (first sync with claims) leaves the row set identical" do
      %{schema_name: s} = seeded_tenant!("req497-w12")
      before = rows_match_bindings!(s)
      user = user!(s)

      synced =
        Identity.sync_role_claims_from_token(
          user,
          claims_context(["TASK_WORKER", "PROCESS_DESIGNER"]),
          prefix: s
        )

      assert %DateTime{} = synced.role_claims_synced_at
      assert rows(s) == before
      assert_t9_zero!(s)
    end

    test "T-W13 PendingAdminGrants.bind_on_login/5 leaves the row set identical" do
      w = H.world!()
      s = w.tenant.schema_name
      before = rows_match_bindings!(s)
      _grant = H.create_grant!(w, "owner@example.com")

      assert %{result: :bound, provisioned: provisioned} =
               H.login(w, sub: "sub-req497-w13", email: "owner@example.com")

      assert "TENANT_ADMIN" in H.roles(w, provisioned.user.id)
      assert rows(s) == before
      assert_t9_zero!(s)
    end
  end
end
