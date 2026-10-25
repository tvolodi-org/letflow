# Letflow.Repo.Migrations.WidenScriptRulesHookKindFormValidation
#
# REQ-569 / GH #3246 (decision 0067 D9, slice F-1) -- the CHECK `script_rules_hook_kind` allowed only
# 'service_task' and 'entity_write', so a `form_validation` script version could not be stored. It is
# widened to also allow 'form_validation'. Nothing else changes: no table, no column, no data. Existing
# rows are all 'service_task' or 'entity_write' and satisfy the wider CHECK.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
#
# `down` restores the two-kind CHECK; it fails if a `form_validation` script row exists (a dev tool only).
defmodule Letflow.Repo.Migrations.WidenScriptRulesHookKindFormValidation do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute(
        ~s|ALTER TABLE "#{schema}".script_rules DROP CONSTRAINT IF EXISTS script_rules_hook_kind|
      )

      execute("""
      ALTER TABLE "#{schema}".script_rules ADD CONSTRAINT script_rules_hook_kind
        CHECK (hook_kind IN ('service_task', 'entity_write', 'form_validation'))
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(
        ~s|ALTER TABLE "#{schema}".script_rules DROP CONSTRAINT IF EXISTS script_rules_hook_kind|
      )

      execute("""
      ALTER TABLE "#{schema}".script_rules ADD CONSTRAINT script_rules_hook_kind
        CHECK (hook_kind IN ('service_task', 'entity_write'))
      """)
    end
  end
end
