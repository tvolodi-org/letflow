# Letflow.Repo.Migrations.WidenGrantsCreatedViaChk
#
# REQ-572 / GH #3252 (decision 0072 D5(a), slice 1) -- `pending_tenant_admin_grants_created_via_chk`
# allowed only 'onboarding'; the provisioner credential's grant path stores 'provisioning'. The
# constraint is re-added under the same name with both values. No table, column or row changes:
# every existing row is 'onboarding' and satisfies the wider CHECK.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# Letflow.TenantProvisioning's manifest (both halves are required). The only interpolated value is the
# trusted `prefix()` schema name, quoted as an identifier (INV-7). `down` restores the one-value CHECK
# and fails if a 'provisioning' grant exists (a dev tool only).
defmodule Letflow.Repo.Migrations.WidenGrantsCreatedViaChk do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute(
        ~s|ALTER TABLE "#{schema}".pending_tenant_admin_grants DROP CONSTRAINT IF EXISTS pending_tenant_admin_grants_created_via_chk|
      )

      execute("""
      ALTER TABLE "#{schema}".pending_tenant_admin_grants
        ADD CONSTRAINT pending_tenant_admin_grants_created_via_chk
        CHECK (created_via IN ('onboarding', 'provisioning'))
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(
        ~s|ALTER TABLE "#{schema}".pending_tenant_admin_grants DROP CONSTRAINT IF EXISTS pending_tenant_admin_grants_created_via_chk|
      )

      execute("""
      ALTER TABLE "#{schema}".pending_tenant_admin_grants
        ADD CONSTRAINT pending_tenant_admin_grants_created_via_chk
        CHECK (created_via = 'onboarding')
      """)
    end
  end
end
