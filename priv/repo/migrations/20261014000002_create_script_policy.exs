# Letflow.Repo.Migrations.CreateScriptPolicy
#
# GH 2534 PR 7b-2a (decision 0053 D5, D7 kill switch; advisor Q3) -- see
# lib/letflow/design/gh2534-7b2a-script-policy.md section 2 for the design.
#
# Two tenant tables:
#
#   * `script_policy` -- exactly one row (id = 1) per tenant schema, holding the two kill-switch
#     latches (P1: the tenant admin's and the platform operator's; effective = either on). The
#     row is inserted HERE (P7), so existing tenants get it through the boot replay and new
#     tenants through provisioning; `Letflow.Scripts.Policy.kill_switch_on?/1` reads a missing
#     row as ON (fail closed). The guard trigger refuses any DELETE and any change of `id` or
#     `inserted_at` (SQLSTATE 'LF001'); it names no other column, so 7b-2b's added columns need
#     no change to it.
#   * `script_readable_masters` -- the advisor-Q3 interim flag: a row means "scripts may read
#     this entity type". Clearing deletes the row (history lives in the audit chain).
#
# PLACEMENT: per-tenant (0006 D2: no tenant_id column).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.CreateScriptPolicy do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:script_policy, primary_key: false, prefix: schema) do
        add :id, :smallint, primary_key: true
        add :tenant_kill_switch, :boolean, null: false, default: false
        add :tenant_kill_switch_set_by, :binary_id
        add :tenant_kill_switch_set_at, :utc_datetime_usec
        add :tenant_kill_switch_reason, :text
        add :platform_kill_switch, :boolean, null: false, default: false
        # P10: no operator id column (the operator's identity lives in the platform chain only).
        add :platform_kill_switch_set_at, :utc_datetime_usec
        add :platform_kill_switch_reason, :text

        timestamps(type: :utc_datetime_usec)
      end

      create constraint(:script_policy, :script_policy_singleton,
               check: "id = 1",
               prefix: schema
             )

      create constraint(:script_policy, :script_policy_tenant_reason_length,
               check: "char_length(tenant_kill_switch_reason) <= 500",
               prefix: schema
             )

      create constraint(:script_policy, :script_policy_platform_reason_length,
               check: "char_length(platform_kill_switch_reason) <= 500",
               prefix: schema
             )

      # P7: the singleton row; a replay is idempotent.
      execute(
        """
        INSERT INTO "#{schema}".script_policy (id, inserted_at, updated_at)
        VALUES (1, now(), now())
        ON CONFLICT (id) DO NOTHING
        """,
        """
        DELETE FROM "#{schema}".script_policy WHERE id = 1
        """
      )

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".script_policy_guard() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'script_policy: the policy row is never deleted' USING ERRCODE = 'LF001';
          END IF;

          IF NEW.id IS DISTINCT FROM OLD.id
             OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
            RAISE EXCEPTION 'script_policy: identity columns are immutable' USING ERRCODE = 'LF001';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".script_policy_guard()
        """
      )

      execute(
        """
        CREATE TRIGGER script_policy_guard
          BEFORE UPDATE OR DELETE ON "#{schema}".script_policy
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".script_policy_guard()
        """,
        """
        DROP TRIGGER IF EXISTS script_policy_guard ON "#{schema}".script_policy
        """
      )

      create table(:script_readable_masters, primary_key: false, prefix: schema) do
        add :entity_type, :text, primary_key: true
        add :set_by, :binary_id, null: false
        add :set_at, :utc_datetime_usec, null: false
        add :reason, :text, null: false

        timestamps(type: :utc_datetime_usec, updated_at: false)
      end

      create constraint(:script_readable_masters, :script_readable_masters_entity_type_format,
               check: "entity_type ~ '^[a-z][a-z0-9_]{0,63}$'",
               prefix: schema
             )

      create constraint(:script_readable_masters, :script_readable_masters_reason_length,
               check: "char_length(reason) <= 500",
               prefix: schema
             )
    end
  end
end
