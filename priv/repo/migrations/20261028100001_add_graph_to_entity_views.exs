# Letflow.Repo.Migrations.AddGraphToEntityViews
#
# REQ-613 / GH #3432 (part A) -- saved graph views: a third view kind on the existing
# `entity_views` table (decision 0066, slice 3). A graph view stores a filter, exactly one
# `group_by`, one to three `aggregates` and a `chart_type` (bar, line or pie). No new table: the
# REQ-555 routes are reused.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). Existing rows are not rewritten: they
# are `list` or `pivot` with a NULL `chart_type`, which both new checks accept.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in Letflow.TenantProvisioning's manifest (both halves are required). The only interpolated value
# is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.AddGraphToEntityViews do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      ALTER TABLE "#{schema}".entity_views
        DROP CONSTRAINT entity_views_kind_check,
        ADD CONSTRAINT entity_views_kind_check CHECK (kind IN ('list', 'pivot', 'graph')),
        DROP CONSTRAINT entity_views_pivot_clauses_chk,
        ADD CONSTRAINT entity_views_pivot_clauses_chk
          CHECK (kind IN ('pivot', 'graph') OR (group_by = '[]'::jsonb AND aggregates = '[]'::jsonb)),
        ADD COLUMN chart_type text,
        ADD CONSTRAINT entity_views_chart_type_chk
          CHECK (
            (kind = 'graph' AND chart_type IS NOT NULL AND chart_type IN ('bar', 'line', 'pie'))
            OR (kind <> 'graph' AND chart_type IS NULL)
          )
      """)
    end
  end

  # Restoring the narrower kind check fails when graph rows exist: a rollback never silently
  # deletes saved views.
  def down do
    if prefix() do
      schema = prefix()

      execute("""
      ALTER TABLE "#{schema}".entity_views
        DROP CONSTRAINT IF EXISTS entity_views_chart_type_chk,
        DROP COLUMN IF EXISTS chart_type,
        DROP CONSTRAINT IF EXISTS entity_views_kind_check,
        ADD CONSTRAINT entity_views_kind_check CHECK (kind IN ('list', 'pivot')),
        DROP CONSTRAINT IF EXISTS entity_views_pivot_clauses_chk,
        ADD CONSTRAINT entity_views_pivot_clauses_chk
          CHECK (kind = 'pivot' OR (group_by = '[]'::jsonb AND aggregates = '[]'::jsonb))
      """)
    end
  end
end
