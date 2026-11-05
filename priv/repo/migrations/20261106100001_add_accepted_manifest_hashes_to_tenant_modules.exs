# Letflow.Repo.Migrations.AddAcceptedManifestHashesToTenantModules
#
# REQ-769 (module upgrade path, decision 0055 Q1 option (a)): `tenant_modules.accepted_manifest_hashes`
# lists earlier manifest hashes whose owner stamps stay valid after the module row was upgraded to a
# newer manifest. NOT NULL, default empty: every existing row (QA included) reads `{}`, so behaviour is
# unchanged until the upgrade apply (REQ-770, the only future writer) fills it.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and so is this file's
# registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
defmodule Letflow.Repo.Migrations.AddAcceptedManifestHashesToTenantModules do
  use Ecto.Migration

  def up do
    if prefix() do
      execute(
        ~s(ALTER TABLE "#{prefix()}".tenant_modules ADD COLUMN IF NOT EXISTS accepted_manifest_hashes text[] NOT NULL DEFAULT '{}')
      )
    end
  end

  def down do
    if prefix() do
      execute(
        ~s(ALTER TABLE "#{prefix()}".tenant_modules DROP COLUMN IF EXISTS accepted_manifest_hashes)
      )
    end
  end
end
