# Letflow.Repo.Migrations.CreateLedgerPartitionedTables
#
# REQ-710 (WMS stock ledger L1, decision 0073 A5/A6/A8): replaces the four ledger tables of
# CreateLedgerTables with the shape the speed test picked, (b): `ledger_entry`, `ledger_leg` and
# `ledger_balance` are `PARTITION BY LIST (ledger_id)` parents (one partition set per ledger id, made
# by `Letflow.Ledger.Storage.ensure/2`, never inside a posting); `ledger_counter` stays a plain table.
# The keys are the A5 keys (the primary keys and the leg-to-header key carry `ledger_id`), the column
# set, defaults, COLLATE "C" and CHECK set are copied unchanged from CreateLedgerTables, and the
# triggers of CreateLedgerTriggers are re-created on the parents with `ledger_id` terms in every leg
# and reversal lookup, so each lookup touches one partition. There is no DEFAULT partition: a ledger
# id without partitions is refused by the insert itself.
#
# REFUSES TO RUN WHEN A LEDGER TABLE HOLDS A ROW (up and down alike): the tables are append-only and
# are dropped and re-created here, never converted. One fixed text, no value in it. On QA and in
# tests the tables are empty (no production caller builds a Capability yet).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# Letflow.TenantProvisioning's manifest. The only interpolated value is the trusted `prefix()` schema
# name, quoted as an identifier (INV-7); every other piece of SQL is fixed text. Function bodies name
# no schema (`format('%I', TG_TABLE_SCHEMA)`, values bound by USING).
#
# down/0 refuses unless `:allow_ledger_migration_down` is true (dev/test only), refuses when a row
# exists, drops the four tables and restores the earlier shape by calling the `up/0` of
# CreateLedgerTables, CreateLedgerTriggers and CreateLedgerPerLedgerIdKeys.
defmodule Letflow.Repo.Migrations.CreateLedgerPartitionedTables do
  use Ecto.Migration

  alias Letflow.Repo.Migrations.CreateLedgerPerLedgerIdKeys
  alias Letflow.Repo.Migrations.CreateLedgerTables
  alias Letflow.Repo.Migrations.CreateLedgerTriggers

  @id_form "COL ~ '^[a-z0-9_]{1,32}(:[a-z0-9-]{1,32})?$' AND octet_length(COL) <= 64"
  @hex64 "COL ~ '^[0-9a-f]{64}$'"
  @token "COL ~ '^[a-z0-9._:-]+$' AND octet_length(COL) <= 128"
  @noctl "COL !~ '[[:cntrl:]]'"

  def up do
    if prefix() do
      schema = prefix()
      refuse_if_rows!(schema, "CreateLedgerPartitionedTables.up refused")

      drop_all(schema)

      execute(counter_sql(schema))
      execute(entry_sql(schema))
      execute(leg_sql(schema))
      execute(balance_sql(schema))
      for sql <- index_sql(schema), do: execute(sql)

      for sql <- functions(schema) ++ triggers(schema), do: execute(sql)
    end
  end

  def down do
    unless Application.get_env(:letflow, :allow_ledger_migration_down, false) == true do
      raise "ledger tables are append-only: CreateLedgerPartitionedTables.down refused " <>
              "(set :allow_ledger_migration_down for dev/test only)"
    end

    if prefix() do
      schema = prefix()
      refuse_if_rows!(schema, "CreateLedgerPartitionedTables.down refused")

      drop_all(schema)

      CreateLedgerTables.up()
      CreateLedgerTriggers.up()
      CreateLedgerPerLedgerIdKeys.up()
    end
  end

  # One statement, run now (not queued): `execute/1` is queued by the runner, this check must
  # come before any DDL. The message is fixed text; no value is echoed.
  defp refuse_if_rows!(schema, what) do
    sql =
      "SELECT (EXISTS (SELECT 1 FROM \"#{schema}\".ledger_counter) " <>
        "OR EXISTS (SELECT 1 FROM \"#{schema}\".ledger_entry) " <>
        "OR EXISTS (SELECT 1 FROM \"#{schema}\".ledger_leg) " <>
        "OR EXISTS (SELECT 1 FROM \"#{schema}\".ledger_balance))"

    %{rows: [[has_rows]]} = repo().query!(sql)

    if has_rows do
      raise "ledger tables hold rows: " <> what
    end
  end

  # balance, leg, entry, counter: the leg references the entry, the entry references itself.
  defp drop_all(schema) do
    for table <- ~w(ledger_balance ledger_leg ledger_entry ledger_counter) do
      execute(~s|DROP TABLE IF EXISTS "#{schema}".#{table}|)
    end
  end

  # -- fragments (fixed text; COL is replaced by a fixed column name) --------------------------------

  defp id_form(col), do: String.replace(@id_form, "COL", col)
  defp hex64(col), do: String.replace(@hex64, "COL", col)
  defp token(col), do: String.replace(@token, "COL", col)
  defp noctl(col), do: String.replace(@noctl, "COL", col)
  defp oct(col, n), do: "octet_length(" <> col <> ") <= " <> Integer.to_string(n)
  defp text_ok(col, n), do: oct(col, n) <> " AND " <> noctl(col)

  defp chk(table, name, expr),
    do: "CONSTRAINT " <> table <> "_" <> name <> "_check CHECK (" <> expr <> ")"

  defp ks, do: Enum.map(1..8, &("k" <> Integer.to_string(&1)))

  defp body(defs), do: Enum.join(defs, ",\n  ")

  # -- tables ----------------------------------------------------------------------------------------

  defp counter_sql(schema) do
    defs = [
      "ledger_id text PRIMARY KEY",
      "last_seq bigint NOT NULL",
      "last_chain_hash text NOT NULL",
      chk("ledger_counter", "ledger_id", id_form("ledger_id")),
      chk("ledger_counter", "last_seq", "last_seq >= 0"),
      chk(
        "ledger_counter",
        "last_chain_hash",
        "last_chain_hash = '' OR " <> hex64("last_chain_hash")
      )
    ]

    ~s(CREATE TABLE "#{schema}".ledger_counter (\n  ) <> body(defs) <> "\n)"
  end

  defp entry_sql(schema) do
    t = "ledger_entry"

    defs = [
      "id uuid NOT NULL",
      "ledger_id text NOT NULL",
      "posting_seq bigint NOT NULL",
      "cause text NOT NULL",
      "sign_rule text NOT NULL",
      "reverses_entry_id uuid",
      "reason_code text",
      "document_type text",
      "document_id text",
      "related_document_id text",
      "actor_id uuid NOT NULL",
      "subject_id uuid NOT NULL",
      "correlation_id text NOT NULL",
      "bpm_instance_id uuid",
      "bpm_task_id uuid",
      "bpm_definition_id uuid",
      "bpm_node_id text",
      "bpm_definition_version text",
      "event_time timestamptz NOT NULL",
      "posting_time timestamptz NOT NULL",
      "client_op_id text NOT NULL",
      "origin_key text NOT NULL",
      "payload_hash text NOT NULL",
      "entry_digest text NOT NULL",
      "chain_hash text NOT NULL",
      "registration_hash text NOT NULL",
      "device_id text",
      "client_seq bigint",
      "client_event_time timestamptz",
      "scope_ref text",
      "leg_count smallint NOT NULL",
      chk(t, "ledger_id", id_form("ledger_id")),
      chk(t, "posting_seq", "posting_seq >= 1"),
      chk(t, "cause", "octet_length(cause) BETWEEN 1 AND 64 AND " <> noctl("cause")),
      chk(
        t,
        "sign_rule",
        "sign_rule IN ('positive', 'negative', 'zero_sum_by_slot_1', 'any', 'reversal')"
      ),
      chk(t, "reversal", "(cause = 'reversal') = (reverses_entry_id IS NOT NULL)"),
      chk(t, "reason_code", text_ok("reason_code", 64)),
      chk(t, "document_type", text_ok("document_type", 128)),
      chk(t, "document_id", text_ok("document_id", 128)),
      chk(t, "related_document_id", text_ok("related_document_id", 128)),
      chk(t, "correlation_id", text_ok("correlation_id", 128)),
      chk(t, "bpm_node_id", text_ok("bpm_node_id", 128)),
      chk(t, "bpm_definition_version", text_ok("bpm_definition_version", 64)),
      chk(
        t,
        "client_op_id",
        "octet_length(client_op_id) BETWEEN 1 AND 128 AND " <> noctl("client_op_id")
      ),
      chk(
        t,
        "origin_key",
        "octet_length(origin_key) BETWEEN 1 AND 200 AND " <> noctl("origin_key")
      ),
      chk(t, "payload_hash", hex64("payload_hash")),
      chk(t, "entry_digest", hex64("entry_digest")),
      chk(t, "chain_hash", hex64("chain_hash")),
      chk(t, "registration_hash", hex64("registration_hash")),
      chk(t, "device_id", oct("device_id", 64) <> " AND device_id ~ '^[A-Za-z0-9._:-]+$'"),
      chk(t, "client_seq", "client_seq >= 0"),
      chk(t, "device_seq", "(device_id IS NULL) = (client_seq IS NULL)"),
      chk(t, "client_event_time", "client_event_time IS NULL OR device_id IS NOT NULL"),
      chk(t, "scope_ref", text_ok("scope_ref", 128)),
      chk(t, "leg_count", "leg_count BETWEEN 1 AND 200"),
      "CONSTRAINT ledger_entry_ledger_seq_key UNIQUE (ledger_id, posting_seq)",
      "PRIMARY KEY (id, ledger_id)",
      "CONSTRAINT ledger_entry_subject_op_key UNIQUE (ledger_id, subject_id, client_op_id)",
      "CONSTRAINT ledger_entry_origin_key_key UNIQUE (ledger_id, origin_key)",
      "CONSTRAINT ledger_entry_leg_target_key UNIQUE (id, ledger_id, posting_seq, event_time)",
      ~s|CONSTRAINT ledger_entry_reverses_entry_id_fkey FOREIGN KEY (reverses_entry_id, ledger_id) | <>
        ~s|REFERENCES "#{schema}".ledger_entry (id, ledger_id)|
    ]

    ~s(CREATE TABLE "#{schema}".ledger_entry (\n  ) <>
      body(defs) <> "\n) PARTITION BY LIST (ledger_id)"
  end

  defp leg_sql(schema) do
    t = "ledger_leg"

    k_defs = Enum.map(ks(), &(&1 <> ~s| text COLLATE "C" NOT NULL DEFAULT ''|))
    k_checks = Enum.map(ks(), &chk(t, &1, text_ok(&1, 128)))

    defs =
      [
        "id uuid NOT NULL",
        "entry_id uuid NOT NULL",
        "ledger_id text NOT NULL",
        "posting_seq bigint NOT NULL",
        "event_time timestamptz NOT NULL",
        "leg_no smallint NOT NULL"
      ] ++
        k_defs ++
        [
          "quantity numeric(30,9) NOT NULL",
          "unit_ref text NOT NULL",
          "attrs jsonb",
          "document_line_id text",
          "quantity_scale smallint NOT NULL",
          "quantity_original numeric(30,9)",
          "original_unit_ref text",
          "original_scale smallint",
          "conversion_factor numeric(30,12)",
          "conversion_basis text",
          "rounding_mode text",
          "reference_quantity numeric(30,9)",
          "tolerance_abs numeric(30,9)",
          "tolerance_state text",
          "exception_ref text",
          ~s|CONSTRAINT ledger_leg_entry_fk FOREIGN KEY (entry_id, ledger_id, posting_seq, event_time) | <>
            ~s|REFERENCES "#{schema}".ledger_entry (id, ledger_id, posting_seq, event_time)|,
          "PRIMARY KEY (id, ledger_id)",
          "CONSTRAINT ledger_leg_entry_leg_no_key UNIQUE (ledger_id, entry_id, leg_no)",
          chk(t, "ledger_id", id_form("ledger_id")),
          chk(t, "leg_no", "leg_no BETWEEN 1 AND 200"),
          chk(t, "k1_present", "k1 <> ''")
        ] ++
        k_checks ++
        [
          chk(t, "quantity", "quantity <> 0"),
          chk(t, "unit_ref", token("unit_ref")),
          chk(t, "attrs", "octet_length(attrs::text) <= 4096"),
          chk(t, "document_line_id", text_ok("document_line_id", 128)),
          chk(t, "quantity_scale", "quantity_scale BETWEEN 0 AND 9"),
          chk(t, "quantity_original", "quantity_original <> 0"),
          chk(t, "original_unit_ref", token("original_unit_ref")),
          chk(t, "original_scale", "original_scale BETWEEN 0 AND 9"),
          chk(t, "conversion_factor", "conversion_factor > 0"),
          chk(t, "conversion_basis", "conversion_basis IN ('registered', 'command')"),
          chk(
            t,
            "rounding_mode",
            "rounding_mode IN ('half_up', 'half_even', 'half_down', 'up', 'down')"
          ),
          chk(t, "reference_quantity", "reference_quantity > 0"),
          chk(t, "tolerance_abs", "tolerance_abs >= 0"),
          chk(t, "tolerance_state", "tolerance_state IN ('within', 'excepted')"),
          chk(t, "exception_ref", token("exception_ref")),
          chk(t, "quantity_round", "quantity = round(quantity, quantity_scale::integer)"),
          chk(t, "original_sign", "sign(quantity_original) = sign(quantity)"),
          chk(t, "original_unit_differs", "original_unit_ref <> unit_ref"),
          chk(
            t,
            "original_round",
            "quantity_original = round(quantity_original, original_scale::integer)"
          ),
          chk(
            t,
            "conversion_group",
            "num_nonnulls(quantity_original, original_unit_ref, original_scale, " <>
              "conversion_factor, conversion_basis, rounding_mode) IN (0, 6)"
          ),
          chk(
            t,
            "tolerance_group",
            "num_nonnulls(reference_quantity, tolerance_abs, tolerance_state) IN (0, 3)"
          ),
          chk(
            t,
            "exception_state",
            "(exception_ref IS NOT NULL) = (tolerance_state IS NOT DISTINCT FROM 'excepted')"
          ),
          chk(
            t,
            "within_tolerance",
            "tolerance_state IS DISTINCT FROM 'within' OR " <>
              "abs(abs(quantity) - reference_quantity) <= tolerance_abs"
          ),
          chk(
            t,
            "excepted_tolerance",
            "tolerance_state IS DISTINCT FROM 'excepted' OR " <>
              "abs(abs(quantity) - reference_quantity) > tolerance_abs"
          ),
          chk(
            t,
            "conversion_tripwire",
            "quantity_original IS NULL OR " <>
              "abs(abs(quantity_original) * conversion_factor - abs(quantity)) * " <>
              "power(10::numeric, quantity_scale::numeric) < 1"
          )
        ]

    ~s(CREATE TABLE "#{schema}".ledger_leg (\n  ) <>
      body(defs) <> "\n) PARTITION BY LIST (ledger_id)"
  end

  defp balance_sql(schema) do
    t = "ledger_balance"

    defs =
      ["ledger_id text NOT NULL"] ++
        Enum.map(ks(), &(&1 <> ~s| text COLLATE "C" NOT NULL DEFAULT ''|)) ++
        [
          "on_hand numeric(30,9) NOT NULL",
          "unit_ref text NOT NULL",
          "max_on_hand numeric(30,9)",
          "last_posting_seq bigint NOT NULL",
          "updated_at timestamptz",
          "PRIMARY KEY (ledger_id, " <> Enum.join(ks(), ", ") <> ")",
          chk(t, "ledger_id", id_form("ledger_id"))
        ] ++
        Enum.map(ks(), &chk(t, &1, text_ok(&1, 128))) ++
        [
          chk(t, "on_hand", "on_hand >= 0"),
          chk(t, "unit_ref", token("unit_ref")),
          chk(t, "max_on_hand", "on_hand <= max_on_hand")
        ]

    ~s(CREATE TABLE "#{schema}".ledger_balance (\n  ) <>
      body(defs) <> "\n) PARTITION BY LIST (ledger_id)"
  end

  # -- indexes ---------------------------------------------------------------------------------------

  defp index_sql(schema) do
    [
      ~s|CREATE UNIQUE INDEX ledger_entry_reverses_unique_index ON "#{schema}".ledger_entry (ledger_id, reverses_entry_id) | <>
        "WHERE reverses_entry_id IS NOT NULL",
      ~s(CREATE UNIQUE INDEX ledger_entry_device_seq_unique_index ON "#{schema}".ledger_entry ) <>
        "(ledger_id, subject_id, device_id, client_seq) WHERE device_id IS NOT NULL",
      ~s(CREATE INDEX ledger_entry_ledger_event_index ON "#{schema}".ledger_entry ) <>
        "(ledger_id, event_time, posting_seq)",
      ~s|CREATE INDEX ledger_entry_document_index ON "#{schema}".ledger_entry (document_type, document_id)|,
      ~s|CREATE INDEX ledger_entry_bpm_task_index ON "#{schema}".ledger_entry (bpm_task_id)|,
      ~s|CREATE INDEX ledger_entry_correlation_index ON "#{schema}".ledger_entry (correlation_id)|,
      ~s(CREATE INDEX ledger_leg_k1_k2_index ON "#{schema}".ledger_leg ) <>
        "(ledger_id, k1, k2, posting_seq) INCLUDE (quantity)",
      ~s|CREATE INDEX ledger_leg_k2_k1_index ON "#{schema}".ledger_leg (ledger_id, k2, k1, posting_seq)|,
      ~s(CREATE INDEX ledger_leg_k1_k2_event_index ON "#{schema}".ledger_leg ) <>
        "(ledger_id, k1, k2, event_time, posting_seq)",
      ~s|CREATE INDEX ledger_balance_k2_k1_index ON "#{schema}".ledger_balance (ledger_id, k2, k1)|
    ]
  end

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
          EXECUTE format('SELECT ledger_id, reverses_entry_id FROM %I.ledger_entry WHERE id = $1 AND ledger_id = $2', TG_TABLE_SCHEMA)
            INTO target_ledger, target_reverses USING NEW.reverses_entry_id, NEW.ledger_id;

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
        EXECUTE format('SELECT count(*) FROM %I.ledger_leg WHERE entry_id = $1 AND ledger_id = $2', TG_TABLE_SCHEMA)
          INTO leg_total USING NEW.id, NEW.ledger_id;

        IF leg_total <> NEW.leg_count THEN
          RAISE EXCEPTION 'ledger entry leg count rule violated'
            USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
        END IF;

        bad := 0;

        IF NEW.sign_rule = 'positive' THEN
          EXECUTE format('SELECT count(*) FROM %I.ledger_leg WHERE entry_id = $1 AND ledger_id = $2 AND quantity <= 0', TG_TABLE_SCHEMA)
            INTO bad USING NEW.id, NEW.ledger_id;
        ELSIF NEW.sign_rule = 'negative' THEN
          EXECUTE format('SELECT count(*) FROM %I.ledger_leg WHERE entry_id = $1 AND ledger_id = $2 AND quantity >= 0', TG_TABLE_SCHEMA)
            INTO bad USING NEW.id, NEW.ledger_id;
        ELSIF NEW.sign_rule = 'zero_sum_by_slot_1' THEN
          EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM %I.ledger_leg WHERE entry_id = $1 AND ledger_id = $2 GROUP BY k1 HAVING sum(quantity) <> 0) g', TG_TABLE_SCHEMA)
            INTO bad USING NEW.id, NEW.ledger_id;
        END IF;

        IF bad > 0 THEN
          RAISE EXCEPTION 'ledger entry sign rule violated'
            USING ERRCODE = 'restrict_violation', SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME;
        END IF;

        IF NEW.reverses_entry_id IS NOT NULL THEN
          EXECUTE format(
            'SELECT count(*) FROM '
            || '(SELECT k1, k2, k3, k4, k5, k6, k7, k8, sum(quantity) AS q FROM %1$I.ledger_leg WHERE entry_id = $1 AND ledger_id = $3 GROUP BY k1, k2, k3, k4, k5, k6, k7, k8) a '
            || 'FULL JOIN '
            || '(SELECT k1, k2, k3, k4, k5, k6, k7, k8, sum(quantity) AS q FROM %1$I.ledger_leg WHERE entry_id = $2 AND ledger_id = $3 GROUP BY k1, k2, k3, k4, k5, k6, k7, k8) b '
            || 'USING (k1, k2, k3, k4, k5, k6, k7, k8) '
            || 'WHERE a.q IS NULL OR b.q IS NULL OR a.q + b.q <> 0',
            TG_TABLE_SCHEMA)
            INTO bad USING NEW.id, NEW.reverses_entry_id, NEW.ledger_id;

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
