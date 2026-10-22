defmodule Letflow.Identity.BindingWritersModesTest do
  @moduledoc """
  REQ-519 slice 2e-a (GH #2535), AC 1 and AC 5 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 3.3 to 3.6, tests
  T-B1..T-B14; spec `test/specs/REQ-519-2e-a.md`): every writer row of
  `Letflow.Identity.BindingWriters` is asserted in EACH of the stored modes `off`, `shadow` and
  `on`. In `off` and `shadow` a row behaves exactly as before (the stage-1 tests T-W1..T-W14 are
  untouched); in `on` it is REFUSED (409 `scope_required`), NO-ROW (the binding is written or kept
  without a tenant-wide row and the skip is reported) or UNCHANGED (removal and moves never
  widen). Registry order: W-a=T-B1, W-b=T-B2, W-b2=T-B3, W-c1=T-B4, W-c2=T-B5, W-c3=T-B6,
  W-d1=T-B7, W-d2=T-B8, W-e=T-B9, W-f1=T-B10, W-f2=T-B11, W-g1=T-B12, W-g2=T-B13, W-h=T-B14.

  Fixtures are built while the tenant is `off` (so the bindings have their rows, exactly as a
  tenant that later turned `on`), then the stored mode is set by a direct `UPDATE`
  (`Letflow.Support.ScopeEnforcementFixture`; no route can set `on` yet).

  `async: false`: real tenant schemas with committed writes and registration-wide sweeps.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Letflow.Support.EnforcedWritersFixture
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Identity
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.RoleScopeGrants.Backfill
  alias Letflow.Identity.TenantAdminMigration, as: Migration
  alias Letflow.Identity.TenantRole
  alias Letflow.Support.TenantAdminMigrationFixture, as: Mig

  defp upsert(s, name, kind, group_id),
    do: RoleRegistry.upsert_role_report(name, kind, group_id, prefix: s)

  defp rebind(s, role_id, group_id) do
    RoleRegistry.rebind_role_report(role_id, group_id, %{actor_id: nil, reason: "REQ-519 test"},
      prefix: s
    )
  end

  defp refused(s), do: entries(s, "binding.refused")

  defp mine(list, fixtures) do
    ids = Enum.map(fixtures, & &1.tenant_id)
    Enum.filter(list, fn %{tenant_id: id} -> id in ids end)
  end

  # ===========================================================================================
  describe "T-B1 W-a: upsert_role nil -> platform_role (REFUSED in on)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B1 #{mode}", %{mode: mode} do
        fx = tenant!("req519-b1-#{mode}", mode)
        s = fx.schema_name
        g = group!(fx)

        result = upsert(s, "PROCESS_DESIGNER", :platform_role, g.id)

        if mode == :on do
          assert result == {:error, :scope_required}
          assert binding(s, "PROCESS_DESIGNER") == nil
          assert rows(s) == []
          assert [refusal] = refused(s)
          assert refusal.after_state["case"] == "nil_to_platform"
        else
          assert {:ok, %TenantRole{kind: :platform_role}, :in_place} = result
          assert rows(s) == [tw(g.id, "PROCESS_DESIGNER")]
          assert refused(s) == []
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-B2 W-b: upsert_role kind change routing -> platform_role (REFUSED in on)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B2 #{mode}", %{mode: mode} do
        fx = tenant!("req519-b2-#{mode}", :off)
        s = fx.schema_name
        g = group!(fx)
        {:ok, _role, :in_place} = upsert(s, "TENANT_AUDITOR", :process_routing_role, g.id)
        assert rows(s) == []
        set_mode!(fx, mode)

        result = upsert(s, "TENANT_AUDITOR", :platform_role, g.id)

        if mode == :on do
          assert result == {:error, :scope_required}
          assert %TenantRole{kind: :process_routing_role} = binding(s, "TENANT_AUDITOR")
          assert rows(s) == []
          assert [refusal] = refused(s)
          assert refusal.after_state["case"] == "routing_to_platform"
          assert entries(s, "role_binding.kind_changed") == []
        else
          assert {:ok, %TenantRole{kind: :platform_role}, :in_place} = result
          assert rows(s) == [tw(g.id, "TENANT_AUDITOR")]
          assert refused(s) == []
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-B3 W-b2: upsert_role platform_role -> routing (UNCHANGED: removal never widens)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B3 #{mode}: the row goes with the binding in every mode", %{mode: mode} do
        fx = tenant!("req519-b3-#{mode}", :off)
        s = fx.schema_name
        g = group!(fx)
        {:ok, _role, :in_place} = upsert(s, "AGENT_RUNNER", :platform_role, g.id)
        assert rows(s) == [tw(g.id, "AGENT_RUNNER")]
        set_mode!(fx, mode)

        assert {:ok, %TenantRole{kind: :process_routing_role}, :in_place} =
                 upsert(s, "AGENT_RUNNER", :process_routing_role, g.id)

        assert rows(s) == []
        assert RoleScopeGrants.orphan_group_rows(s) == []
        assert refused(s) == []
      end

      @tag mode: mode

      test "T-B3 #{mode}: the N1 last-tenant-admin guard still runs on the removal", %{mode: mode} do
        fx = seeded_tenant!("req519-b3n-#{mode}", mode)
        s = fx.schema_name
        ta_group = group_of!(s, "TENANT_ADMIN")
        _admin = member!(s, ta_group, user!(s))
        rows_before = rows(s)

        assert {:error, :last_tenant_wide_admin} =
                 upsert(s, "TENANT_ADMIN", :process_routing_role, ta_group)

        assert %TenantRole{kind: :platform_role} = binding(s, "TENANT_ADMIN")
        assert rows(s) == rows_before
      end
    end
  end

  # ===========================================================================================
  describe "T-B4 W-c1: upsert_role unchanged-branch repair (NO-ROW in on)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B4 #{mode}: a binding with no row", %{mode: mode} do
        fx = seeded_tenant!("req519-b4-#{mode}", :off)
        s = fx.schema_name
        g = group_of!(s, "PROCESS_DESIGNER")
        assert raw_delete_rows!(s, g, "PROCESS_DESIGNER") == 1
        set_mode!(fx, mode)

        result = upsert(s, "PROCESS_DESIGNER", :platform_role, g)

        if mode == :on do
          assert {:ok, %TenantRole{}, :skipped_enforced} = result
          refute tw(g, "PROCESS_DESIGNER") in rows(s)
          assert RoleScopeGrants.bindings_without_row_count(s) == 1
        else
          assert {:ok, %TenantRole{}, :in_place} = result
          assert tw(g, "PROCESS_DESIGNER") in rows(s)
          assert RoleScopeGrants.bindings_without_row_count(s) == 0
        end
      end
    end

    test "T-B4 on: a binding that HAS its row is :in_place and its rows are untouched" do
      fx = seeded_tenant!("req519-b4-row", :on)
      s = fx.schema_name
      g = group_of!(s, "PROCESS_DESIGNER")
      rows_before = rows(s)

      assert {:ok, %TenantRole{}, :in_place} = upsert(s, "PROCESS_DESIGNER", :platform_role, g)
      assert rows(s) == rows_before
    end

    test "T-B4 on: a group holding only a SCOPED row for the role is :in_place (never widened)" do
      fx = seeded_tenant!("req519-b4-scoped", :off)
      s = fx.schema_name
      g = group_of!(s, "PROCESS_DESIGNER")
      node = make_group_scoped_only!(s, g, "PROCESS_DESIGNER")
      set_mode!(fx, :on)

      assert {:ok, %TenantRole{}, :in_place} = upsert(s, "PROCESS_DESIGNER", :platform_role, g)
      assert Enum.filter(rows(s), &(elem(&1, 1) == g)) == [scoped(g, "PROCESS_DESIGNER", node)]
    end
  end

  # ===========================================================================================
  describe "T-B5 W-c2: platform-role seeding repair (NO-ROW in on)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B5 #{mode}", %{mode: mode} do
        fx = seeded_tenant!("req519-b5-#{mode}", :off)
        s = fx.schema_name
        g = group_of!(s, "TASK_WORKER")
        assert raw_delete_rows!(s, g, "TASK_WORKER") == 1
        set_mode!(fx, mode)

        assert {:ok, %{roles: roles, skipped_enforced: skipped}} =
                 RoleRegistry.seed_default_platform_role_groups_report(prefix: s)

        assert length(roles) == length(RoleRegistry.seedable_role_names(s))

        if mode == :on do
          assert skipped == ["TASK_WORKER"]
          refute tw(g, "TASK_WORKER") in rows(s)
          assert RoleScopeGrants.bindings_without_row_count(s) == 1
        else
          assert skipped == []
          assert tw(g, "TASK_WORKER") in rows(s)
          assert_t9_zero!(s)
        end

        # The public shape is unchanged in every mode.
        assert {:ok, [%TenantRole{} | _]} =
                 RoleRegistry.seed_default_platform_role_groups(prefix: s)
      end
    end
  end

  # ===========================================================================================
  describe "T-B6 W-c3: TenantAdminMigration TENANT_ADMIN repair (NO-ROW in on: the tenant is skipped)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B6 #{mode}", %{mode: mode} do
        p = Mig.operator_tenant!()
        a = Mig.tenant!("req519-b6-#{mode}")
        s = a.schema_name
        %{group: pa_group, users: [u1]} = Mig.legacy!(a, 1)
        :ok = raw_tenant_wide_row!(s, pa_group.id, "PLATFORM_ADMIN")
        ta_group = Mig.group!(s, "TENANT_ADMIN")
        raw_binding!(s, "TENANT_ADMIN", :platform_role, ta_group.id)
        assert RoleScopeGrants.bindings_without_row_count(s) == 1
        set_mode!(a, mode)

        assert {:ok, report} = Migration.run(Mig.good_opts(p))
        assert [rep] = mine(report.migrated, [a])

        if mode == :on do
          assert rep.rows == :skipped_enforced
          assert rep.members_copied == 0
          refute rep.platform_admin_binding_removed
          assert rows(s) == [tw(pa_group.id, "PLATFORM_ADMIN")]
          assert RoleScopeGrants.bindings_without_row_count(s) == 1
          assert binding(s, "PLATFORM_ADMIN") != nil

          refute Repo.exists?(
                   from(m in GroupMember,
                     where: m.user_id == ^u1.id and m.group_id == ^ta_group.id
                   ),
                   prefix: s
                 )
        else
          assert rep.rows == :written
          assert tw(ta_group.id, "TENANT_ADMIN") in rows(s)
          assert rows(s) == [tw(ta_group.id, "TENANT_ADMIN")]
          assert binding(s, "PLATFORM_ADMIN") == nil
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-B7 W-d1: rebind_role, rows move with the binding (UNCHANGED, asserted)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B7 #{mode}: a scoped row follows the binding and no tenant-wide row appears", %{
        mode: mode
      } do
        fx = tenant!("req519-b7-#{mode}", :off)
        s = fx.schema_name
        g = group!(fx)
        target = group!(fx)
        role = raw_binding!(s, "PROCESS_DESIGNER", :platform_role, g.id)
        node = make_group_scoped_only!(s, g.id, "PROCESS_DESIGNER")
        set_mode!(fx, mode)

        assert {:ok, %TenantRole{} = moved, :in_place} = rebind(s, role.id, target.id)
        assert moved.group_id == target.id
        assert rows(s) == [scoped(target.id, "PROCESS_DESIGNER", node)]
        assert tenant_wide_count(s) == 0
      end
    end
  end

  # ===========================================================================================
  describe "T-B8 W-d2: rebind_role, zero rows move (NO-ROW in on, no repair fallback)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B8 #{mode}", %{mode: mode} do
        fx = tenant!("req519-b8-#{mode}", :off)
        s = fx.schema_name
        g = group!(fx)
        target = group!(fx)
        role = raw_binding!(s, "PROCESS_DESIGNER", :platform_role, g.id)
        assert rows(s) == []
        set_mode!(fx, mode)

        result = rebind(s, role.id, target.id)

        if mode == :on do
          assert {:ok, %TenantRole{} = moved, :skipped_enforced} = result
          assert moved.group_id == target.id
          assert rows(s) == []
          assert RoleScopeGrants.bindings_without_row_count(s) == 1
        else
          assert {:ok, %TenantRole{}, :in_place} = result
          assert rows(s) == [tw(target.id, "PROCESS_DESIGNER")]
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-B9 W-e: Backfill.run (NO-ROW per tenant in on, reported as skipped_enforced)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B9 #{mode}", %{mode: mode} do
        fx = seeded_tenant!("req519-b9-#{mode}", :off)
        s = fx.schema_name
        Mig.isolate_registrations!(fx)
        g = group_of!(s, "TENANT_AUDITOR")
        assert raw_delete_rows!(s, g, "TENANT_AUDITOR") == 1
        set_mode!(fx, mode)
        rows_before = rows(s)

        assert {:ok, report} = Backfill.run([])

        if mode == :on do
          assert [tenant] = mine(report.tenants, [fx])

          assert tenant.skipped_enforced == true
          assert tenant.group_rows_inserted == 0
          assert tenant.bindings_without_row_after == 1
          assert report.skipped_enforced_tenants == [fx.tenant_id]
          assert report.inserted_total == 0
          assert rows(s) == rows_before
          assert entries(s, "scope.backfill_completed") == []
        else
          assert [%{skipped_enforced: false, group_rows_inserted: 1}] = mine(report.tenants, [fx])
          assert report.skipped_enforced_tenants == []
          assert report.inserted_total == 1
          assert_t9_zero!(s)
          assert [_one] = entries(s, "scope.backfill_completed")
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-B10 W-f1: P -> nil removal (UNCHANGED: removal never widens)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B10 #{mode}: reconcile_non_widening!(P, nil) removes the group rows in every mode",
           %{
             mode: mode
           } do
        fx = tenant!("req519-b10-#{mode}", :off)
        s = fx.schema_name
        g = group!(fx)
        pa = raw_binding!(s, "PLATFORM_ADMIN", :platform_role, g.id)
        :ok = raw_tenant_wide_row!(s, g.id, "PLATFORM_ADMIN")
        set_mode!(fx, mode)

        assert {:ok, :ok} =
                 Repo.transaction(fn -> RoleScopeGrants.reconcile_non_widening!(pa, nil, s) end,
                   prefix: s
                 )

        assert rows(s) == []
      end
    end
  end

  # ===========================================================================================
  describe "T-B11 W-f2: delete_group removes the group's principal rows (UNCHANGED)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B11 #{mode}", %{mode: mode} do
        fx = tenant!("req519-b11-#{mode}", :off)
        s = fx.schema_name
        g = group!(fx)
        :ok = raw_tenant_wide_row!(s, g.id, "PROCESS_DESIGNER")
        set_mode!(fx, mode)

        assert Identity.delete_group(g.id, prefix: s) == :ok
        assert rows(s) == []
      end
    end
  end

  # ===========================================================================================
  describe "T-B12 W-g1: platform-role seeding nil branch (NO-ROW in on, sweep unaffected)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B12 #{mode}", %{mode: mode} do
        fx = tenant!("req519-b12-#{mode}", mode)
        s = fx.schema_name
        names = RoleRegistry.seedable_role_names(s)

        assert {:ok, %{roles: roles, skipped_enforced: skipped}} =
                 RoleRegistry.seed_default_platform_role_groups_report(prefix: s)

        assert length(roles) == length(names)
        assert Enum.all?(roles, &(&1.kind == :platform_role))

        if mode == :on do
          assert Enum.sort(skipped) == Enum.sort(names)
          assert rows(s) == []
          assert RoleScopeGrants.bindings_without_row_count(s) == length(names)
          assert entries(s, "binding.refused") == []
        else
          assert skipped == []
          assert length(rows(s)) == length(names)
          assert_t9_zero!(s)
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-B13 W-g2: TenantAdminMigration nil branch (the tenant is skipped in on)" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B13 #{mode}", %{mode: mode} do
        p = Mig.operator_tenant!()
        a = Mig.tenant!("req519-b13-#{mode}")
        s = a.schema_name
        %{users: [u1, u2]} = Mig.legacy!(a, 2)
        set_mode!(a, mode)

        assert {:ok, report} = Migration.run(Mig.good_opts(p))
        assert [rep] = mine(report.migrated, [a])
        ta = binding(s, "TENANT_ADMIN")

        if mode == :on do
          assert rep.rows == :skipped_enforced
          assert rep.tenant_admin_binding_created == false
          assert ta == nil
          assert rows(s) == []
          assert binding(s, "PLATFORM_ADMIN") != nil
        else
          assert rep.rows == :written
          assert rep.tenant_admin_binding_created == true
          assert %TenantRole{} = ta
          assert rows(s) == [tw(ta.group_id, "TENANT_ADMIN")]

          assert Repo.all(
                   from(m in GroupMember, where: m.group_id == ^ta.group_id, select: m.user_id),
                   prefix: s
                 )
                 |> Enum.sort() == Enum.sort([u1.id, u2.id])
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-B14 W-h: POST /roles over HTTP" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "T-B14 #{mode}: new platform binding", %{mode: mode} do
        fx = tenant!("req519-b14-#{mode}", mode)
        s = fx.schema_name
        g = group!(fx)

        conn =
          http(:post, "/roles", fx, %{
            "name" => "PROCESS_DESIGNER",
            "kind" => "platform_role",
            "group_id" => g.id
          })

        if mode == :on do
          assert conn.status == 409, conn.resp_body
          assert body(conn)["detail"] == "scope_required"
          assert binding(s, "PROCESS_DESIGNER") == nil
          assert rows(s) == []
        else
          assert conn.status == 200, conn.resp_body
          refute Map.has_key?(body(conn), "grant_rows")
          assert rows(s) == [tw(g.id, "PROCESS_DESIGNER")]
        end
      end

      @tag mode: mode

      test "T-B14 #{mode}: routing -> platform kind change", %{mode: mode} do
        fx = tenant!("req519-b14r-#{mode}", :off)
        s = fx.schema_name
        g = group!(fx)
        {:ok, _role, _rows} = upsert(s, "PROCESS_DESIGNER", :process_routing_role, g.id)
        set_mode!(fx, mode)

        conn =
          http(:post, "/roles", fx, %{
            "name" => "PROCESS_DESIGNER",
            "kind" => "platform_role",
            "group_id" => g.id
          })

        if mode == :on do
          assert conn.status == 409, conn.resp_body
          assert body(conn)["detail"] == "scope_required"
          assert %TenantRole{kind: :process_routing_role} = binding(s, "PROCESS_DESIGNER")
          assert rows(s) == []
        else
          assert conn.status == 200, conn.resp_body
          assert rows(s) == [tw(g.id, "PROCESS_DESIGNER")]
        end
      end
    end
  end
end
