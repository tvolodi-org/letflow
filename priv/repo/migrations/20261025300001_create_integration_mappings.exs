# Letflow.Repo.Migrations.CreateIntegrationMappings
#
# REQ-565 / GH #3201 (slice 1) -- tenant integration mappings: a declarative, data-only payload
# mapping (rules as jsonb). No credential column: a const is public configuration, never a secret.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well. The table starts empty: no existing row is altered.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateIntegrationMappings do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".integration_mappings (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
        direction text NOT NULL CHECK (direction IN ('outbound', 'inbound')),
        rules jsonb NOT NULL,
        updated_by uuid,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX integration_mappings_name_index ON "#{schema}".integration_mappings (name)|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}".integration_mappings))
    end
  end
end
