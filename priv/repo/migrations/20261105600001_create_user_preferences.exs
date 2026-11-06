# Letflow.Repo.Migrations.CreateUserPreferences
#
# T-1389 -- per-user preferences store (core). Table `user_preferences`, one row per (user, key).
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`); no `tenant_id` column (decision 0006
# D2), isolation is the schema. No foreign key to `users`: users live in the public schema.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7).
#
# The table starts empty: no backfill, no existing tenant changes behaviour. `value` is a jsonb
# object `{"v": <validated value>}` (Ecto `:map` cannot hold a bare scalar).
defmodule Letflow.Repo.Migrations.CreateUserPreferences do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:user_preferences, primary_key: false, prefix: schema) do
        add :user_id, :binary_id, null: false
        add :key, :string, size: 64, null: false
        add :value, :map, null: false

        timestamps(type: :utc_datetime_usec, inserted_at: false)
      end

      create unique_index(:user_preferences, [:user_id, :key],
               name: :user_preferences_user_id_key_idx,
               prefix: schema
             )
    end
  end
end
