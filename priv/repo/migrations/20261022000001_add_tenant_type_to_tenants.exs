# REQ-469 (GH #2476) -- tenant type (`test` | `production`) on the PUBLIC `tenants` table.
# NOT NULL with default 'test', so every existing row reads `test` until a platform admin
# changes it. A platform-security attribute: not in the tenant `settings` blob and NOT added to
# `Letflow.TenantProvisioning.tenant_scoped_migrations/0`.
defmodule Letflow.Repo.Migrations.AddTenantTypeToTenants do
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add :tenant_type, :string, null: false, default: "test"
    end

    create constraint(:tenants, :tenants_tenant_type_check,
             check: "tenant_type IN ('test', 'production')"
           )
  end

  def down do
    drop constraint(:tenants, :tenants_tenant_type_check)

    alter table(:tenants) do
      remove :tenant_type
    end
  end
end
