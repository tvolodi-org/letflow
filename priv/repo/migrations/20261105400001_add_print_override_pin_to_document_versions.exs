# Letflow.Repo.Migrations.AddPrintOverridePinToDocumentVersions
#
# REQ-624 / GH #3485 (decision 0068 D8 S3, decision 0075 R6): an issued document version pins the
# tenant print override it was issued under. Four nullable columns on `document_versions`:
# `template_version`, `print_override_id`, `print_override_version`, `print_override_layout_hash`.
# NULL means "no override" (every version issued before this migration, and every version issued
# with no active override); nothing is back-filled.
#
# `guard_document_versions()` is replaced with the 20261105300001 body and exactly one change: the
# `draft -> issued` branch may also set the four columns. Every other transition still refuses
# them (the jsonb diff below), and `artefact_hash` NULL -> value on an issued row stays allowed.
# The triggers are not recreated, so their `ENABLE ALWAYS` state is kept. No foreign key: the
# overrides table refuses deletes by trigger, the pin is written only from a row read in the same
# transaction, and a pin that points at no row fails closed at render.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY (see the
# manifest in Letflow.TenantProvisioning).
defmodule Letflow.Repo.Migrations.AddPrintOverridePinToDocumentVersions do
  use Ecto.Migration

  def up do
    if prefix() do
      execute(
        ~s(ALTER TABLE "#{prefix()}".document_versions ADD COLUMN template_version text, ADD COLUMN print_override_id uuid, ADD COLUMN print_override_version integer, ADD COLUMN print_override_layout_hash text)
      )

      execute(function_sql(prefix(), true))
    end
  end

  def down do
    if prefix() do
      execute(function_sql(prefix(), false))

      execute(
        ~s(ALTER TABLE "#{prefix()}".document_versions DROP COLUMN template_version, DROP COLUMN print_override_id, DROP COLUMN print_override_version, DROP COLUMN print_override_layout_hash)
      )
    end
  end

  defp function_sql(schema, with_pin) do
    issued_columns =
      if with_pin do
        "ARRAY['status', 'issued_at', 'issued_by', 'content_hash', 'template_version', 'print_override_id', 'print_override_version', 'print_override_layout_hash']"
      else
        "ARRAY['status', 'issued_at', 'issued_by', 'content_hash']"
      end

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
        allowed := #{issued_columns};
      ELSIF OLD.status = 'draft' AND NEW.status = 'discarded' THEN
        allowed := ARRAY['status', 'discarded_at', 'discarded_by'];
      ELSIF OLD.status = 'issued' AND NEW.status = 'superseded' THEN
        allowed := ARRAY['status', 'superseded_by_version'];
      ELSIF OLD.status = 'issued' AND NEW.status = 'cancelled' THEN
        allowed := ARRAY['status', 'cancelled_at', 'cancelled_by', 'cancel_reason'];
      ELSIF OLD.status = 'issued' AND NEW.status = 'issued' THEN
        IF OLD.artefact_hash IS NULL AND NEW.artefact_hash ~ '^[0-9a-f]{64}$' THEN
          allowed := ARRAY['artefact_hash'];
        ELSE
          RAISE EXCEPTION 'document version transition is not allowed'
            USING ERRCODE = 'restrict_violation';
        END IF;
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
    """
  end
end
