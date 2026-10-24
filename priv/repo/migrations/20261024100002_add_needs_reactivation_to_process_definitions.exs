# Letflow.Repo.Migrations.AddNeedsReactivationToProcessDefinitions
#
# GH #2692 / REQ-515 (decision 0054 D4a.4, open point 9): a second axis on an ACTIVE definition
# whose recorded activator lost its authority. `needs_reactivation_at` / `needs_reactivation_reason`
# are both NULL (ok) or both set (needs reactivation); `status` stays `active`. Server-owned: no
# changeset casts them. NO backfill: NULL = ok for every existing row.
#
# TENANT-SCOPED MIGRATION -- the `if prefix()` guard is MANDATORY, and so is this file's
# registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# Reversible: `change/0`.
defmodule Letflow.Repo.Migrations.AddNeedsReactivationToProcessDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:process_definitions, prefix: schema) do
        add :needs_reactivation_at, :utc_datetime_usec
        add :needs_reactivation_reason, :string, size: 64
      end

      create constraint(
               :process_definitions,
               :process_definitions_needs_reactivation_both_or_none,
               check:
                 "(needs_reactivation_at IS NULL AND needs_reactivation_reason IS NULL) " <>
                   "OR (needs_reactivation_at IS NOT NULL AND needs_reactivation_reason IS NOT NULL)",
               prefix: schema
             )
    end
  end
end
