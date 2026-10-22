defmodule Letflow.Identity.EnforcedWritersInvariantTest do
  @moduledoc """
  REQ-519 slice 2e-a (GH #2535), AC 5 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 3.3, tests T-I1 and T-I2;
  spec `test/specs/REQ-519-2e-a.md`): "in an `on` tenant no writer creates a tenant_wide row".

  T-I1 is a property test over the writer set: random sequences of operations in a tenant stored
  `on`, drawn from `upsert_role/4` (every kind, every group), `rebind_role/4`, the platform-role
  seeding, `Backfill.run_tenant/2`, `reconcile_widening!/3` and `reconcile_non_widening!/3`
  called directly with every `(before, after)` shape (each shape to the entry point its writer
  picks), and the two low-level inserters `ensure_tenant_wide_group_row!/3` and
  `repair_group_row!/3`, after each of which the number of `tenant_wide = true` rows must not
  have INCREASED. A `drop_rows` step deletes a binding's rows behind the writers' back so that
  the repair paths have a gap to be tempted by. The one sanctioned insert, the explicit
  make-tenant-wide act (`RoleScopeGrants.insert_tenant_wide/4`), is the control: the same
  measure DOES move for it, in `on`, so the property is not vacuous.

  T-I2: in `off` and `shadow` the stage-1 legacy writers still insert the row.

  `async: false`: committed writes in a real tenant schema.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  import Letflow.Support.EnforcedWritersFixture
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.RoleScopeGrants.Backfill
  alias Letflow.Identity.TenantRole

  @roles ["PROCESS_DESIGNER", "TASK_WORKER", "AGENT_RUNNER", "TENANT_AUDITOR"]
  @kinds [:platform_role, :process_routing_role]

  defp op_gen do
    role = member_of(@roles)
    kind = member_of(@kinds)
    group = member_of([0, 1, 2])
    maybe_kind = member_of([nil | @kinds])

    one_of([
      tuple({constant(:upsert), role, kind, group}),
      tuple({constant(:rebind), role, group}),
      constant({:seed}),
      constant({:backfill}),
      tuple({constant(:drop_rows), role}),
      tuple({constant(:reconcile), maybe_kind, maybe_kind, role, group, group}),
      tuple({constant(:ensure_row), group, role}),
      tuple({constant(:repair_row), group, role})
    ])
  end

  # Runs one operation; every error or raise is part of the exercise and is ignored (the
  # property is about the row count, not about success).
  defp run_op(op, s, groups) do
    do_op(op, s, groups)
  rescue
    _exception -> :raised
  end

  defp do_op({:upsert, role, kind, g}, s, groups),
    do: RoleRegistry.upsert_role_report(role, kind, Enum.at(groups, g), prefix: s)

  defp do_op({:rebind, role, g}, s, groups) do
    case binding(s, role) do
      nil ->
        :no_binding

      %TenantRole{id: id} ->
        RoleRegistry.rebind_role_report(
          id,
          Enum.at(groups, g),
          %{actor_id: nil, reason: "REQ-519 property"},
          prefix: s
        )
    end
  end

  defp do_op({:seed}, s, _groups),
    do: RoleRegistry.seed_default_platform_role_groups_report(prefix: s)

  defp do_op({:backfill}, s, _groups), do: Backfill.run_tenant(s, [])

  defp do_op({:drop_rows, role}, s, _groups) do
    case binding(s, role) do
      nil -> :no_binding
      %TenantRole{group_id: gid} -> raw_delete_rows!(s, gid, role)
    end
  end

  defp do_op({:reconcile, before_kind, after_kind, role, g1, g2}, s, groups) do
    before = shape(before_kind, role, Enum.at(groups, g1))
    after_ = shape(after_kind, role, Enum.at(groups, g2))

    Repo.transaction(fn ->
      # The entry point each binding writer picks (GH #2848): a creating write is the widening one.
      if platform_binding?(after_) and not platform_binding?(before) do
        RoleScopeGrants.reconcile_widening!(before, after_, s)
      else
        RoleScopeGrants.reconcile_non_widening!(before, after_, s)
      end
    end)
  end

  defp do_op({:ensure_row, g, role}, s, groups) do
    Repo.transaction(fn ->
      RoleScopeGrants.ensure_tenant_wide_group_row!(Enum.at(groups, g), role, s)
    end)
  end

  defp do_op({:repair_row, g, role}, s, groups) do
    Repo.transaction(fn -> RoleScopeGrants.repair_group_row!(Enum.at(groups, g), role, s) end)
  end

  defp platform_binding?(%TenantRole{kind: :platform_role}), do: true
  defp platform_binding?(_binding), do: false

  defp shape(nil, _role, _group), do: nil
  defp shape(kind, role, group), do: %TenantRole{name: role, kind: kind, group_id: group}

  defp groups!(fx), do: for(_ <- 1..3, do: group!(fx).id)

  # ===========================================================================================
  describe "T-I1 in an on tenant no writer increases the count of tenant_wide rows" do
    test "random sequences over the writer set never add a tenant-wide row" do
      fx = seeded_tenant!("req519-i1", :on)
      s = fx.schema_name
      groups = groups!(fx)

      check all(ops <- list_of(op_gen(), min_length: 1, max_length: 6), max_runs: 40) do
        for op <- ops do
          before = tenant_wide_count(s)
          _result = run_op(op, s, groups)
          after_count = tenant_wide_count(s)

          assert after_count <= before,
                 "#{inspect(op)} added a tenant-wide row in an on tenant (#{before} -> #{after_count})"
        end
      end

      assert stored_mode(fx) == "on"
    end

    test "control: the explicit make-tenant-wide insert DOES move the measure in an on tenant" do
      fx = seeded_tenant!("req519-i1c", :on)
      s = fx.schema_name
      user = user!(s)
      before = tenant_wide_count(s)

      assert {:ok, {:ok, _row}} =
               Repo.transaction(fn ->
                 RoleScopeGrants.insert_tenant_wide(:user, user.id, "TASK_WORKER", s)
               end)

      assert tenant_wide_count(s) == before + 1
    end

    test "control: each writer alone, on a gap, leaves the count unchanged in on" do
      fx = tenant!("req519-i1d", :off)
      s = fx.schema_name
      [g | _] = groups = groups!(fx)
      _role = raw_binding!(s, "TASK_WORKER", :platform_role, g)
      set_mode!(fx, :on)
      before = tenant_wide_count(s)

      for op <- [
            {:repair_row, 0, "TASK_WORKER"},
            {:ensure_row, 0, "TASK_WORKER"},
            {:reconcile, :platform_role, :platform_role, "TASK_WORKER", 0, 0},
            {:reconcile, nil, :platform_role, "TASK_WORKER", 0, 0},
            {:reconcile, :process_routing_role, :platform_role, "TASK_WORKER", 0, 0},
            {:reconcile, :platform_role, :platform_role, "TASK_WORKER", 0, 1},
            {:upsert, "TASK_WORKER", :platform_role, 0},
            {:seed},
            {:backfill}
          ] do
        _ = run_op(op, s, groups)
        assert tenant_wide_count(s) == before, inspect(op)
      end
    end
  end

  # ===========================================================================================
  describe "T-I2 in off and shadow a legacy writer still inserts the row" do
    for mode <- [:off, :shadow] do
      @tag mode: mode
      test "T-I2 #{mode}", %{mode: mode} do
        fx = tenant!("req519-i2-#{mode}", mode)
        s = fx.schema_name
        [g1, g2, g3] = groups!(fx)

        assert tenant_wide_count(s) == 0

        assert {:ok, :inserted} =
                 Repo.transaction(fn ->
                   RoleScopeGrants.ensure_tenant_wide_group_row!(g1, "TASK_WORKER", s)
                 end)

        assert tenant_wide_count(s) == 1

        assert {:ok, :inserted} =
                 Repo.transaction(fn ->
                   RoleScopeGrants.repair_group_row!(g2, "PROCESS_DESIGNER", s)
                 end)

        assert tenant_wide_count(s) == 2

        assert {:ok, %TenantRole{}, :in_place} =
                 RoleRegistry.upsert_role_report("AGENT_RUNNER", :platform_role, g3, prefix: s)

        assert tenant_wide_count(s) == 3
      end
    end
  end
end
