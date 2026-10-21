# Letflow.Repo.Migrations.CreateDocumentImmutabilityTriggers
#
# REQ-500 / GH #2588, PR A -- the database-level immutability of the document tables
# (decision 0056 D4). Design: state/tasks/T-0077/design.md sections 4 (D-8, D-9, D-10,
# D-13, D-14) and 7 (trigger table).
#
# Every trigger is created `ENABLE ALWAYS`, so it also fires when a session sets
# `session_replication_role = replica`. Only a role that may set that parameter could
# bypass the default `ENABLE ORIGIN` behaviour; `ENABLE ALWAYS` closes that path for
# the document tables (triggers_test.exs A-1 and A-2 check it).
#
# Every statement that changes an issued document is refused here, whatever the
# caller: the context (PR B) is one writer, not the only guard. Trigger functions are
# schema-qualified and carry fixed messages: no field value is echoed (INV-2), and no
# SQL is built from request data (INV-7).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY (see the
# manifest in Letflow.TenantProvisioning).
defmodule Letflow.Repo.Migrations.CreateDocumentImmutabilityTriggers do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      for sql <- functions(schema) ++ triggers(schema), do: execute(sql)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      for {table, name, _timing, _level, _fun} <- trigger_specs() do
        execute(~s(DROP TRIGGER IF EXISTS #{name} ON "#{schema}"."#{table}"))
      end

      for fun <-
            ~w(document_refuse guard_document_versions guard_documents guard_document_types guard_document_sequences) do
        execute(~s|DROP FUNCTION IF EXISTS "#{schema}"."#{fun}"()|)
      end
    end
  end

  # One row per trigger: {table, trigger name, timing and event, level, function}.
  # The trigger name is the table's own name plus a suffix; the function is shared by
  # the triggers that enforce the same rule.
  defp trigger_specs do
    [
      {"document_types", "document_types_guard_update", "BEFORE UPDATE", "ROW",
       "guard_document_types"},
      {"document_types", "document_types_guard_delete", "BEFORE DELETE", "ROW",
       "document_refuse"},
      {"document_types", "document_types_guard_truncate", "BEFORE TRUNCATE", "STATEMENT",
       "document_refuse"},
      {"documents", "documents_guard_update", "BEFORE UPDATE", "ROW", "guard_documents"},
      {"documents", "documents_guard_delete", "BEFORE DELETE", "ROW", "document_refuse"},
      {"documents", "documents_guard_truncate", "BEFORE TRUNCATE", "STATEMENT",
       "document_refuse"},
      {"document_versions", "document_versions_guard_update", "BEFORE UPDATE", "ROW",
       "guard_document_versions"},
      {"document_versions", "document_versions_guard_delete", "BEFORE DELETE", "ROW",
       "document_refuse"},
      {"document_versions", "document_versions_guard_truncate", "BEFORE TRUNCATE", "STATEMENT",
       "document_refuse"},
      {"document_sequences", "document_sequences_guard_update", "BEFORE UPDATE", "ROW",
       "guard_document_sequences"},
      {"document_sequences", "document_sequences_guard_delete", "BEFORE DELETE", "ROW",
       "document_refuse"},
      {"document_sequences", "document_sequences_guard_truncate", "BEFORE TRUNCATE", "STATEMENT",
       "document_refuse"},
      {"document_external_registrations", "document_external_registrations_guard_update",
       "BEFORE UPDATE", "ROW", "document_refuse"},
      {"document_external_registrations", "document_external_registrations_guard_delete",
       "BEFORE DELETE", "ROW", "document_refuse"},
      {"document_external_registrations", "document_external_registrations_guard_truncate",
       "BEFORE TRUNCATE", "STATEMENT", "document_refuse"}
    ]
  end

  defp functions(schema) do
    [
      """
      CREATE OR REPLACE FUNCTION "#{schema}".document_refuse() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'document data is immutable: this statement is refused'
          USING ERRCODE = 'restrict_violation';
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".guard_document_versions() RETURNS trigger AS $$
      DECLARE
        allowed text[];
      BEGIN
        -- D-8: the only transitions, each with the columns it may change. Every other
        -- pair (including any change from discarded, superseded or cancelled) is refused.
        IF OLD.status = 'draft' AND NEW.status = 'draft' THEN
          allowed := ARRAY['content'];
        ELSIF OLD.status = 'draft' AND NEW.status = 'issued' THEN
          allowed := ARRAY['status', 'issued_at', 'issued_by', 'content_hash'];
        ELSIF OLD.status = 'draft' AND NEW.status = 'discarded' THEN
          allowed := ARRAY['status', 'discarded_at', 'discarded_by'];
        ELSIF OLD.status = 'issued' AND NEW.status = 'superseded' THEN
          allowed := ARRAY['status', 'superseded_by_version'];
        ELSIF OLD.status = 'issued' AND NEW.status = 'cancelled' THEN
          allowed := ARRAY['status', 'cancelled_at', 'cancelled_by', 'cancel_reason'];
        ELSE
          RAISE EXCEPTION 'document version transition is not allowed'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF (to_jsonb(OLD) - allowed) IS DISTINCT FROM (to_jsonb(NEW) - allowed) THEN
          RAISE EXCEPTION 'document version field is immutable for this transition'
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".guard_documents() RETURNS trigger AS $$
      DECLARE
        hit boolean;
      BEGIN
        -- The checks below read a sibling table through TG_TABLE_SCHEMA, never a literal
        -- schema name: tenant schemas are built from a template build schema, and a body
        -- that named a schema kept pointing at that build schema once copied.
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
           OR NEW.id IS DISTINCT FROM OLD.id
           OR NEW.type_key IS DISTINCT FROM OLD.type_key
           OR NEW.issuing_org_unit_id IS DISTINCT FROM OLD.issuing_org_unit_id THEN
          RAISE EXCEPTION 'document identity fields are immutable'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF OLD.number IS NOT NULL AND NEW.number IS DISTINCT FROM OLD.number THEN
          RAISE EXCEPTION 'document number is immutable once set' USING ERRCODE = 'restrict_violation';
        END IF;

        IF OLD.period IS NOT NULL AND NEW.period IS DISTINCT FROM OLD.period THEN
          RAISE EXCEPTION 'document period is immutable once set' USING ERRCODE = 'restrict_violation';
        END IF;

        IF OLD.legal_entity_id IS NOT NULL AND NEW.legal_entity_id IS DISTINCT FROM OLD.legal_entity_id THEN
          RAISE EXCEPTION 'document legal entity is immutable once set'
            USING ERRCODE = 'restrict_violation';
        END IF;

        -- Number, period and legal entity are set only together with an issue: a NULL
        -- to value change needs an issued version of the document to exist.
        IF (OLD.number IS NULL AND NEW.number IS NOT NULL)
           OR (OLD.period IS NULL AND NEW.period IS NOT NULL)
           OR (OLD.legal_entity_id IS NULL AND NEW.legal_entity_id IS NOT NULL) THEN
          EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %I.document_versions v WHERE v.document_id = $1 AND v.status = ''issued'')',
            TG_TABLE_SCHEMA
          ) INTO hit USING OLD.id;

          IF NOT hit THEN
            RAISE EXCEPTION 'document number is set only by an issue' USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;

        IF NEW.source_ref IS DISTINCT FROM OLD.source_ref THEN
          EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %I.document_versions v WHERE v.document_id = $1 AND v.status <> ''draft'')',
            TG_TABLE_SCHEMA
          ) INTO hit USING OLD.id;
        ELSE
          hit := false;
        END IF;

        IF hit THEN
          RAISE EXCEPTION 'document source reference is frozen after the first issue'
            USING ERRCODE = 'restrict_violation';
        END IF;

        -- D-10: current_version moves only to an issued version of this document. It
        -- is not re-checked when that version is cancelled later, so the pointer stays.
        IF NEW.current_version IS DISTINCT FROM OLD.current_version THEN
          IF NEW.current_version IS NULL THEN
            RAISE EXCEPTION 'document current version cannot be cleared'
              USING ERRCODE = 'restrict_violation';
          END IF;

          EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %I.document_versions v WHERE v.id = $1 AND v.document_id = $2 AND v.status = ''issued'')',
            TG_TABLE_SCHEMA
          ) INTO hit USING NEW.current_version, OLD.id;

          IF NOT hit THEN
            RAISE EXCEPTION 'document current version must be an issued version of the document'
              USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".guard_document_types() RETURNS trigger AS $$
      DECLARE
        hit boolean;
      BEGIN
        EXECUTE format(
          'SELECT EXISTS (SELECT 1 FROM %I.documents d WHERE d.type_key = $1)',
          TG_TABLE_SCHEMA
        ) INTO hit USING OLD.key;

        IF hit THEN
          RAISE EXCEPTION 'document type is frozen once a document of that type exists'
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      """
      CREATE OR REPLACE FUNCTION "#{schema}".guard_document_sequences() RETURNS trigger AS $$
      BEGIN
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
           OR NEW.type_key IS DISTINCT FROM OLD.type_key
           OR NEW.legal_entity_key IS DISTINCT FROM OLD.legal_entity_key
           OR NEW.period IS DISTINCT FROM OLD.period THEN
          RAISE EXCEPTION 'document sequence identity fields are immutable'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.counter < OLD.counter THEN
          RAISE EXCEPTION 'document sequence counter cannot be lowered'
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """
    ]
  end

  # `ENABLE ALWAYS` follows each CREATE TRIGGER, so the trigger is never left in its
  # default `ENABLE ORIGIN` state, not even for the duration of this migration.
  defp triggers(schema) do
    Enum.flat_map(trigger_specs(), fn {table, name, timing, level, fun} ->
      [
        """
        CREATE TRIGGER #{name}
          #{timing} ON "#{schema}"."#{table}"
          FOR EACH #{level} EXECUTE FUNCTION "#{schema}"."#{fun}"()
        """,
        ~s(ALTER TABLE "#{schema}"."#{table}" ENABLE ALWAYS TRIGGER #{name})
      ]
    end)
  end
end
