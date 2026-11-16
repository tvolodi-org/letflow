# Letflow.Repo.Migrations.CreateNegativeBalanceSettings
#
# REQ-834 / GH #4547 (decision 0090 sections 3 and 5.1; Qoimeks parity G4 part 2): the per-tenant
# negative balance setting of a ledger registration, and the end of the database rule
# `on_hand >= 0`.
#
# 1. Creates `ledger_balance_settings`, one row per registration name. No row means refuse, so
#    the table starts EMPTY in every schema and this migration writes no data: no tenant changes
#    behaviour by rolling it out.
# 2. Drops CHECK `ledger_balance_on_hand_check` (`on_hand >= 0`) of the partitioned `ledger_balance`
#    (the partitions inherit it, so one statement on the parent removes it everywhere). The CHECK on
#    `max_on_hand` stays. The column type `numeric(30,9)` is the database lower bound (an absolute
#    value of 10^21 or more is SQLSTATE 22003); the guard in `Letflow.Ledger` refuses at -1.0E+21.
#    Dropping a check needs no data step.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`); the schema is the tenant boundary, so the
# row carries no tenant_id (0006 D2), as `approval_rule_settings`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
#
# down: re-adds the CHECK; Postgres refuses it while a negative on_hand row exists, which is the
# honest answer (nothing is rewritten).
defmodule Letflow.Repo.Migrations.CreateNegativeBalanceSettings do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".ledger_balance_settings (
        id uuid PRIMARY KEY,
        registration_name text NOT NULL CHECK (char_length(registration_name) BETWEEN 1 AND 255),
        allow_negative boolean NOT NULL,
        changed_by uuid NOT NULL,
        changed_at timestamptz NOT NULL,
        reason text NOT NULL,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX ledger_balance_settings_registration_index ON "#{schema}".ledger_balance_settings (registration_name)|
      )

      execute(
        ~s|ALTER TABLE "#{schema}".ledger_balance DROP CONSTRAINT IF EXISTS ledger_balance_on_hand_check|
      )
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(
        ~s|ALTER TABLE "#{schema}".ledger_balance ADD CONSTRAINT ledger_balance_on_hand_check CHECK (on_hand >= 0)|
      )

      execute(~s|DROP TABLE IF EXISTS "#{schema}"."ledger_balance_settings"|)
    end
  end
end
