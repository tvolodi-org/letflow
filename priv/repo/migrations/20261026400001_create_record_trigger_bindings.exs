# Letflow.Repo.Migrations.CreateRecordTriggerBindings
#
# REQ-570 / GH #3248 (decision 0067 D4/D9, slice T-1) -- the pin of one published `entity_event`
# script version to one (entity type, event) pair: a record trigger. Nothing reads the table at run
# time yet and nothing is queued.
#
# Two changes in one file: the CHECK `script_rules_hook_kind` (last widened by
# 20261026300001) is widened to also allow 'entity_event'; and the binding table is created.
# Existing rows are all service_task, entity_write or form_validation and satisfy the wider CHECK;
# the table starts empty, so no existing row is altered. No foreign key (script_rules rows are never
# deleted; no reference to another tenant's data).
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
#
# `down` drops the table and restores the three-kind CHECK; it fails if an `entity_event` script row
# exists (a dev tool only).
defmodule Letflow.Repo.Migrations.CreateRecordTriggerBindings do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute(
        ~s|ALTER TABLE "#{schema}".script_rules DROP CONSTRAINT IF EXISTS script_rules_hook_kind|
      )

      execute("""
      ALTER TABLE "#{schema}".script_rules ADD CONSTRAINT script_rules_hook_kind
        CHECK (hook_kind IN ('service_task', 'entity_write', 'form_validation', 'entity_event'))
      """)

      execute("""
      CREATE TABLE "#{schema}".record_trigger_bindings (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        entity_type text NOT NULL CHECK (char_length(entity_type) >= 1),
        event text NOT NULL CHECK (event IN ('created', 'updated', 'deleted')),
        script_key text NOT NULL,
        script_version integer NOT NULL CHECK (script_version >= 1),
        script_sha256 text NOT NULL CHECK (script_sha256 ~ '^[0-9a-f]{64}$'),
        status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
        bound_by uuid,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX record_trigger_bindings_entity_type_event_index ON "#{schema}".record_trigger_bindings (entity_type, event)|
      )

      execute(
        ~s|CREATE INDEX record_trigger_bindings_script_index ON "#{schema}".record_trigger_bindings (script_key, script_version)|
      )
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(~s(DROP TABLE IF EXISTS "#{schema}".record_trigger_bindings))

      execute(
        ~s|ALTER TABLE "#{schema}".script_rules DROP CONSTRAINT IF EXISTS script_rules_hook_kind|
      )

      execute("""
      ALTER TABLE "#{schema}".script_rules ADD CONSTRAINT script_rules_hook_kind
        CHECK (hook_kind IN ('service_task', 'entity_write', 'form_validation'))
      """)
    end
  end
end
