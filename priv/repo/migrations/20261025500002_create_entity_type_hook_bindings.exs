# Letflow.Repo.Migrations.CreateEntityTypeHookBindings
#
# REQ-567 / GH #3217 (decision 0065 D8, slice E-1 part 1) -- the pin of one published `entity_write`
# script version to one entity type (its pre-write hook). Nothing reads the table at run time yet.
#
# Two changes in one file: the CHECK `script_rules_hook_kind` (migration 20261014000001) allowed only
# 'service_task', so it is widened to also allow 'entity_write'; and the binding table is created.
# Existing rows are all 'service_task' and satisfy the wider CHECK; the table starts empty, so no
# existing row is altered. No foreign key (script_rules rows are never deleted; the retire block is
# application logic under the row lock).
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
#
# `down` drops the table and restores the old CHECK; it fails if an `entity_write` script row exists
# (a dev tool only).
defmodule Letflow.Repo.Migrations.CreateEntityTypeHookBindings do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute(
        ~s|ALTER TABLE "#{schema}".script_rules DROP CONSTRAINT IF EXISTS script_rules_hook_kind|
      )

      execute("""
      ALTER TABLE "#{schema}".script_rules ADD CONSTRAINT script_rules_hook_kind
        CHECK (hook_kind IN ('service_task', 'entity_write'))
      """)

      execute("""
      CREATE TABLE "#{schema}".entity_type_hook_bindings (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        entity_type text NOT NULL CHECK (char_length(entity_type) >= 1),
        script_key text NOT NULL,
        script_version integer NOT NULL CHECK (script_version >= 1),
        script_sha256 text NOT NULL CHECK (script_sha256 ~ '^[0-9a-f]{64}$'),
        bound_by uuid,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX entity_type_hook_bindings_entity_type_index ON "#{schema}".entity_type_hook_bindings (entity_type)|
      )

      execute(
        ~s|CREATE INDEX entity_type_hook_bindings_script_index ON "#{schema}".entity_type_hook_bindings (script_key, script_version)|
      )
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(~s(DROP TABLE IF EXISTS "#{schema}".entity_type_hook_bindings))

      execute(
        ~s|ALTER TABLE "#{schema}".script_rules DROP CONSTRAINT IF EXISTS script_rules_hook_kind|
      )

      execute("""
      ALTER TABLE "#{schema}".script_rules ADD CONSTRAINT script_rules_hook_kind
        CHECK (hook_kind = 'service_task')
      """)
    end
  end
end
