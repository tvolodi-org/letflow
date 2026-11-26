# Letflow.Repo.Migrations.AddStartPermissionToProcessDefinitions
#
# T-2591 (pilot gap G3; decision record
# `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)): the permission a
# caller must hold to START an instance of this definition version.
#
# `start_permission` is NULLABLE and NULL for every existing row: a definition that declares
# none starts exactly as it did before. The value is a permission ATOM NAME (the same strings
# `Letflow.Api.Authorization` uses, e.g. `TenantsManage`), written by the definition's author
# when the version is created or updated.
#
# D-180 EXTENSION POINT (not built here): the later fork/binding slice of owner decision D-180
# adds the lineage of a tenant's own copy of a standard definition -- a `custom` marker and a
# `based_on: <standard key>@<version>` reference -- to THIS table, as further NULLABLE columns
# beside this one. Nothing here assumes that a definition is editable by whoever can see it, nor
# that a tenant has exactly one definition per key: the start permission is read from the
# definition's OWN row, and a tenant's copy would carry its own.
#
# TENANT-SCOPED MIGRATION -- the `if prefix()` guard is MANDATORY, and so is this file's
# registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# Reversible: `change/0`.
defmodule Letflow.Repo.Migrations.AddStartPermissionToProcessDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:process_definitions, prefix: schema) do
        add :start_permission, :string, size: 64
      end
    end
  end
end
