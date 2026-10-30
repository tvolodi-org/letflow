# Letflow.Repo.Migrations.CreateLedgerTables
#
# REQ-620 / GH #3463 part A (WMS stock ledger L1; notes gh2657 sections 4.1-4.4, gh2660 section 4.5
# with amendments A1, A13, A26, A33) -- the four per-tenant ledger tables and their CHECK set:
# `ledger_counter`, `ledger_entry`, `ledger_leg`, `ledger_balance`. The tables are append-only in
# design and cannot be back-filled, so the column set and the CHECK set are complete here. No trigger,
# no function, no seed row (the immutability and balance triggers are part B).
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). NO `tenant_id` column: the tenant is the
# schema (decision 0006 D2). Exactly two foreign keys exist across the four tables: the self-reference
# `ledger_entry.reverses_entry_id` and the composite key from a leg to its header. `bpm_*` ids carry no
# foreign key (the ledger outlives the process rows).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# Letflow.TenantProvisioning's manifest (both halves are required). The only interpolated value is the
# trusted `prefix()` schema name, quoted as an identifier (INV-7); every other piece of SQL is fixed text.
#
# OPERATOR NOTE: the tables start empty and no existing row is altered. Existing tenants receive them
# through `replay_all_pending/0` after deploy. `down` drops append-only tables, so it refuses to run
# unless `:allow_ledger_migration_down` is true (set in config/dev.exs and config/test.exs only); there
# is no partial purge or restore of a ledger.
defmodule Letflow.Repo.Migrations.CreateLedgerTables do
  use Ecto.Migration

  @id_form "COL ~ '^[a-z0-9_]{1,32}(:[a-z0-9-]{1,32})?$' AND octet_length(COL) <= 64"
  @hex64 "COL ~ '^[0-9a-f]{64}$'"
  @token "COL ~ '^[a-z0-9._:-]+$' AND octet_length(COL) <= 128"
  @noctl "COL !~ '[[:cntrl:]]'"

  def up do
    if prefix() do
      schema = prefix()

      execute(counter_sql(schema))
      execute(entry_sql(schema))
      execute(leg_sql(schema))
      execute(balance_sql(schema))

      for sql <- index_sql(schema), do: execute(sql)
    end
  end

  def down do
    unless Application.get_env(:letflow, :allow_ledger_migration_down, false) == true do
      raise "ledger tables are append-only: CreateLedgerTables.down refused " <>
              "(set :allow_ledger_migration_down for dev/test only)"
    end

    if prefix() do
      schema = prefix()

      for table <- ~w(ledger_balance ledger_leg ledger_entry ledger_counter) do
        execute(~s|DROP TABLE IF EXISTS "#{schema}".#{table}|)
      end
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
      "id uuid PRIMARY KEY",
      "ledger_id text NOT NULL",
      "posting_seq bigint NOT NULL",
      "cause text NOT NULL",
      "sign_rule text NOT NULL",
      ~s|reverses_entry_id uuid REFERENCES "#{schema}".ledger_entry (id)|,
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
      "CONSTRAINT ledger_entry_subject_op_key UNIQUE (subject_id, client_op_id)",
      "CONSTRAINT ledger_entry_origin_key_key UNIQUE (origin_key)",
      "CONSTRAINT ledger_entry_leg_target_key UNIQUE (id, ledger_id, posting_seq, event_time)"
    ]

    ~s(CREATE TABLE "#{schema}".ledger_entry (\n  ) <> body(defs) <> "\n)"
  end

  defp leg_sql(schema) do
    t = "ledger_leg"

    k_defs = Enum.map(ks(), &(&1 <> ~s| text COLLATE "C" NOT NULL DEFAULT ''|))
    k_checks = Enum.map(ks(), &chk(t, &1, text_ok(&1, 128)))

    defs =
      [
        "id uuid PRIMARY KEY",
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
          "CONSTRAINT ledger_leg_entry_leg_no_key UNIQUE (entry_id, leg_no)",
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

    ~s(CREATE TABLE "#{schema}".ledger_leg (\n  ) <> body(defs) <> "\n)"
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

    ~s(CREATE TABLE "#{schema}".ledger_balance (\n  ) <> body(defs) <> "\n)"
  end

  # -- indexes ---------------------------------------------------------------------------------------

  defp index_sql(schema) do
    [
      ~s|CREATE UNIQUE INDEX ledger_entry_reverses_unique_index ON "#{schema}".ledger_entry (reverses_entry_id) | <>
        "WHERE reverses_entry_id IS NOT NULL",
      ~s(CREATE UNIQUE INDEX ledger_entry_device_seq_unique_index ON "#{schema}".ledger_entry ) <>
        "(subject_id, device_id, client_seq) WHERE device_id IS NOT NULL",
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
end
