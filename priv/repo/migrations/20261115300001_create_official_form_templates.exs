# Letflow.Repo.Migrations.CreateOfficialFormTemplates
#
# T-1982 / decision 0089 D5, slice S4a -- per-tenant company templates (docx) of the official print
# forms, with a draft -> active -> retired lifecycle, one active row per (form_id, locale), and a
# database trigger that makes the stored bytes immutable. The table starts empty: no existing row
# is altered.
#
# The triggers are modelled on `20261027200001_create_document_print_overrides.exs` and are created
# `ENABLE ALWAYS`, so they also fire under `session_replication_role = replica`. Messages are
# fixed: no value is echoed (INV-2).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateOfficialFormTemplates do
  use Ecto.Migration

  def up do
    if prefix() do
      s = prefix()

      execute("""
      CREATE TABLE "#{s}".official_form_templates (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        form_id text NOT NULL CHECK (form_id ~ '^[a-z0-9]{2,8}$'),
        locale text NOT NULL CHECK (locale IN ('default', 'ru', 'kk')),
        version_no integer NOT NULL CHECK (version_no >= 1),
        status text NOT NULL CHECK (status IN ('draft', 'active', 'retired')),
        content bytea NOT NULL,
        byte_size integer NOT NULL,
        sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
        summary jsonb NOT NULL,
        rollback_of uuid REFERENCES "#{s}".official_form_templates (id),
        created_by uuid NOT NULL,
        activated_by uuid,
        activated_at timestamptz,
        retired_at timestamptz,
        reason_code text,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT official_form_templates_size_chk CHECK (byte_size = octet_length(content)),
        CONSTRAINT official_form_templates_active_chk
          CHECK (status <> 'active' OR (activated_by IS NOT NULL AND activated_at IS NOT NULL)),
        CONSTRAINT official_form_templates_retired_chk
          CHECK (status <> 'retired' OR retired_at IS NOT NULL)
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX official_form_templates_version_index ON "#{s}".official_form_templates (form_id, locale, version_no)|
      )

      execute(
        ~s|CREATE UNIQUE INDEX official_form_templates_one_active_index ON "#{s}".official_form_templates (form_id, locale) WHERE status = 'active'|
      )

      execute("""
      CREATE OR REPLACE FUNCTION "#{s}".guard_official_form_templates() RETURNS trigger AS $$
      DECLARE
        allowed text[];
      BEGIN
        IF OLD.status = 'draft' AND NEW.status = 'active' THEN
          allowed := ARRAY['status', 'activated_by', 'activated_at', 'reason_code', 'updated_at'];
        ELSIF (OLD.status = 'draft' OR OLD.status = 'active') AND NEW.status = 'retired' THEN
          allowed := ARRAY['status', 'retired_at', 'reason_code', 'updated_at'];
        ELSE
          RAISE EXCEPTION 'official form template transition is not allowed'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF (to_jsonb(OLD) - allowed) IS DISTINCT FROM (to_jsonb(NEW) - allowed) THEN
          RAISE EXCEPTION 'official form template field is immutable for this transition'
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """)

      execute("""
      CREATE OR REPLACE FUNCTION "#{s}".official_form_template_refuse() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'official form template data is immutable: this statement is refused'
          USING ERRCODE = 'restrict_violation';
      END;
      $$ LANGUAGE plpgsql
      """)

      for {name, timing, level, fun} <- [
            {"official_form_templates_guard_update", "BEFORE UPDATE", "ROW",
             "guard_official_form_templates"},
            {"official_form_templates_guard_delete", "BEFORE DELETE", "ROW",
             "official_form_template_refuse"},
            {"official_form_templates_guard_truncate", "BEFORE TRUNCATE", "STATEMENT",
             "official_form_template_refuse"}
          ] do
        execute(
          ~s|CREATE TRIGGER #{name} #{timing} ON "#{s}".official_form_templates FOR EACH #{level} EXECUTE FUNCTION "#{s}".#{fun}()|
        )

        execute(~s|ALTER TABLE "#{s}".official_form_templates ENABLE ALWAYS TRIGGER #{name}|)
      end
    end
  end

  def down do
    if prefix() do
      s = prefix()
      execute(~s|DROP TABLE IF EXISTS "#{s}"."official_form_templates"|)
      execute(~s|DROP FUNCTION IF EXISTS "#{s}"."guard_official_form_templates"()|)
      execute(~s|DROP FUNCTION IF EXISTS "#{s}"."official_form_template_refuse"()|)
    end
  end
end
