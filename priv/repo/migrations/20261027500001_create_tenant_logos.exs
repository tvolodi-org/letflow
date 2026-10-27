# Letflow.Repo.Migrations.CreateTenantLogos
#
# REQ-590 / GH #3338 part 1: one uploaded logo image per tenant. Per-tenant table (0006 D2: no
# tenant_id column); the CHECK keeps it a singleton (`id = 1`), as `script_policy` does. The table
# starts empty and nothing reads it yet (REQ-591); existing `tenants.settings["logo_url"]` values
# are not touched.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# The only SQL interpolation is the schema name from `prefix()` (INV-7); here none is needed.
defmodule Letflow.Repo.Migrations.CreateTenantLogos do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:tenant_logos, primary_key: false, prefix: schema) do
        add :id, :smallint, primary_key: true
        add :content_type, :text, null: false
        add :byte_size, :integer, null: false
        add :content_hash, :text, null: false
        add :data, :binary, null: false
        add :updated_at, :utc_datetime_usec, null: false
        add :updated_by, :binary_id
      end

      create constraint(:tenant_logos, :tenant_logos_singleton,
               check: "id = 1",
               prefix: schema
             )
    end
  end
end
