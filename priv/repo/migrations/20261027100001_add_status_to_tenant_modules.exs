# Letflow.Repo.Migrations.AddStatusToTenantModules
#
# REQ-578 / GH #3267, decision 0066 D2: `tenant_modules.status` is `active` or `uninstalled`.
# NOT NULL with default 'active', so every existing row (QA's already-installed modules
# included) reads `active` and no data statement is needed. No CHECK constraint: the schema's
# Ecto.Enum refuses other values at the application boundary.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# Reversible: `change/0` with a single `alter ... add`.
defmodule Letflow.Repo.Migrations.AddStatusToTenantModules do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:tenant_modules, prefix: prefix()) do
        add :status, :string, null: false, default: "active"
      end
    end
  end
end
