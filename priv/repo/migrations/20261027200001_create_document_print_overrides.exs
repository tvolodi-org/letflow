# Letflow.Repo.Migrations.CreateDocumentPrintOverrides
#
# REQ-579 / GH #3289 (decision 0068 D3, D7, D8 S2), part 1 -- per-tenant print-layout overrides
# with a draft -> active -> retired lifecycle, one active row per (type_key, locale), and a
# database trigger that makes a saved layout immutable. The table starts empty: no existing row
# is altered.
#
# Q3 assumption (two-principal activation): `CHECK (activated_by <> created_by)`. Switching to a
# single-admin rule later needs a follow-up migration that drops this constraint.
#
# The triggers are modelled on `guard_document_versions` (20261022100002) and are created
# `ENABLE ALWAYS`, so they also fire under `session_replication_role = replica`. Messages are
# fixed: no value is echoed (INV-2).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateDocumentPrintOverrides do
  use Ecto.Migration

  def up do
    if prefix() do
      s = prefix()

      execute("""
      CREATE TABLE "#{s}".document_print_overrides (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        type_key text NOT NULL,
        locale text NOT NULL CHECK (locale IN ('ru', 'kk', 'default')),
        version_no integer NOT NULL CHECK (version_no >= 1),
        status text NOT NULL CHECK (status IN ('draft', 'active', 'retired')),
        layout jsonb NOT NULL,
        layout_hash text NOT NULL CHECK (layout_hash ~ '^[0-9a-f]{64}$'),
        layout_schema_version integer NOT NULL,
        created_by uuid NOT NULL,
        activated_by uuid,
        activated_at timestamptz,
        retired_at timestamptz,
        reason_code text,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT document_print_overrides_sod_chk CHECK (activated_by <> created_by)
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX document_print_overrides_version_index ON "#{s}".document_print_overrides (type_key, locale, version_no)|
      )

      execute(
        ~s|CREATE UNIQUE INDEX document_print_overrides_one_active_index ON "#{s}".document_print_overrides (type_key, locale) WHERE status = 'active'|
      )

      execute("""
      CREATE OR REPLACE FUNCTION "#{s}".guard_document_print_overrides() RETURNS trigger AS $$
      DECLARE
        allowed text[];
      BEGIN
        IF OLD.status = 'draft' AND NEW.status = 'draft' THEN
          allowed := ARRAY['layout', 'layout_hash', 'layout_schema_version', 'updated_at'];
        ELSIF OLD.status = 'draft' AND NEW.status = 'active' THEN
          allowed := ARRAY['status', 'activated_by', 'activated_at', 'reason_code', 'updated_at'];
        ELSIF OLD.status = 'active' AND NEW.status = 'retired' THEN
          allowed := ARRAY['status', 'retired_at', 'reason_code', 'updated_at'];
        ELSE
          RAISE EXCEPTION 'print override transition is not allowed'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF (to_jsonb(OLD) - allowed) IS DISTINCT FROM (to_jsonb(NEW) - allowed) THEN
          RAISE EXCEPTION 'print override field is immutable for this transition'
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """)

      execute("""
      CREATE OR REPLACE FUNCTION "#{s}".print_override_refuse() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'print override data is immutable: this statement is refused'
          USING ERRCODE = 'restrict_violation';
      END;
      $$ LANGUAGE plpgsql
      """)

      for {name, timing, level, fun} <- [
            {"document_print_overrides_guard_update", "BEFORE UPDATE", "ROW",
             "guard_document_print_overrides"},
            {"document_print_overrides_guard_delete", "BEFORE DELETE", "ROW",
             "print_override_refuse"},
            {"document_print_overrides_guard_truncate", "BEFORE TRUNCATE", "STATEMENT",
             "print_override_refuse"}
          ] do
        execute(
          ~s|CREATE TRIGGER #{name} #{timing} ON "#{s}".document_print_overrides FOR EACH #{level} EXECUTE FUNCTION "#{s}".#{fun}()|
        )

        execute(~s|ALTER TABLE "#{s}".document_print_overrides ENABLE ALWAYS TRIGGER #{name}|)
      end
    end
  end

  def down do
    if prefix() do
      s = prefix()
      execute(~s|DROP TABLE IF EXISTS "#{s}"."document_print_overrides"|)
      execute(~s|DROP FUNCTION IF EXISTS "#{s}"."guard_document_print_overrides"()|)
      execute(~s|DROP FUNCTION IF EXISTS "#{s}"."print_override_refuse"()|)
    end
  end
end
