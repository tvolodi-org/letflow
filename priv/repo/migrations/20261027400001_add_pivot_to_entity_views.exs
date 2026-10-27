# Letflow.Repo.Migrations.AddPivotToEntityViews
#
# REQ-598 / GH #3367 (part A) -- saved pivot views: a second view kind on the existing
# `entity_views` table (decision 0066, slice 2). `kind` is `list` or `pivot`; `group_by` and
# `aggregates` hold the wire shape of `POST /entities/query/aggregate` and stay empty for a list
# view. No new table: the REQ-555 routes are reused.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). Existing rows are not rewritten: the
# NOT NULL defaults make every one `list` with empty `group_by` and `aggregates`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in Letflow.TenantProvisioning's manifest (both halves are required). The only interpolated value
# is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.AddPivotToEntityViews do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      ALTER TABLE "#{schema}".entity_views
        ADD COLUMN kind text NOT NULL DEFAULT 'list' CHECK (kind IN ('list', 'pivot')),
        ADD COLUMN group_by jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(group_by) = 'array'),
        ADD COLUMN aggregates jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(aggregates) = 'array'),
        ADD CONSTRAINT entity_views_pivot_clauses_chk
          CHECK (kind = 'pivot' OR (group_by = '[]'::jsonb AND aggregates = '[]'::jsonb))
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute("""
      ALTER TABLE "#{schema}".entity_views
        DROP CONSTRAINT IF EXISTS entity_views_pivot_clauses_chk,
        DROP COLUMN IF EXISTS kind,
        DROP COLUMN IF EXISTS group_by,
        DROP COLUMN IF EXISTS aggregates
      """)
    end
  end
end
