# Letflow.Repo.Migrations.AddManifestHashToTenantModules
#
# GH #2590 / REQ-501 PR R2 (design lib/letflow/design/gh2590-req501-module-write-handlers.md
# 4.8, 4.10, OQ-R7).
#
# `tenant_modules.manifest_hash` is the module's manifest hash
# (`Letflow.Modules.Catalog.manifest_hash/1`) recorded at install. Nullable, no default and NO
# backfill: a module installed before this migration cannot reconstruct the hash it was
# installed under, so its row stays NULL and (R3 onwards) such a tenant cannot activate a
# handler-calling definition until reinstall or the module-upgrade path (OQ-R7). Written only
# by `Letflow.Modules.Installs.install/3`; the settings changeset never casts it.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# Reversible: `change/0` with a single `alter ... add`.
defmodule Letflow.Repo.Migrations.AddManifestHashToTenantModules do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:tenant_modules, prefix: prefix()) do
        add :manifest_hash, :string, size: 64
      end
    end
  end
end
