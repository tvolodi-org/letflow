# Letflow.Repo.Migrations.AddActivatedByToProcessDefinitions
#
# GH #2587 / REQ-499 PR B1 (decision 0054 D4a, design
# lib/letflow/design/gh2587-req499-pr-b-human-task-writes.md D-B.14, D-B.24, I-B11).
#
# Adds `process_definitions.activated_by`, the authority a definition with declarative
# `entity_writes` was activated under: the activator's user id, effective roles, evaluated
# permissions and the authorised (entity_type, op) pairs. Nullable jsonb, no default and NO
# backfill: NULL means "no `entity_writes` on this graph" (every existing row, and every
# row activated without lines). Written only by the three activation paths; no changeset
# casts it.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# Existing tenants receive the column through the boot-time replay.
#
# Reversible: `change/0` with a single `alter ... add`.
defmodule Letflow.Repo.Migrations.AddActivatedByToProcessDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:process_definitions, prefix: prefix()) do
        add :activated_by, :map
      end
    end
  end
end
