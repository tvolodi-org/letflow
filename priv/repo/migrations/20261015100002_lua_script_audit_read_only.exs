# Letflow.Repo.Migrations.LuaScriptAuditReadOnly
#
# GH 2534 PR 7c-1 (advisor Q11, decision C17) -- see
# lib/letflow/design/gh2534-7c-script-handler.md sections 3.2 and 10.
#
# `lua_script_execution_audit` (REQ-058) becomes read-only history: its only writer,
# `Letflow.Engine.LuaScriptAudit.execute_script_for_audit/6`, is removed in the same PR, and
# this ROW trigger refuses every INSERT, UPDATE and DELETE (SQLSTATE 'LF001'). Existing rows
# stay readable through `Letflow.Engine.LuaScriptAudit.AuditRecord`.
#
# NO TRUNCATE trigger (C17, CDV C6): exactly like `audit_entries`, TRUNCATE stays open because
# the pooled test-schema reset (`TenantTemplate.reset_clone_schema!/3`) depends on it; no
# `lib/` code truncates tenant tables.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.LuaScriptAuditReadOnly do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".lua_script_execution_audit_read_only()
        RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'lua_script_execution_audit: read-only history (GH 2534 7c)'
            USING ERRCODE = 'LF001';
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".lua_script_execution_audit_read_only()
        """
      )

      execute(
        """
        CREATE TRIGGER lua_script_execution_audit_read_only
          BEFORE INSERT OR UPDATE OR DELETE ON "#{schema}".lua_script_execution_audit
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".lua_script_execution_audit_read_only()
        """,
        """
        DROP TRIGGER IF EXISTS lua_script_execution_audit_read_only
          ON "#{schema}".lua_script_execution_audit
        """
      )
    end
  end
end
