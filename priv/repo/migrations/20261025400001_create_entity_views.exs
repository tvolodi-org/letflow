# Letflow.Repo.Migrations.CreateEntityViews
#
# REQ-555 / GH #3157 -- saved list view definitions: a named, tenant-shared definition over ONE
# entity type (ordered columns, a filter and a sort stored in the wire shape of
# `POST /entities/query`). Decision 0066 D1..D7. A view stores field NAMES and literal filter
# values only; it never holds a record value.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` kept in
# the row as well (INV-1). The table starts empty: no existing row is altered. No foreign key to
# users or entity definitions (a type can be deactivated and a user removed; the view stays).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in Letflow.TenantProvisioning's manifest (both halves are required). The only interpolated value
# is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateEntityViews do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".entity_views (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        entity_type text NOT NULL,
        name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
        columns jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(columns) = 'array'),
        filter jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(filter) = 'array'),
        sort jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(sort) = 'array'),
        created_by uuid NOT NULL,
        updated_by uuid NOT NULL,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX entity_views_entity_type_name_index ON "#{schema}".entity_views (entity_type, name)|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}"."entity_views"))
    end
  end
end
