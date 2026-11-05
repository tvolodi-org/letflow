# Letflow.Repo.Migrations.CreateEntityTypeWriteAccessTables
#
# REQ-577 / GH #3261 -- decision 0070 D2 and D6 slice A (Q2 option 1: a second table pair).
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`), same as `entity_type_restrictions`
# and `user_entity_type_grants`; no `tenant_id` column (decision 0006 D2), isolation is the schema.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7).
#
# A row in `entity_type_write_restrictions` closes WRITING of the type to every user without a
# `user_entity_type_write_grants` row for it; reading stays with `TypeAccess`. Both tables start
# empty: no backfill, no existing row changes.
defmodule Letflow.Repo.Migrations.CreateEntityTypeWriteAccessTables do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:entity_type_write_restrictions, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :entity_type, :string, size: 255, null: false

        timestamps(type: :utc_datetime_usec)
      end

      create unique_index(
               :entity_type_write_restrictions,
               [:entity_type],
               name: :entity_type_write_restrictions_entity_type_idx,
               prefix: schema
             )

      create table(:user_entity_type_write_grants, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :user_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
        add :entity_type, :string, size: 255, null: false

        timestamps(updated_at: false, type: :utc_datetime_usec)
      end

      create unique_index(
               :user_entity_type_write_grants,
               [:user_id, :entity_type],
               name: :user_entity_type_write_grants_user_id_entity_type_idx,
               prefix: schema
             )
    end
  end
end
