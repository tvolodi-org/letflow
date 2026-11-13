defmodule Letflow.Identity.ScopedApproversHoldersTest do
  @moduledoc """
  Roles stage 0, slice S0-2: `ScopedApprovers.count/1` asks the roles that hold
  `TasksWorkInScope` (today TASK_WORKER only) instead of the name. A scoped TENANT_ADMIN grant must
  not be counted (A1, refused branch); a scoped TASK_WORKER grant still is (A2, allowed branch).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.ScopedApprovers
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.SyncScopeFixture, as: S

  # The tenant fixture already binds TENANT_ADMIN to its admin's group: reuse it, add a scoped row.
  defp admin_group!(schema, node) do
    %{group_id: group_id} = RSG.binding(schema, "TENANT_ADMIN")
    group = Letflow.Repo.get!(Letflow.Identity.Group, group_id, prefix: schema)
    :ok = RSG.raw_scoped_row!(schema, group.id, "TENANT_ADMIN", node)
    group
  end

  # A routed user who is a member of the TENANT_ADMIN platform-role group and holds a scoped
  # TENANT_ADMIN user row.
  defp scoped_routed_admin!(schema) do
    node = RSG.node!(schema)
    group = admin_group!(schema, node)
    user = RSG.member!(schema, group.id, RSG.user!(schema))
    :ok = RSG.raw_user_row!(schema, user.id, "TENANT_ADMIN", node)
    _routing = F.route!(schema, user)
    user
  end

  test "A1 a scoped TENANT_ADMIN user is not counted next to a scoped TASK_WORKER" do
    fx = F.admin_tenant!("s02-a1")
    schema = fx.schema_name
    _w = F.scoped_task_worker!(schema, true)
    _admin = scoped_routed_admin!(schema)

    assert ScopedApprovers.count(schema) == %{approvers: 1, task_workers_not_approvers: 0}
  end

  test "A2 the TENANT_ADMIN user alone is not counted; once it also holds TASK_WORKER it is" do
    fx = F.admin_tenant!("s02-a2")
    schema = fx.schema_name
    admin = scoped_routed_admin!(schema)

    assert ScopedApprovers.count(schema) == %{approvers: 0, task_workers_not_approvers: 0}

    node = RSG.node!(schema)
    group = S.platform_group!(schema, "TASK_WORKER", [{:node, node}])
    _member = RSG.member!(schema, group.id, admin)

    assert ScopedApprovers.count(schema) == %{approvers: 1, task_workers_not_approvers: 0}
  end
end
