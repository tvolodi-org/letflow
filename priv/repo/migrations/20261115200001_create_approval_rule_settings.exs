# Letflow.Repo.Migrations.CreateApprovalRuleSettings
#
# T-1986 (four-eyes switch, slice 1; docs/design/four-eyes-switch.md, owner decision D-144): one row per
# (process definition name, HUMAN_TASK node id) that a tenant administrator has switched. No row means
# the four-eyes rule (`distinct_from`) stays ON. The table starts EMPTY in every schema and this
# migration writes no data, so no existing process changes behaviour.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`); the schema is the tenant boundary, so the
# row carries no tenant_id (0006 D2).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateApprovalRuleSettings do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".approval_rule_settings (
        id uuid PRIMARY KEY,
        definition_name text NOT NULL CHECK (char_length(definition_name) BETWEEN 1 AND 255),
        node_id text NOT NULL CHECK (char_length(node_id) BETWEEN 1 AND 255),
        four_eyes boolean NOT NULL,
        changed_by uuid NOT NULL,
        changed_at timestamptz NOT NULL,
        reason text NOT NULL,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX approval_rule_settings_step_index ON "#{schema}".approval_rule_settings (definition_name, node_id)|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."approval_rule_settings"|)
    end
  end
end
