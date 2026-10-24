defmodule Letflow.Identity.ScopedApproversTest do
  @moduledoc """
  REQ-519 slice 2f-a (GH #2535), AC 10 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.5 and 8.3, tests
  T-P1..T-P7, SEC ruling S-4 "AC literal, active users only"; spec
  `test/specs/REQ-519-2f-a.md`): `Letflow.Identity.ScopedApprovers.count/1`.

  Definition under test (the literal AC 10 text):

    * HOLDER: an ACTIVE user who is a member of a group bound as a PLATFORM role to
      `TASK_WORKER`;
    * SCOPED_TW: a HOLDER with at least one scoped applicable `TASK_WORKER` row (a user row or a
      row of a group the user belongs to and that group binds `TASK_WORKER`) and NO tenant-wide
      applicable `TASK_WORKER` row;
    * ROUTED: a member of a group bound as a `:process_routing_role`;
    * `approvers` = SCOPED_TW and ROUTED (blocks the `on` flip, fact 5); `task_workers_not_approvers`
      = SCOPED_TW and not ROUTED (informational, never blocks).

  A holder with ZERO applicable rows is not scoped (it is denied outright and fact 1 counts its
  binding). Each test is a variation of one scoped, routed task worker, so a counted user turning
  into a not-counted one is attributable to exactly one change.

  `async: false`: real tenant schemas (the tenant fixture leaves the sandbox in `:auto` mode).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.ScopedApprovers
  alias Letflow.ScopeEnforcement.OnGate
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.SyncScopeFixture, as: S

  @none %{approvers: 0, task_workers_not_approvers: 0}

  defp fx!(slug_prefix), do: F.admin_tenant!(slug_prefix)

  describe "T-P1 a scoped, routed task worker is a scoped approver" do
    test "one approver, no informational worker" do
      fx = fx!("req519-p1")
      _w = F.scoped_task_worker!(fx.schema_name, true)

      assert ScopedApprovers.count(fx.schema_name) == %{
               approvers: 1,
               task_workers_not_approvers: 0
             }
    end

    test "a scoped USER-principal row alone (the group has no row) is enough" do
      fx = fx!("req519-p1b")
      schema = fx.schema_name
      node = RSG.node!(schema)
      group = S.platform_group!(schema, "TASK_WORKER", [])
      user = RSG.member!(schema, group.id, RSG.user!(schema))
      :ok = RSG.raw_user_row!(schema, user.id, "TASK_WORKER", node)
      _routing = F.route!(schema, user)

      assert ScopedApprovers.count(schema) == %{approvers: 1, task_workers_not_approvers: 0}
    end

    test "two routing groups still count the user ONCE" do
      fx = fx!("req519-p1c")
      w = F.scoped_task_worker!(fx.schema_name, true)
      _second = F.route!(fx.schema_name, w.user)

      assert ScopedApprovers.count(fx.schema_name) == %{
               approvers: 1,
               task_workers_not_approvers: 0
             }
    end

    test "two scoped workers, one routed and one not, are counted separately" do
      fx = fx!("req519-p1d")
      schema = fx.schema_name
      node = RSG.node!(schema)
      group = S.platform_group!(schema, "TASK_WORKER", [{:node, node}])

      routed = RSG.member!(schema, group.id, RSG.user!(schema))
      _routing = F.route!(schema, routed)
      _plain = RSG.member!(schema, group.id, RSG.user!(schema))

      assert ScopedApprovers.count(schema) == %{approvers: 1, task_workers_not_approvers: 1}
    end

    test "the gate reports the approver and does not refuse the flip (REQ-532, informational)" do
      fx = F.shadow_tenant!("req519-p1e")
      :ok = F.satisfy!(fx, fx.now)
      _w = F.scoped_task_worker!(fx.schema_name, true)

      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      assert failed == []
      assert report.scoped_approvers == 1
    end
  end

  describe "T-P2 a tenant-wide TASK_WORKER is not a scoped approver" do
    test "a tenant-wide USER row clears the count" do
      fx = fx!("req519-p2a")
      w = F.scoped_task_worker!(fx.schema_name, true)
      assert ScopedApprovers.count(fx.schema_name).approvers == 1

      :ok = RSG.raw_user_row!(fx.schema_name, w.user.id, "TASK_WORKER", nil)

      assert ScopedApprovers.count(fx.schema_name) == @none
    end

    test "a tenant-wide GROUP row alongside the scoped one clears the count" do
      fx = fx!("req519-p2b")
      w = F.scoped_task_worker!(fx.schema_name, true)

      :ok = RSG.raw_tenant_wide_row!(fx.schema_name, w.group.id, "TASK_WORKER")

      assert ScopedApprovers.count(fx.schema_name) == @none
    end
  end

  describe "T-P3 removing the scoped row clears the count" do
    test "the holder is then a zero-row holder and is not counted" do
      fx = fx!("req519-p3")
      w = F.scoped_task_worker!(fx.schema_name, true)
      assert ScopedApprovers.count(fx.schema_name).approvers == 1

      assert RSG.raw_delete_rows!(fx.schema_name, w.group.id, "TASK_WORKER") == 1

      assert ScopedApprovers.count(fx.schema_name) == @none
    end
  end

  describe "T-P4 / T-P5 the routing membership decides approver or informational" do
    test "removing the routing membership turns the approver into an informational worker" do
      fx = fx!("req519-p4")
      w = F.scoped_task_worker!(fx.schema_name, true)

      {1, _} =
        Repo.delete_all(
          from(m in GroupMember, where: m.user_id == ^w.user.id and m.group_id == ^w.routing.id),
          prefix: fx.schema_name
        )

      assert ScopedApprovers.count(fx.schema_name) == %{
               approvers: 0,
               task_workers_not_approvers: 1
             }
    end

    test "a scoped task worker in no routing group does not block and is counted informationally" do
      fx = F.shadow_tenant!("req519-p5")
      :ok = F.satisfy!(fx, fx.now)
      _w = F.scoped_task_worker!(fx.schema_name, false)

      assert ScopedApprovers.count(fx.schema_name) == %{
               approvers: 0,
               task_workers_not_approvers: 1
             }

      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      assert failed == []
      assert report.scoped_approvers == 0
      assert report.scoped_task_workers_without_task_scope == 1
    end
  end

  describe "T-P6 an inactive user is not counted (SEC S-4)" do
    test "inactive: zero; reactivated: counted again" do
      fx = fx!("req519-p6")
      w = F.scoped_task_worker!(fx.schema_name, true)

      :ok = F.set_status!(fx.schema_name, w.user.id, :inactive)
      assert ScopedApprovers.count(fx.schema_name) == @none

      :ok = F.set_status!(fx.schema_name, w.user.id, :active)

      assert ScopedApprovers.count(fx.schema_name) == %{
               approvers: 1,
               task_workers_not_approvers: 0
             }
    end
  end

  describe "T-P7 a zero-row TASK_WORKER holder is not a scoped approver" do
    test "a routed member of a TASK_WORKER binding with no row is not counted, fact 1 counts the binding" do
      fx = F.shadow_tenant!("req519-p7")
      :ok = F.satisfy!(fx, fx.now)
      schema = fx.schema_name
      group = S.platform_group!(schema, "TASK_WORKER", [])
      user = RSG.member!(schema, group.id, RSG.user!(schema))
      _routing = F.route!(schema, user)

      assert ScopedApprovers.count(schema) == @none

      {report, failed} = OnGate.evaluate(fx.tenant_id, schema, fx.now)
      assert failed == [:bindings_without_row]
      assert report.bindings_without_row == 1
      assert report.scoped_approvers == 0
    end
  end

  describe "who is not a holder, and which rows count" do
    test "a user with a scoped USER row who is in no TASK_WORKER group is not a holder" do
      fx = fx!("req519-ph1")
      schema = fx.schema_name
      node = RSG.node!(schema)
      user = RSG.user!(schema)
      :ok = RSG.raw_user_row!(schema, user.id, "TASK_WORKER", node)
      _routing = F.route!(schema, user)

      assert ScopedApprovers.count(schema) == @none
    end

    test "a TASK_WORKER binding of the ROUTING kind makes nobody a holder" do
      fx = fx!("req519-ph2")
      schema = fx.schema_name
      node = RSG.node!(schema)
      group = RSG.fresh_group!(schema)
      _binding = RSG.raw_binding!(schema, "TASK_WORKER", :process_routing_role, group.id)
      :ok = RSG.raw_scoped_row!(schema, group.id, "TASK_WORKER", node)
      user = RSG.member!(schema, group.id, RSG.user!(schema))
      # a scoped USER row too, so only the binding KIND stands between this user and the count
      :ok = RSG.raw_user_row!(schema, user.id, "TASK_WORKER", node)
      _routing = F.route!(schema, user)

      assert ScopedApprovers.count(schema) == @none
    end

    test "a scoped row of ANOTHER role does not make a tenant-wide TASK_WORKER scoped" do
      fx = fx!("req519-ph3")
      schema = fx.schema_name
      node = RSG.node!(schema)
      group = S.platform_group!(schema, "TASK_WORKER", [:tenant_wide])
      :ok = RSG.raw_scoped_row!(schema, group.id, "PROCESS_OPERATOR", node)
      user = RSG.member!(schema, group.id, RSG.user!(schema))
      _routing = F.route!(schema, user)

      assert ScopedApprovers.count(schema) == @none
    end

    test "a tenant-wide row of ANOTHER role (user row or group row) does not clear a scoped TASK_WORKER" do
      fx = fx!("req519-ph4")
      w = F.scoped_task_worker!(fx.schema_name, true)
      :ok = RSG.raw_user_row!(fx.schema_name, w.user.id, "PROCESS_OPERATOR", nil)
      :ok = RSG.raw_tenant_wide_row!(fx.schema_name, w.group.id, "PROCESS_OPERATOR")

      assert ScopedApprovers.count(fx.schema_name) == %{
               approvers: 1,
               task_workers_not_approvers: 0
             }
    end

    test "a scoped worker of ANOTHER tenant is not counted" do
      fx = fx!("req519-ph5a")
      other = fx!("req519-ph5b")
      _w = F.scoped_task_worker!(other.schema_name, true)

      assert ScopedApprovers.count(fx.schema_name) == @none
      assert ScopedApprovers.count(other.schema_name).approvers == 1
    end

    test "the count is a plain read: it writes no audit entry" do
      fx = fx!("req519-ph6")
      _w = F.scoped_task_worker!(fx.schema_name, true)
      before = Repo.aggregate(Letflow.Audit.Entry, :count, prefix: fx.schema_name)

      _ = ScopedApprovers.count(fx.schema_name)

      assert Repo.aggregate(Letflow.Audit.Entry, :count, prefix: fx.schema_name) == before
    end
  end
end
