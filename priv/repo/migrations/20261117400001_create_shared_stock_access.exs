# Letflow.Repo.Migrations.CreateSharedStockAccess
#
# REQ-858 / GH #4573 (decision 0091 section 4; Qoimeks parity G13 part 2): the per-tenant
# shared stock access credential (a stock-only token for the old Qoimeks app). One row holds
# the SHA-256 hex of the value (never the value), who created it, when it was rotated or
# revoked. A revoked row stays (audit anchor); at most one ACTIVE row per tenant (partial
# unique index on `revoked_at IS NULL`).
#
# The table starts EMPTY in every schema and this migration writes no data: no tenant gets a
# credential by rolling it out. Existing QA tenants get the table from the boot replay
# (MigrationReplayBoot, ISS-0771).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
# The schema is the tenant boundary, so the row carries no tenant_id (0006 D2).
defmodule Letflow.Repo.Migrations.CreateSharedStockAccess do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".shared_stock_access (
        id uuid PRIMARY KEY,
        token_hash text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
        actor_id uuid NOT NULL,
        created_by_user_id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        rotated_at timestamptz,
        revoked_at timestamptz,
        revoked_by_user_id uuid,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX shared_stock_access_active_index ON "#{schema}".shared_stock_access ((true)) WHERE revoked_at IS NULL|
      )

      execute(
        ~s|CREATE UNIQUE INDEX shared_stock_access_hash_index ON "#{schema}".shared_stock_access (token_hash) WHERE revoked_at IS NULL|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."shared_stock_access"|)
    end
  end
end
