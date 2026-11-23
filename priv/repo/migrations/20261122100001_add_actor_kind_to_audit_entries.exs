# Letflow.Repo.Migrations.AddActorKindToAuditEntries
#
# T-2588 (pilot gap G2), decision (d) of
# docs/migration/decisions/0094-platform-call-authority.md: the audit row tells
# "nobody" from "the system".
#
# Adds `audit_entries.actor_kind`: the kind of the actor a lifecycle row records
# -- `user` (a person) or `system` (module code, a seed task, a job). Nullable,
# no default and NO backfill: NULL is a row written before this column existed.
# The column is NOT part of the chain hash (REQ-195's canonical hashed form
# names eleven fields and stays as it is -- changing it would invalidate every
# stored chain); the table's own immutability trigger is what keeps the value
# from being edited after the row is written.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# Existing tenants receive the column through the boot-time replay.
#
# Reversible: `change/0` with a single `alter ... add`.
defmodule Letflow.Repo.Migrations.AddActorKindToAuditEntries do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:audit_entries, prefix: prefix()) do
        add :actor_kind, :string
      end
    end
  end
end
