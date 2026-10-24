# Letflow.Repo.Migrations.AddDocumentRetentionAndHold
#
# REQ-508 / GH #2675, part (a) (decision 0063 S3, S4, S5). Adds the retention policy columns
# to document_types, the hold columns to documents, their CHECKs, and replaces
# guard_document_types() so that exactly the three policy columns may change once a document
# of the type exists. guard_documents() and guard_document_versions() are not changed.
#
# Existing rows: every ADD COLUMN has a constant (or NULL) default, a catalog-only change in
# PostgreSQL 11+, so no row is rewritten and no row trigger fires. Existing types read
# NULL / 'issued' / 'keep'; existing documents read on_hold = false with NULL hold columns.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY (see the manifest in
# Letflow.TenantProvisioning).
defmodule Letflow.Repo.Migrations.AddDocumentRetentionAndHold do
  use Ecto.Migration

  @policy_columns ~w(retention_period_days retention_from retention_action)

  def up do
    if prefix() do
      schema = prefix()

      for sql <- columns(schema) ++ checks(schema) ++ [guard_function(schema)], do: execute(sql)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(original_guard_function(schema))

      for name <- ~w(document_types_retention_period_chk document_types_retention_from_chk
                     document_types_retention_action_chk document_types_retention_tie_chk) do
        execute(~s(ALTER TABLE "#{schema}".document_types DROP CONSTRAINT IF EXISTS #{name}))
      end

      for name <- ~w(documents_hold_on_hold_chk documents_hold_set_side_chk
                     documents_hold_clear_side_chk documents_hold_cleared_needs_set_chk) do
        execute(~s(ALTER TABLE "#{schema}".documents DROP CONSTRAINT IF EXISTS #{name}))
      end

      execute(
        ~s(ALTER TABLE "#{schema}".document_types ) <>
          Enum.map_join(@policy_columns, ", ", &"DROP COLUMN IF EXISTS #{&1}")
      )

      execute(
        ~s(ALTER TABLE "#{schema}".documents ) <>
          Enum.map_join(
            ~w(on_hold hold_set_at hold_set_by hold_reason_code hold_reason_note
               hold_cleared_at hold_cleared_by hold_clear_reason_code hold_clear_reason_note),
            ", ",
            &"DROP COLUMN IF EXISTS #{&1}"
          )
      )
    end
  end

  defp columns(schema) do
    [
      """
      ALTER TABLE "#{schema}".document_types
        ADD COLUMN retention_period_days integer NULL,
        ADD COLUMN retention_from text NOT NULL DEFAULT 'issued',
        ADD COLUMN retention_action text NOT NULL DEFAULT 'keep'
      """,
      """
      ALTER TABLE "#{schema}".documents
        ADD COLUMN on_hold boolean NOT NULL DEFAULT false,
        ADD COLUMN hold_set_at timestamptz NULL,
        ADD COLUMN hold_set_by uuid NULL,
        ADD COLUMN hold_reason_code text NULL,
        ADD COLUMN hold_reason_note text NULL,
        ADD COLUMN hold_cleared_at timestamptz NULL,
        ADD COLUMN hold_cleared_by uuid NULL,
        ADD COLUMN hold_clear_reason_code text NULL,
        ADD COLUMN hold_clear_reason_note text NULL
      """
    ]
  end

  defp checks(schema) do
    [
      ~s|ALTER TABLE "#{schema}".document_types ADD CONSTRAINT document_types_retention_period_chk CHECK (retention_period_days IS NULL OR retention_period_days > 0)|,
      ~s|ALTER TABLE "#{schema}".document_types ADD CONSTRAINT document_types_retention_from_chk CHECK (retention_from IN ('issued', 'superseded_or_cancelled'))|,
      ~s|ALTER TABLE "#{schema}".document_types ADD CONSTRAINT document_types_retention_action_chk CHECK (retention_action IN ('keep', 'archive', 'purge'))|,
      ~s|ALTER TABLE "#{schema}".document_types ADD CONSTRAINT document_types_retention_tie_chk CHECK ((retention_period_days IS NULL) = (retention_action = 'keep'))|,
      ~s|ALTER TABLE "#{schema}".documents ADD CONSTRAINT documents_hold_on_hold_chk CHECK (on_hold = (hold_set_at IS NOT NULL AND hold_cleared_at IS NULL))|,
      ~s|ALTER TABLE "#{schema}".documents ADD CONSTRAINT documents_hold_set_side_chk CHECK ((hold_set_at IS NULL) = (hold_set_by IS NULL) AND (hold_set_at IS NULL) = (hold_reason_code IS NULL) AND (hold_set_at IS NULL) = (hold_reason_note IS NULL))|,
      ~s|ALTER TABLE "#{schema}".documents ADD CONSTRAINT documents_hold_clear_side_chk CHECK ((hold_cleared_at IS NULL) = (hold_cleared_by IS NULL) AND (hold_cleared_at IS NULL) = (hold_clear_reason_code IS NULL) AND (hold_cleared_at IS NULL) = (hold_clear_reason_note IS NULL))|,
      ~s|ALTER TABLE "#{schema}".documents ADD CONSTRAINT documents_hold_cleared_needs_set_chk CHECK (hold_cleared_at IS NULL OR hold_set_at IS NOT NULL)|
    ]
  end

  # The type stays frozen once a document of its key exists, except the three policy
  # columns (decision 0063 S3). The message text is the one of the original function.
  defp guard_function(schema) do
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
        IF (to_jsonb(OLD) - ARRAY['retention_period_days', 'retention_from', 'retention_action'])
           IS DISTINCT FROM
           (to_jsonb(NEW) - ARRAY['retention_period_days', 'retention_from', 'retention_action']) THEN
          RAISE EXCEPTION 'document type is frozen once a document of that type exists'
            USING ERRCODE = 'restrict_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """
  end

  defp original_guard_function(schema) do
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
    """
  end
end
