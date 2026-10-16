# REQ-497 PR 1b / GH #2533 (decision 0051 D12, Rollout; design
# lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md section 3.1) -- the per-tenant
# scope-enforcement flag on the PUBLIC `tenants` table. Stage 1 knows only `off` and
# `shadow`; the CHECK makes `on` unrepresentable until stage 2 (#2535) widens it in its own
# migration. Both auth paths already read the tenant row uncached, so the flag is read per
# request with no extra query. Deliberately NOT in the tenant settings blob (no generic
# settings API can reach it) and NOT in
# `Letflow.TenantProvisioning.tenant_scoped_migrations/0`. Every existing row gets `off`.
defmodule Letflow.Repo.Migrations.AddScopeEnforcementToTenants do
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add :scope_enforcement, :string, null: false, default: "off"
    end

    create constraint(:tenants, :tenants_scope_enforcement_check,
             check: "scope_enforcement IN ('off', 'shadow')"
           )
  end

  def down do
    drop constraint(:tenants, :tenants_scope_enforcement_check)

    alter table(:tenants) do
      remove :scope_enforcement
    end
  end
end
