# Letflow.Repo.Migrations.WidenTenantsScopeEnforcementCheck
#
# REQ-517 / GH #2535 PR 2b (decision 0051 D12, Rollout; design
# lib/letflow/design/req517-scoped-grants-admin-plane.md section 4.2) -- the stored value
# `on` of the per-tenant scope-enforcement flag on the PUBLIC `tenants` table. The CHECK
# `tenants_scope_enforcement_check` (created by 20261015025332 as off|shadow) is dropped and
# re-created as off|shadow|on. Nothing in application code can SET `on` yet
# (`Letflow.ScopeEnforcement.parse_mode/1` and `flip/4` still reject it; REQ-519 adds the
# guarded flip), so every existing row stays as it is.
#
# PUBLIC migration: deliberately NOT in `Letflow.TenantProvisioning`'s
# `@tenant_scoped_migration_manifest` (it touches `tenants`, not a tenant schema).
#
# `down` RAISES while any tenant is stored as `on`: an operator must flip such a tenant off
# first, because silently restoring the two-value CHECK would either fail on the row or
# de-escalate enforcement unnoticed. With no `on` row it restores the two-value CHECK.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7); every statement is a
# constant.
defmodule Letflow.Repo.Migrations.WidenTenantsScopeEnforcementCheck do
  use Ecto.Migration

  def up do
    drop constraint(:tenants, :tenants_scope_enforcement_check)

    create constraint(:tenants, :tenants_scope_enforcement_check,
             check: "scope_enforcement IN ('off', 'shadow', 'on')"
           )
  end

  def down do
    execute(fn -> refuse_when_any_tenant_is_on!() end)

    drop constraint(:tenants, :tenants_scope_enforcement_check)

    create constraint(:tenants, :tenants_scope_enforcement_check,
             check: "scope_enforcement IN ('off', 'shadow')"
           )
  end

  @spec refuse_when_any_tenant_is_on!() :: :ok
  defp refuse_when_any_tenant_is_on! do
    %{rows: [[count]]} =
      repo().query!("SELECT count(*) FROM tenants WHERE scope_enforcement = 'on'", [])

    if count > 0 do
      raise "tenants_scope_enforcement_check rollback refused: #{count} tenant(s) are stored " <>
              "as on; flip them off first"
    end

    :ok
  end
end
