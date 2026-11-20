# Letflow.Repo.Migrations.AllowZeroCountLedgerLegs
#
# Qoimeks old-client parity (T-2415): the old server stored an empty-shelf count (book 0, counted 0)
# as a real reversible movement. Such a count_set entry has one zero leg. The stock policy and the
# core ledger validator allow zero ONLY for count_set; every other cause keeps its positive/nonzero
# rule. This migration removes the older database-wide quantity <> 0 check, which cannot distinguish
# a count_set leg from another cause (ledger_leg has no cause column).
#
# The table is partitioned by ledger id. Existing partitions hold their own copy of the constraint,
# so drop it on the parent and every partition; partitions created later copy the parent's new shape.
# Existing rows need no data change and replay is a no-op.
#
# TENANT-SCOPED MIGRATION -- the `if prefix()` guard is MANDATORY, and this file is registered in
# Letflow.TenantProvisioning's manifest. The only interpolated value is the trusted prefix() schema
# name; statements in the DO block use format() and %I (INV-7).
#
# down/0 refuses unless :allow_ledger_migration_down is true (dev/test only), then restores the old
# check. Postgres refuses that restore while a zero leg exists; no ledger row is rewritten.
defmodule Letflow.Repo.Migrations.AllowZeroCountLedgerLegs do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      DO $zero_count$
      DECLARE
        s constant text := '#{schema}';
        r record;
      BEGIN
        EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I',
                       s, 'ledger_leg', 'ledger_leg_quantity_check');

        FOR r IN
          SELECT c.relname AS part
            FROM pg_inherits i
            JOIN pg_class c ON c.oid = i.inhrelid
           WHERE i.inhparent = format('%I.%I', s, 'ledger_leg')::regclass
        LOOP
          EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I',
                         s, r.part, 'ledger_leg_quantity_check');
        END LOOP;
      END
      $zero_count$
      """)
    end
  end

  def down do
    unless Application.get_env(:letflow, :allow_ledger_migration_down, false) == true do
      raise "ledger tables are append-only: AllowZeroCountLedgerLegs.down refused " <>
              "(set :allow_ledger_migration_down for dev/test only)"
    end

    if prefix() do
      execute(
        ~s|ALTER TABLE "#{prefix()}".ledger_leg ADD CONSTRAINT ledger_leg_quantity_check CHECK (quantity <> 0)|
      )
    end
  end
end
