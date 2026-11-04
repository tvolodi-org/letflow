# Letflow.Repo.Migrations.CreateEntityScopeDeclarations
#
# REQ-635 / GH #3549 -- decision 0070 D3 and D6 slice B (Q1 option (a): a core table).
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`); no `tenant_id` column (decision 0006
# D2), isolation is the schema.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7).
#
# One row per tenant-owned entity type: how a scoped caller's read of that type is filtered
# (`tenant_wide` or a `column`). The table starts empty: no backfill, no existing tenant changes
# behaviour (an undeclared type stays `:undeclared`).
defmodule Letflow.Repo.Migrations.CreateEntityScopeDeclarations do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:entity_scope_declarations, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :entity_type, :string, size: 255, null: false
        add :kind, :string, size: 16, null: false
        add :field, :string, size: 255
        add :set_by, :binary_id, null: false

        timestamps(type: :utc_datetime_usec)
      end

      create unique_index(
               :entity_scope_declarations,
               [:entity_type],
               name: :entity_scope_declarations_entity_type_idx,
               prefix: schema
             )

      create constraint(
               :entity_scope_declarations,
               :entity_scope_declarations_kind_field_check,
               check:
                 "(kind = 'tenant_wide' AND field IS NULL) OR (kind = 'column' AND field IS NOT NULL)",
               prefix: schema
             )
    end
  end
end
