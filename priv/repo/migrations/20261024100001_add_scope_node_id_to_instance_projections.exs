# Letflow.Repo.Migrations.AddScopeNodeIdToInstanceProjections
#
# REQ-531 / GH #3092 (decision 0051 T13): a nullable `instance_projections.scope_node_id`, the scope
# node an instance is started under. It is set once, at instance creation (`Letflow.Engine.create/2`,
# or by inheritance from the parent for a sub-process child), and never changed: only
# `InstanceProjection.insert_changeset/2` casts it.
#
# EXISTING ROWS (QA is deployed from `main` by auto-CD): the column is nullable with no default and
# no backfill, so every existing instance, in every tenant schema, reads NULL after this migration.
# A NULL node is "unresolvable for scoped principals, visible to tenant-wide holders" (T13), which
# is how every instance behaved before; no existing flow changes. Adding a nullable column without
# a default is a catalogue-only change in Postgres (no table rewrite).
#
# The foreign key `instance_projections_scope_node_id_fkey` (39 bytes, under Postgres's 63-byte
# NAMEDATALEN) references `scope_node_paths (node_id)` ON DELETE RESTRICT: a node an instance names
# can never be deleted (orgs retire nodes instead). A partial index serves the later `scope_node_id`
# predicate.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this file's
# registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`. No new table,
# so `@expected_tenant_tables` is unchanged.
#
# The only interpolation is the schema name from `prefix()` (INV-7). `down` is guarded by
# `to_regclass` because a replay may find no `instance_projections` table.
defmodule Letflow.Repo.Migrations.AddScopeNodeIdToInstanceProjections do
  use Ecto.Migration

  @spec up() :: any()
  def up do
    if prefix() do
      schema = prefix()

      execute(~s|ALTER TABLE "#{schema}".instance_projections ADD COLUMN scope_node_id text NULL|)

      execute("""
      ALTER TABLE "#{schema}".instance_projections
        ADD CONSTRAINT instance_projections_scope_node_id_fkey
        FOREIGN KEY (scope_node_id) REFERENCES "#{schema}".scope_node_paths (node_id)
        ON DELETE RESTRICT
      """)

      execute("""
      CREATE INDEX instance_projections_scope_node_id_idx
        ON "#{schema}".instance_projections (scope_node_id)
        WHERE scope_node_id IS NOT NULL
      """)
    end
  end

  @spec down() :: any()
  def down do
    if prefix() do
      schema = prefix()

      execute(~s|DROP INDEX IF EXISTS "#{schema}".instance_projections_scope_node_id_idx|)

      execute("""
      DO $$
      BEGIN
        IF to_regclass('"#{schema}".instance_projections') IS NOT NULL THEN
          ALTER TABLE "#{schema}".instance_projections
            DROP CONSTRAINT IF EXISTS instance_projections_scope_node_id_fkey;
          ALTER TABLE "#{schema}".instance_projections DROP COLUMN IF EXISTS scope_node_id;
        END IF;
      END
      $$
      """)
    end
  end
end
