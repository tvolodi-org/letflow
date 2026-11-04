# Letflow.Repo.Migrations.MoveLedgerFksToPartitions
#
# REQ-711 (WMS stock ledger L1 rework, decision 0073 A5/A6): moves the two ledger foreign keys,
# `ledger_entry_reverses_entry_id_fkey` (reversal -> reversed entry) and `ledger_leg_entry_fk`
# (leg -> entry header), from the partitioned PARENTS to the PARTITIONS. A parent-level key is cloned by
# ATTACH PARTITION, and that clone makes ATTACH take SHARE ROW EXCLUSIVE on `ledger_entry` and
# `ledger_leg` (measured by REQ-711), which would block every posting of the tenant while a module is
# installed. Every row of a LIST partition has one ledger id, so a key from the leg partition (or the
# entry partition itself, for a reversal) to the entry partition of the SAME ledger id enforces what the
# parent key enforced: the database refuses a leg or a reversal across ledger ids (A5). The partitions of
# a new ledger id get their keys from `Letflow.Ledger.Storage.ensure/2` before ATTACH.
#
# This migration adds the per-partition keys to every EXISTING partition (named
# `<parent key name>_<h>`, `h` = the last 16 characters of the partition name, the same suffix
# Storage gives indexes), then drops the two parent keys. Replay is a no-op. No table, column or row is
# altered; a partition that holds rows is safe because the parent key already guaranteed them.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# Letflow.TenantProvisioning's manifest. The only interpolated value is the trusted `prefix()` schema
# name; statements inside the DO blocks are built with format() and %I (INV-7).
#
# down/0 refuses unless `:allow_ledger_migration_down` is true (dev/test only); it drops the
# per-partition keys and restores the two parent keys (which ATTACH-style clone onto the partitions).
defmodule Letflow.Repo.Migrations.MoveLedgerFksToPartitions do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      DO $move$
      DECLARE
        s constant text := '#{schema}';
        r record;
        h text;
      BEGIN
        FOR r IN
          SELECT c.relname AS part
            FROM pg_inherits i
            JOIN pg_class c ON c.oid = i.inhrelid
           WHERE i.inhparent = format('%I.%I', s, 'ledger_entry')::regclass
        LOOP
          h := right(r.part, 16);
          IF NOT EXISTS (SELECT 1 FROM pg_constraint k
                          WHERE k.conrelid = format('%I.%I', s, r.part)::regclass
                            AND k.conname = 'ledger_entry_reverses_entry_id_fkey_' || h) THEN
            EXECUTE format(
              'ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (reverses_entry_id, ledger_id) REFERENCES %I.%I (id, ledger_id)',
              s, r.part, 'ledger_entry_reverses_entry_id_fkey_' || h, s, r.part);
          END IF;
        END LOOP;

        FOR r IN
          SELECT c.relname AS part
            FROM pg_inherits i
            JOIN pg_class c ON c.oid = i.inhrelid
           WHERE i.inhparent = format('%I.%I', s, 'ledger_leg')::regclass
        LOOP
          h := right(r.part, 16);
          IF NOT EXISTS (SELECT 1 FROM pg_constraint k
                          WHERE k.conrelid = format('%I.%I', s, r.part)::regclass
                            AND k.conname = 'ledger_leg_entry_fk_' || h) THEN
            EXECUTE format(
              'ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (entry_id, ledger_id, posting_seq, event_time) REFERENCES %I.%I (id, ledger_id, posting_seq, event_time)',
              s, r.part, 'ledger_leg_entry_fk_' || h, s, 'ledger_entry_p' || h);
          END IF;
        END LOOP;
      END
      $move$
      """)

      execute(
        ~s|ALTER TABLE "#{schema}".ledger_leg DROP CONSTRAINT IF EXISTS ledger_leg_entry_fk|
      )

      execute(
        ~s|ALTER TABLE "#{schema}".ledger_entry DROP CONSTRAINT IF EXISTS ledger_entry_reverses_entry_id_fkey|
      )
    end
  end

  def down do
    unless Application.get_env(:letflow, :allow_ledger_migration_down, false) == true do
      raise "ledger tables are append-only: MoveLedgerFksToPartitions.down refused " <>
              "(set :allow_ledger_migration_down for dev/test only)"
    end

    if prefix() do
      schema = prefix()

      # The per-partition keys go first: an equal key left on a partition would be adopted by the
      # parent key below and could then no longer be dropped by name.
      execute("""
      DO $unmove$
      DECLARE
        s constant text := '#{schema}';
        r record;
      BEGIN
        FOR r IN
          SELECT c.relname AS part, k.conname AS key
            FROM pg_constraint k
            JOIN pg_class c ON c.oid = k.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = s AND k.contype = 'f' AND k.conparentid = 0
             AND (k.conname ~ '^ledger_entry_reverses_entry_id_fkey_[0-9a-f]{16}$'
               OR k.conname ~ '^ledger_leg_entry_fk_[0-9a-f]{16}$')
        LOOP
          EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', s, r.part, r.key);
        END LOOP;
      END
      $unmove$
      """)

      execute(
        ~s|ALTER TABLE "#{schema}".ledger_entry ADD CONSTRAINT ledger_entry_reverses_entry_id_fkey | <>
          ~s|FOREIGN KEY (reverses_entry_id, ledger_id) REFERENCES "#{schema}".ledger_entry (id, ledger_id)|
      )

      execute(
        ~s|ALTER TABLE "#{schema}".ledger_leg ADD CONSTRAINT ledger_leg_entry_fk | <>
          ~s|FOREIGN KEY (entry_id, ledger_id, posting_seq, event_time) | <>
          ~s|REFERENCES "#{schema}".ledger_entry (id, ledger_id, posting_seq, event_time)|
      )
    end
  end
end
