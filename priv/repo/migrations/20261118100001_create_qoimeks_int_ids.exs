# Letflow.Repo.Migrations.CreateQoimeksIntIds
#
# REQ-859 / GH #4572 (decision 0091 section 7; Qoimeks parity G13 part 3): the three per-tenant
# mapping tables that give a Letflow uuid a stable integer for the old Qoimeks app, whose ids are
# integers: `catalog_item_int_ids` (sku_id), `location_node_int_ids` (location_id) and
# `movement_int_ids` (movement id). The integer is a bigserial: assigned once, never
# changed, starting at 1 per table (so per tenant); a gap is possible after a lost insert race.
# The tables start EMPTY and this migration writes no data; rows appear when the old-app address
# first answers a read that names the uuid. Existing QA tenants get the tables from the boot
# replay (MigrationReplayBoot, ISS-0771).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated values are the trusted `prefix()` schema name and fixed table names, quoted as
# identifiers (INV-7). The schema is the tenant boundary, so a row carries no tenant_id (0006 D2).
defmodule Letflow.Repo.Migrations.CreateQoimeksIntIds do
  use Ecto.Migration

  @tables ~w(catalog_item_int_ids location_node_int_ids movement_int_ids)

  def up do
    if prefix() do
      schema = prefix()

      for table <- @tables do
        execute("""
        CREATE TABLE "#{schema}"."#{table}" (
          int_id bigserial PRIMARY KEY,
          ref_id uuid NOT NULL UNIQUE,
          inserted_at timestamptz NOT NULL DEFAULT now()
        )
        """)
      end
    end
  end

  def down do
    if prefix() do
      for table <- @tables do
        execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."#{table}"|)
      end
    end
  end
end
