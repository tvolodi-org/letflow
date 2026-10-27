# Letflow.Repo.Migrations.CreateEntityTypeExtensions
#
# REQ-576 / GH #3258 -- decision 0067-tenant-x D2, slice I1 (storage only): the table that will hold
# a tenant's `x_` additions to a module entity type. Nothing writes or reads it yet.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` kept in
# the row as well (INV-1). The table starts empty: no existing row is altered. No foreign key: a
# module upgrade replaces entity definition rows and must leave this layer intact.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in Letflow.TenantProvisioning's manifest (both halves are required). The only interpolated value
# is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateEntityTypeExtensions do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".entity_type_extensions (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        entity_type text NOT NULL,
        kind text NOT NULL CONSTRAINT entity_type_extensions_kind_chk CHECK (kind = 'field'),
        name text NOT NULL CONSTRAINT entity_type_extensions_name_chk CHECK (name LIKE 'x\\_%'),
        spec jsonb NOT NULL CONSTRAINT entity_type_extensions_spec_chk CHECK (jsonb_typeof(spec) = 'object'),
        "position" integer NOT NULL,
        status text NOT NULL CONSTRAINT entity_type_extensions_status_chk CHECK (status IN ('active', 'retired')),
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX entity_type_extensions_tenant_type_name_index ON "#{schema}".entity_type_extensions (tenant_id, entity_type, name)|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}"."entity_type_extensions"))
    end
  end
end
