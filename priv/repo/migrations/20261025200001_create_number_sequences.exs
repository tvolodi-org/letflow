# Letflow.Repo.Migrations.CreateNumberSequences
#
# REQ-541 / GH #3160 -- tenant-scoped number sequences bound to a record type. A new,
# small allocator (`Letflow.NumberSequences`) that follows the gap-free protocol of
# decision 0056 D2 (insert-if-absent, SELECT ... FOR UPDATE, increment) on its own tables;
# it neither reads nor writes `document_sequences`.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). Every table carries
# `tenant_id uuid NOT NULL` as well. The tables start empty: no existing row is altered and
# every existing entity type stays unbound.
#
# Guards (all `ENABLE ALWAYS`, fixed messages, no value echoed):
#   * a counter row is never lowered, never re-identified and never deleted;
#   * an allocation-log row is never updated or deleted (a number is never reused).
# There is deliberately NO truncate trigger: the test template reset truncates dirty tables.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateNumberSequences do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      for sql <- table_statements(schema) ++ functions(schema) ++ triggers(schema),
          do: execute(sql)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      for {table, name, _timing, _fun} <- trigger_specs() do
        execute(~s(DROP TRIGGER IF EXISTS #{name} ON "#{schema}"."#{table}"))
      end

      for fun <- ~w(guard_number_sequence_counters number_sequence_refuse) do
        execute(~s|DROP FUNCTION IF EXISTS "#{schema}"."#{fun}"()|)
      end

      for table <-
            ~w(number_sequence_numbers number_sequence_counters number_sequence_definitions) do
        execute(~s(DROP TABLE IF EXISTS "#{schema}"."#{table}"))
      end
    end
  end

  defp table_statements(schema) do
    [
      """
      CREATE TABLE "#{schema}".number_sequence_definitions (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        key text NOT NULL,
        entity_type text NOT NULL,
        prefix text NOT NULL CHECK (prefix ~ '^[A-Za-z0-9]{1,8}$'),
        padding integer NOT NULL CHECK (padding BETWEEN 1 AND 12),
        period text NOT NULL CHECK (period IN ('year', 'none')),
        inserted_at timestamptz NOT NULL
      )
      """,
      ~s|CREATE UNIQUE INDEX number_sequence_definitions_key_index ON "#{schema}".number_sequence_definitions (key)|,
      ~s|CREATE UNIQUE INDEX number_sequence_definitions_entity_type_index ON "#{schema}".number_sequence_definitions (entity_type)|,
      """
      CREATE TABLE "#{schema}".number_sequence_counters (
        tenant_id uuid NOT NULL,
        sequence_id uuid NOT NULL
          REFERENCES "#{schema}".number_sequence_definitions (id)
          ON UPDATE RESTRICT ON DELETE RESTRICT,
        period text NOT NULL,
        counter bigint NOT NULL DEFAULT 0 CHECK (counter >= 0),
        PRIMARY KEY (sequence_id, period)
      )
      """,
      """
      CREATE TABLE "#{schema}".number_sequence_numbers (
        tenant_id uuid NOT NULL,
        sequence_id uuid NOT NULL
          REFERENCES "#{schema}".number_sequence_definitions (id)
          ON UPDATE RESTRICT ON DELETE RESTRICT,
        period text NOT NULL,
        number bigint NOT NULL CHECK (number >= 1),
        entity_type text NOT NULL,
        record_id uuid NOT NULL,
        formatted text NOT NULL,
        PRIMARY KEY (entity_type, record_id)
      )
      """,
      ~s|CREATE UNIQUE INDEX number_sequence_numbers_seq_period_number_index ON "#{schema}".number_sequence_numbers (sequence_id, period, number)|
    ]
  end

  defp functions(schema) do
    [
      """
      CREATE OR REPLACE FUNCTION "#{schema}".number_sequence_refuse() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'number sequence data is immutable: this statement is refused'
          USING ERRCODE = 'restrict_violation';
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".guard_number_sequence_counters() RETURNS trigger AS $$
      BEGIN
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
           OR NEW.sequence_id IS DISTINCT FROM OLD.sequence_id
           OR NEW.period IS DISTINCT FROM OLD.period THEN
          RAISE EXCEPTION 'number sequence identity fields are immutable'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.counter < OLD.counter THEN
          RAISE EXCEPTION 'number sequence counter cannot be lowered'
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """
    ]
  end

  defp trigger_specs do
    [
      {"number_sequence_counters", "number_sequence_counters_guard_update", "BEFORE UPDATE",
       "guard_number_sequence_counters"},
      {"number_sequence_counters", "number_sequence_counters_guard_delete", "BEFORE DELETE",
       "number_sequence_refuse"},
      {"number_sequence_numbers", "number_sequence_numbers_guard_update", "BEFORE UPDATE",
       "number_sequence_refuse"},
      {"number_sequence_numbers", "number_sequence_numbers_guard_delete", "BEFORE DELETE",
       "number_sequence_refuse"},
      {"number_sequence_definitions", "number_sequence_definitions_guard_update", "BEFORE UPDATE",
       "number_sequence_refuse"},
      {"number_sequence_definitions", "number_sequence_definitions_guard_delete", "BEFORE DELETE",
       "number_sequence_refuse"}
    ]
  end

  # `ENABLE ALWAYS` follows each CREATE TRIGGER, as in the document triggers migration.
  defp triggers(schema) do
    Enum.flat_map(trigger_specs(), fn {table, name, timing, fun} ->
      [
        """
        CREATE TRIGGER #{name}
          #{timing} ON "#{schema}"."#{table}"
          FOR EACH ROW EXECUTE FUNCTION "#{schema}"."#{fun}"()
        """,
        ~s(ALTER TABLE "#{schema}"."#{table}" ENABLE ALWAYS TRIGGER #{name})
      ]
    end)
  end
end
