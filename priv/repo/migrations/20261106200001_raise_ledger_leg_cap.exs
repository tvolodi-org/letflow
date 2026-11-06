# Letflow.Repo.Migrations.RaiseLedgerLegCap
#
# REQ-774 (stock documents at volume, decision 0073 amendment): one posting may now carry 2000 legs, so the
# two CHECK constraints that bound it move from 200 to 2000:
#   * `ledger_entry_leg_count_check`  CHECK (leg_count BETWEEN 1 AND 2000)  on ledger_entry
#   * `ledger_leg_leg_no_check`       CHECK (leg_no BETWEEN 1 AND 2000)     on ledger_leg
# Both tables are partitioned by ledger id. Partitions are built with `CREATE TABLE ... (LIKE parent
# INCLUDING ALL)` and then attached (`Letflow.Ledger.Storage`), so each EXISTING partition holds its own copy
# of the old constraint (merged with the parent's on ATTACH). Dropping the parent's constraint is therefore
# not enough: the loop below drops the constraint on the parent, then on every partition, then adds the new
# one on the parent, which cascades to the partitions. Partitions created later copy the new constraint.
# Existing rows are valid under the wider range. Replay is a no-op (DROP IF EXISTS, then ADD).
#
# Locking: ADD CHECK scans the partitions under ACCESS EXCLUSIVE; the ledger tables are small at the time of
# writing (QA), and the migration is not part of a request path.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# Letflow.TenantProvisioning's manifest. The only interpolated value is the trusted `prefix()` schema name;
# statements inside the DO block are built with format() and %I (INV-7). It is not a module manifest key.
#
# down/0 refuses unless `:allow_ledger_migration_down` is true (dev/test only), then restores 200 (it fails if a
# row above 200 exists).
defmodule Letflow.Repo.Migrations.RaiseLedgerLegCap do
  use Ecto.Migration

  def up, do: set_cap(2000)

  def down do
    unless Application.get_env(:letflow, :allow_ledger_migration_down, false) == true do
      raise "ledger tables are append-only: RaiseLedgerLegCap.down refused " <>
              "(set :allow_ledger_migration_down for dev/test only)"
    end

    set_cap(200)
  end

  defp set_cap(cap) do
    if prefix() do
      schema = prefix()

      execute("""
      DO $cap$
      DECLARE
        s constant text := '#{schema}';
        cap constant integer := #{cap};
        r record;
        t record;
      BEGIN
        FOR t IN
          SELECT * FROM (VALUES
            ('ledger_entry', 'ledger_entry_leg_count_check', 'leg_count'),
            ('ledger_leg', 'ledger_leg_leg_no_check', 'leg_no')) AS v(tbl, con, col)
        LOOP
          EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I', s, t.tbl, t.con);

          FOR r IN
            SELECT c.relname AS part
              FROM pg_inherits i
              JOIN pg_class c ON c.oid = i.inhrelid
             WHERE i.inhparent = format('%I.%I', s, t.tbl)::regclass
          LOOP
            EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I', s, r.part, t.con);
          END LOOP;

          EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%I BETWEEN 1 AND %s)',
                         s, t.tbl, t.con, t.col, cap);
        END LOOP;
      END
      $cap$
      """)
    end
  end
end
