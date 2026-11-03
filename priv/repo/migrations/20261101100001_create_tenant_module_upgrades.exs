# Letflow.Repo.Migrations.CreateTenantModuleUpgrades
#
# REQ-640 / GH #3578 (module upgrade slice 1a, decision 0055 D1, D12 step 1): the per-tenant journal
# table `tenant_module_upgrades`. Nothing writes to it in this slice.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). NO `tenant_id` column: the tenant is the
# schema (decision 0006 D2). No foreign key, no trigger, no CHECK: `kind` and `state` are restricted
# by the Ecto.Enum cast of `Letflow.Modules.TenantModuleUpgrade`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# Letflow.TenantProvisioning's manifest (both halves are required). The only interpolated value is the
# trusted `prefix()` schema name, quoted as an identifier (INV-7).
#
# OPERATOR NOTE: the table starts empty and no existing row is altered (`tenant_modules` is untouched).
# Existing tenants receive it through `replay_all_pending/0` after deploy.
defmodule Letflow.Repo.Migrations.CreateTenantModuleUpgrades do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".tenant_module_upgrades (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        module_id text NOT NULL,
        from_version text NOT NULL,
        to_version text NOT NULL,
        kind text NOT NULL,
        state text NOT NULL,
        plan_hash text,
        actor_id uuid,
        rationale text,
        step_id text,
        step_cursor text,
        steps_done text[] NOT NULL DEFAULT '{}',
        touches jsonb,
        catchup_from_seq bigint,
        runner_id text,
        epoch integer NOT NULL DEFAULT 1,
        heartbeat_at timestamptz,
        started_at timestamptz,
        finished_at timestamptz,
        error_code text
      )
      """)
    end
  end

  def down do
    if prefix() do
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}".tenant_module_upgrades))
    end
  end
end
