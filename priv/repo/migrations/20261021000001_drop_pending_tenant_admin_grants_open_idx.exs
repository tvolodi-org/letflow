# Letflow.Repo.Migrations.DropPendingTenantAdminGrantsOpenIdx
#
# GH #2502: drops `pending_tenant_admin_grants_open_idx`, the partial index on `(email_key)`
# WHERE `consumed_at IS NULL AND revoked_at IS NULL` that 20261008000001 created next to the
# UNIQUE index `pending_tenant_admin_grants_email_key_idx` on the same column.
#
# WHY IT IS REDUNDANT: `pending_tenant_admin_grants_state_chk` pins
# `(consumed_at IS NULL AND revoked_at IS NULL) = (email_key IS NOT NULL)`, so every row with a
# non-NULL `email_key` is an open row. The partial index therefore indexes exactly the rows the
# unique index does; the login-path lookup (`email_key = $1 AND consumed_at IS NULL AND
# revoked_at IS NULL`) probes the unique index and filters the two NULL tests on at most one
# row. Keeping the second index only costs a write on every insert, bind and revoke.
#
# The shipped migration is not edited (it has run on existing tenants); this is a forward drop.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# No new table, so `@expected_tenant_tables` is unchanged.
#
# The only interpolation is the schema name from `prefix()` (INV-7). `up` is replay-safe
# (IF EXISTS); `down` is guarded by `to_regclass` because a replay may find no table.
defmodule Letflow.Repo.Migrations.DropPendingTenantAdminGrantsOpenIdx do
  use Ecto.Migration

  @spec up() :: any()
  def up do
    if prefix() do
      schema = prefix()

      execute(~s|DROP INDEX IF EXISTS "#{schema}".pending_tenant_admin_grants_open_idx|)
    end
  end

  @spec down() :: any()
  def down do
    if prefix() do
      schema = prefix()

      execute("""
      DO $$
      BEGIN
        IF to_regclass('"#{schema}".pending_tenant_admin_grants') IS NOT NULL THEN
          CREATE INDEX IF NOT EXISTS pending_tenant_admin_grants_open_idx
            ON "#{schema}".pending_tenant_admin_grants (email_key)
            WHERE consumed_at IS NULL AND revoked_at IS NULL;
        END IF;
      END
      $$
      """)
    end
  end
end
