# Letflow.Repo.Migrations.CreateLedgerTriggers
#
# REQ-620 / GH #3463 part B (WMS stock ledger L1; notes gh2657 sections 5.1 to 5.3 and 6.2) -- the
# database rules on the four ledger tables created by CreateLedgerTables: `ledger_entry` and
# `ledger_leg` are append-only, `ledger_counter` moves one step at a time, `ledger_balance` moves only
# with the counter, and the gap-free `posting_seq` and the digest chain are checked at COMMIT. No digest
# is computed here (slice L2a); the database checks that the stored 64-hex values are consistent.
#
# Every trigger is created `ENABLE ALWAYS`, so it also fires under `session_replication_role = replica`
# (decision 0056 D4). Every RAISE carries a fixed text plus SCHEMA and TABLE; no value is echoed
# (INV-2, INV-8). Function bodies read sibling tables only through `EXECUTE format('%I...',
# TG_TABLE_SCHEMA)` with values bound by USING (INV-1, INV-7): no schema name is written in a body, so
# a cloned tenant schema reads its own tables.
#
# RESIDUAL (note 5.1): the table owner can still `ALTER TABLE ... DISABLE TRIGGER`. These triggers are
# a tripwire, not a security boundary; the hash chain detects such a tamper afterwards, and REVOKE is
# not used. Balance `last_posting_seq` may change while `on_hand` does not (note 5.2 states the on_hand
# case only; reconciliation covers the rest).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# Letflow.TenantProvisioning's manifest. All CREATE and ALTER text is literal SQL; the only value
# interpolated into it is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
#
# OPERATOR NOTE: the tables are empty and no row is altered; existing tenants receive the functions
# and triggers through `replay_all_pending/0` after deploy. `down` removes tamper protection, so it
# refuses to run unless `:allow_ledger_migration_down` is true (config/dev.exs and config/test.exs).
defmodule Letflow.Repo.Migrations.CreateLedgerTriggers do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      for sql <- functions(schema) ++ triggers(schema), do: execute(sql)
    end
  end

  def down do
    unless Application.get_env(:letflow, :allow_ledger_migration_down, false) == true do
      raise "ledger triggers are tamper protection: CreateLedgerTriggers.down refused " <>
              "(set :allow_ledger_migration_down for dev/test only)"
    end

    if prefix() do
      schema = prefix()

      for {table, name} <- trigger_specs() do
        execute(~s(DROP TRIGGER IF EXISTS #{name} ON "#{schema}"."#{table}"))
      end

      for name <-
            ~w(ledger_refuse ledger_guard_counter ledger_guard_balance ledger_guard_entry_insert ledger_check_counter ledger_check_entry) do
        execute(~s|DROP FUNCTION IF EXISTS "#{schema}"."#{name}"()|)
      end
    end
  end

  # {table, trigger name}: used by `down` and by the catalog test only.
  def trigger_specs do
    [
      {"ledger_entry", "ledger_entry_guard_update"},
      {"ledger_entry", "ledger_entry_guard_delete"},
      {"ledger_entry", "ledger_entry_guard_truncate"},
      {"ledger_entry", "ledger_entry_guard_insert"},
      {"ledger_entry", "ledger_entry_check_commit"},
      {"ledger_leg", "ledger_leg_guard_update"},
      {"ledger_leg", "ledger_leg_guard_delete"},
      {"ledger_leg", "ledger_leg_guard_truncate"},
      {"ledger_counter", "ledger_counter_guard_insert"},
      {"ledger_counter", "ledger_counter_guard_update"},
      {"ledger_counter", "ledger_counter_guard_delete"},
      {"ledger_counter", "ledger_counter_guard_truncate"},
      {"ledger_counter", "ledger_counter_check_commit"},
      {"ledger_balance", "ledger_balance_guard_insert"},
      {"ledger_balance", "ledger_balance_guard_update"},
      {"ledger_balance", "ledger_balance_guard_delete"},
      {"ledger_balance", "ledger_balance_guard_truncate"}
    ]
  end

  defp functions(schema) do
    [
      """
      CREATE OR REPLACE FUNCTION "#{schema}".ledger_refuse() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'ledger data is append-only: this statement is refused'
          USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".ledger_guard_counter() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          IF NEW.last_seq <> 0 OR NEW.last_chain_hash <> '' THEN
            RAISE EXCEPTION 'ledger counter insert rule violated'
              USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
          END IF;
        ELSE
          IF NEW.ledger_id <> OLD.ledger_id OR NEW.last_seq <> OLD.last_seq + 1 THEN
            RAISE EXCEPTION 'ledger counter update rule violated'
              USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".ledger_guard_balance() RETURNS trigger AS $$
      DECLARE
        counter_seq bigint;
      BEGIN
        IF TG_OP = 'INSERT' THEN
          IF NEW.on_hand <> 0 OR NEW.last_posting_seq <> 0 THEN
            RAISE EXCEPTION 'ledger balance insert rule violated'
              USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
          END IF;

          RETURN NEW;
        END IF;

        IF NEW.ledger_id IS DISTINCT FROM OLD.ledger_id
           OR NEW.k1 IS DISTINCT FROM OLD.k1 OR NEW.k2 IS DISTINCT FROM OLD.k2
           OR NEW.k3 IS DISTINCT FROM OLD.k3 OR NEW.k4 IS DISTINCT FROM OLD.k4
           OR NEW.k5 IS DISTINCT FROM OLD.k5 OR NEW.k6 IS DISTINCT FROM OLD.k6
           OR NEW.k7 IS DISTINCT FROM OLD.k7 OR NEW.k8 IS DISTINCT FROM OLD.k8
           OR NEW.unit_ref IS DISTINCT FROM OLD.unit_ref
           OR NEW.max_on_hand IS DISTINCT FROM OLD.max_on_hand THEN
          RAISE EXCEPTION 'ledger balance update rule violated'
            USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
        END IF;

        IF NEW.on_hand IS DISTINCT FROM OLD.on_hand THEN
          EXECUTE format('SELECT last_seq FROM %I.ledger_counter WHERE ledger_id = $1', TG_TABLE_SCHEMA)
            INTO counter_seq USING NEW.ledger_id;

          IF counter_seq IS NULL OR NEW.last_posting_seq IS DISTINCT FROM counter_seq THEN
            RAISE EXCEPTION 'ledger balance update rule violated'
              USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".ledger_guard_entry_insert() RETURNS trigger AS $$
      DECLARE
        counter_seq bigint;
        target_ledger text;
        target_reverses uuid;
      BEGIN
        EXECUTE format('SELECT last_seq FROM %I.ledger_counter WHERE ledger_id = $1', TG_TABLE_SCHEMA)
          INTO counter_seq USING NEW.ledger_id;

        IF counter_seq IS NULL OR NEW.posting_seq <> counter_seq THEN
          RAISE EXCEPTION 'ledger entry posting sequence rule violated'
            USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
        END IF;

        IF NEW.reverses_entry_id IS NOT NULL THEN
          EXECUTE format('SELECT ledger_id, reverses_entry_id FROM %I.ledger_entry WHERE id = $1', TG_TABLE_SCHEMA)
            INTO target_ledger, target_reverses USING NEW.reverses_entry_id;

          IF target_ledger IS NULL OR target_ledger <> NEW.ledger_id OR target_reverses IS NOT NULL THEN
            RAISE EXCEPTION 'ledger entry reversal rule violated'
              USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".ledger_check_counter() RETURNS trigger AS $$
      DECLARE
        found_hash text;
      BEGIN
        EXECUTE format('SELECT chain_hash FROM %I.ledger_entry WHERE ledger_id = $1 AND posting_seq = $2', TG_TABLE_SCHEMA)
          INTO found_hash USING NEW.ledger_id, NEW.last_seq;

        IF found_hash IS NULL OR found_hash <> NEW.last_chain_hash THEN
          RAISE EXCEPTION 'ledger counter has no matching entry'
            USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
        END IF;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".ledger_check_entry() RETURNS trigger AS $$
      DECLARE
        leg_total bigint;
        bad bigint;
      BEGIN
        EXECUTE format('SELECT count(*) FROM %I.ledger_leg WHERE entry_id = $1', TG_TABLE_SCHEMA)
          INTO leg_total USING NEW.id;

        IF leg_total <> NEW.leg_count THEN
          RAISE EXCEPTION 'ledger entry leg count rule violated'
            USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
        END IF;

        bad := 0;

        IF NEW.sign_rule = 'positive' THEN
          EXECUTE format('SELECT count(*) FROM %I.ledger_leg WHERE entry_id = $1 AND quantity <= 0', TG_TABLE_SCHEMA)
            INTO bad USING NEW.id;
        ELSIF NEW.sign_rule = 'negative' THEN
          EXECUTE format('SELECT count(*) FROM %I.ledger_leg WHERE entry_id = $1 AND quantity >= 0', TG_TABLE_SCHEMA)
            INTO bad USING NEW.id;
        ELSIF NEW.sign_rule = 'zero_sum_by_slot_1' THEN
          EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM %I.ledger_leg WHERE entry_id = $1 GROUP BY k1 HAVING sum(quantity) <> 0) g', TG_TABLE_SCHEMA)
            INTO bad USING NEW.id;
        END IF;

        IF bad > 0 THEN
          RAISE EXCEPTION 'ledger entry sign rule violated'
            USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
        END IF;

        IF NEW.reverses_entry_id IS NOT NULL THEN
          EXECUTE format(
            'SELECT count(*) FROM '
            || '(SELECT k1, k2, k3, k4, k5, k6, k7, k8, sum(quantity) AS q FROM %1$I.ledger_leg WHERE entry_id = $1 GROUP BY k1, k2, k3, k4, k5, k6, k7, k8) a '
            || 'FULL JOIN '
            || '(SELECT k1, k2, k3, k4, k5, k6, k7, k8, sum(quantity) AS q FROM %1$I.ledger_leg WHERE entry_id = $2 GROUP BY k1, k2, k3, k4, k5, k6, k7, k8) b '
            || 'USING (k1, k2, k3, k4, k5, k6, k7, k8) '
            || 'WHERE a.q IS NULL OR b.q IS NULL OR a.q + b.q <> 0',
            TG_TABLE_SCHEMA)
            INTO bad USING NEW.id, NEW.reverses_entry_id;

          IF bad > 0 THEN
            RAISE EXCEPTION 'ledger entry reversal sum rule violated'
              USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
          END IF;
        END IF;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
      """
    ]
  end

  # `ENABLE ALWAYS` follows each trigger, so none is left in its default `ENABLE ORIGIN` state.
  defp triggers(schema) do
    [
      ~s|CREATE TRIGGER ledger_entry_guard_update BEFORE UPDATE ON "#{schema}".ledger_entry FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_entry ENABLE ALWAYS TRIGGER ledger_entry_guard_update|,
      ~s|CREATE TRIGGER ledger_entry_guard_delete BEFORE DELETE ON "#{schema}".ledger_entry FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_entry ENABLE ALWAYS TRIGGER ledger_entry_guard_delete|,
      ~s|CREATE TRIGGER ledger_entry_guard_truncate BEFORE TRUNCATE ON "#{schema}".ledger_entry FOR EACH STATEMENT EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_entry ENABLE ALWAYS TRIGGER ledger_entry_guard_truncate|,
      ~s|CREATE TRIGGER ledger_entry_guard_insert BEFORE INSERT ON "#{schema}".ledger_entry FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_guard_entry_insert()|,
      ~s|ALTER TABLE "#{schema}".ledger_entry ENABLE ALWAYS TRIGGER ledger_entry_guard_insert|,
      ~s|CREATE CONSTRAINT TRIGGER ledger_entry_check_commit AFTER INSERT ON "#{schema}".ledger_entry DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_check_entry()|,
      ~s|ALTER TABLE "#{schema}".ledger_entry ENABLE ALWAYS TRIGGER ledger_entry_check_commit|,
      ~s|CREATE TRIGGER ledger_leg_guard_update BEFORE UPDATE ON "#{schema}".ledger_leg FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_leg ENABLE ALWAYS TRIGGER ledger_leg_guard_update|,
      ~s|CREATE TRIGGER ledger_leg_guard_delete BEFORE DELETE ON "#{schema}".ledger_leg FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_leg ENABLE ALWAYS TRIGGER ledger_leg_guard_delete|,
      ~s|CREATE TRIGGER ledger_leg_guard_truncate BEFORE TRUNCATE ON "#{schema}".ledger_leg FOR EACH STATEMENT EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_leg ENABLE ALWAYS TRIGGER ledger_leg_guard_truncate|,
      ~s|CREATE TRIGGER ledger_counter_guard_insert BEFORE INSERT ON "#{schema}".ledger_counter FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_guard_counter()|,
      ~s|ALTER TABLE "#{schema}".ledger_counter ENABLE ALWAYS TRIGGER ledger_counter_guard_insert|,
      ~s|CREATE TRIGGER ledger_counter_guard_update BEFORE UPDATE ON "#{schema}".ledger_counter FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_guard_counter()|,
      ~s|ALTER TABLE "#{schema}".ledger_counter ENABLE ALWAYS TRIGGER ledger_counter_guard_update|,
      ~s|CREATE TRIGGER ledger_counter_guard_delete BEFORE DELETE ON "#{schema}".ledger_counter FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_counter ENABLE ALWAYS TRIGGER ledger_counter_guard_delete|,
      ~s|CREATE TRIGGER ledger_counter_guard_truncate BEFORE TRUNCATE ON "#{schema}".ledger_counter FOR EACH STATEMENT EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_counter ENABLE ALWAYS TRIGGER ledger_counter_guard_truncate|,
      ~s|CREATE CONSTRAINT TRIGGER ledger_counter_check_commit AFTER UPDATE ON "#{schema}".ledger_counter DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_check_counter()|,
      ~s|ALTER TABLE "#{schema}".ledger_counter ENABLE ALWAYS TRIGGER ledger_counter_check_commit|,
      ~s|CREATE TRIGGER ledger_balance_guard_insert BEFORE INSERT ON "#{schema}".ledger_balance FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_guard_balance()|,
      ~s|ALTER TABLE "#{schema}".ledger_balance ENABLE ALWAYS TRIGGER ledger_balance_guard_insert|,
      ~s|CREATE TRIGGER ledger_balance_guard_update BEFORE UPDATE ON "#{schema}".ledger_balance FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_guard_balance()|,
      ~s|ALTER TABLE "#{schema}".ledger_balance ENABLE ALWAYS TRIGGER ledger_balance_guard_update|,
      ~s|CREATE TRIGGER ledger_balance_guard_delete BEFORE DELETE ON "#{schema}".ledger_balance FOR EACH ROW EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_balance ENABLE ALWAYS TRIGGER ledger_balance_guard_delete|,
      ~s|CREATE TRIGGER ledger_balance_guard_truncate BEFORE TRUNCATE ON "#{schema}".ledger_balance FOR EACH STATEMENT EXECUTE FUNCTION "#{schema}".ledger_refuse()|,
      ~s|ALTER TABLE "#{schema}".ledger_balance ENABLE ALWAYS TRIGGER ledger_balance_guard_truncate|
    ]
  end
end
