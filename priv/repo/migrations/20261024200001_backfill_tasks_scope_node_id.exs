# Letflow.Repo.Migrations.BackfillTasksScopeNodeId
#
# REQ-532 / GH #3091 (decision 0051 T13): a task carries the scope node of the instance it belongs
# to. The writer (`Letflow.Engine.TaskActivation.insert_task_row/4`) sets `tasks.scope_node_id` on
# every task it creates from now on; this migration gives the same value to the tasks that already
# exist.
#
# THE RULE: a task takes only its own instance's value (`instance_projections.scope_node_id`, joined
# on `instance_id`). Nothing is guessed. A task whose instance has no scope stays NULL, which is
# fail-closed: only tenant-wide holders see it.
#
# RE-RUNNABLE: the `WHERE tasks.scope_node_id IS NULL` predicate means a second run changes zero rows,
# and a task that already has a node is never changed.
#
# EXPECTED EFFECT: zero rows in every existing tenant. Before REQ-531 no instance carried a scope
# node, so no instance_projections row has one to copy. The count is logged so the QA deploy shows it.
#
# DOWN: a no-op. The copied values stay in place (they are the instance's own scope and are correct
# to keep). The column itself is dropped by the REQ-518 migration's `down`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix()` guard is MANDATORY, and so is this file's registration in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`. No new table.
#
# The statement is an Ecto query, not an interpolated SQL string (INV-7); the schema comes in through
# the `prefix:` option.
defmodule Letflow.Repo.Migrations.BackfillTasksScopeNodeId do
  use Ecto.Migration

  import Ecto.Query

  require Logger

  @spec up() :: any()
  def up do
    if prefix() do
      query =
        from(t in "tasks",
          join: ip in "instance_projections",
          on: ip.instance_id == t.instance_id,
          where: is_nil(t.scope_node_id) and not is_nil(ip.scope_node_id),
          update: [set: [scope_node_id: ip.scope_node_id]]
        )

      {count, _} = repo().update_all(query, [], prefix: prefix())

      Logger.info("tasks.scope_node_id backfill: #{count} row(s) changed in #{prefix()}")
    end
  end

  @spec down() :: any()
  def down do
    :ok
  end
end
