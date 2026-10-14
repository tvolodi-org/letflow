# Letflow.Repo.Migrations.CreateScopeNodePaths
#
# REQ-496 / GH #2530 (decision 0050 D8, Deviation 1) -- see
# lib/letflow/design/req496-managed-by-and-scope-node-paths.md section 5 for the design.
#
# The core-owned materialized-path security index over a tenant's scope tree. One row per node:
# `path` is "/<root id>/.../<node id>/", `depth` its segment count (root = 1). Exactly one writer,
# `Letflow.ScopeNodePaths.write/2` (enforced by `mix letflow.check_scope_node_paths_writers`).
# No upper-bound CHECK on `depth`: the bound (12) is enforced by the writer and DETECTED by the
# consistency check, which must be able to see a depth-13 row.
#
# PLACEMENT: per-tenant (0006 D2: no tenant_id column). No FK to any module table (0050 D8).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# Existing tenants receive the table through the boot-time replay; it starts empty.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.CreateScopeNodePaths do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:scope_node_paths, primary_key: false, prefix: schema) do
        add :node_id, :text, primary_key: true
        add :path, :text, null: false
        add :depth, :smallint, null: false
        add :retired_at, :utc_datetime_usec

        timestamps(type: :utc_datetime_usec)
      end

      create constraint(:scope_node_paths, :scope_node_paths_depth_positive,
               check: "depth >= 1",
               prefix: schema
             )

      # `text_pattern_ops` so a left-anchored `path LIKE '<prefix>%'` uses the index under any
      # collation; UNIQUE because a path names exactly one node.
      execute(
        """
        CREATE UNIQUE INDEX scope_node_paths_path_pattern_idx
          ON "#{schema}".scope_node_paths (path text_pattern_ops)
        """,
        """
        DROP INDEX IF EXISTS "#{schema}".scope_node_paths_path_pattern_idx
        """
      )
    end
  end
end
