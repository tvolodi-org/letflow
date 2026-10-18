# Letflow.Repo.Migrations.AddScopeNodeIdToTasks
#
# REQ-518 / GH #2535 PR 2d (AC 12; design lib/letflow/design/req518-compiler-scope-filter.md
# C.1, decision 0051 D9): a nullable `tasks.scope_node_id`, the scope node a task belongs to
# for the approver rule F1. NO production code writes it (tasks carry no scope node until W3b);
# a NULL node is visible only to tenant-wide principals. The only writer is the test-support
# helper `Letflow.Support.TaskScopeFixture`.
#
# VERSION: the design names 20261019100001, which GH #2659 (REQ-505 PR-1) took first; Ecto
# versions must be unique, so this migration is 20261019200001.
#
# The foreign key `tasks_scope_node_id_fkey` (24 bytes, under Postgres's 63-byte NAMEDATALEN)
# references `scope_node_paths (node_id)` ON DELETE RESTRICT: a node a task names can never be
# deleted. A partial index serves the `scope_node_id IN (...)` predicate of the task list.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# No new table, so `@expected_tenant_tables` is unchanged.
#
# The only interpolation is the schema name from `prefix()` (INV-7). `down` is guarded by
# `to_regclass` because a replay may find no `tasks` table.
defmodule Letflow.Repo.Migrations.AddScopeNodeIdToTasks do
  use Ecto.Migration

  @spec up() :: any()
  def up do
    if prefix() do
      schema = prefix()

      execute(~s|ALTER TABLE "#{schema}".tasks ADD COLUMN scope_node_id text NULL|)

      execute("""
      ALTER TABLE "#{schema}".tasks
        ADD CONSTRAINT tasks_scope_node_id_fkey
        FOREIGN KEY (scope_node_id) REFERENCES "#{schema}".scope_node_paths (node_id)
        ON DELETE RESTRICT
      """)

      execute("""
      CREATE INDEX tasks_scope_node_id_idx ON "#{schema}".tasks (scope_node_id)
        WHERE scope_node_id IS NOT NULL
      """)
    end
  end

  @spec down() :: any()
  def down do
    if prefix() do
      schema = prefix()

      execute(~s|DROP INDEX IF EXISTS "#{schema}".tasks_scope_node_id_idx|)

      execute("""
      DO $$
      BEGIN
        IF to_regclass('"#{schema}".tasks') IS NOT NULL THEN
          ALTER TABLE "#{schema}".tasks DROP CONSTRAINT IF EXISTS tasks_scope_node_id_fkey;
          ALTER TABLE "#{schema}".tasks DROP COLUMN IF EXISTS scope_node_id;
        END IF;
      END
      $$
      """)
    end
  end
end
