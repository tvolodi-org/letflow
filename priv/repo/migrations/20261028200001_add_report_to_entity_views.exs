# Letflow.Repo.Migrations.AddReportToEntityViews
#
# REQ-619 / GH #3453 (part A) -- saved report definitions: a fourth view kind on the existing
# `entity_views` table (decision 0066, slice 4). A report stores one filter, a summary
# (`group_by` + non-empty `aggregates`, the pivot shape) and an optional detail (`columns` +
# `sort`, the list shape). No new table, no new column: the REQ-555 routes are reused.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). Existing rows are not rewritten: they
# are `list`, `pivot` or `graph`, which the wider checks accept. `entity_views_chart_type_chk` is
# left as it is: it already keeps `chart_type` NULL for every kind but `graph`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in Letflow.TenantProvisioning's manifest (both halves are required). The only interpolated value
# is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.AddReportToEntityViews do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      ALTER TABLE "#{schema}".entity_views
        DROP CONSTRAINT entity_views_kind_check,
        ADD CONSTRAINT entity_views_kind_check CHECK (kind IN ('list', 'pivot', 'graph', 'report')),
        DROP CONSTRAINT entity_views_pivot_clauses_chk,
        ADD CONSTRAINT entity_views_pivot_clauses_chk
          CHECK (kind IN ('pivot', 'graph', 'report') OR (group_by = '[]'::jsonb AND aggregates = '[]'::jsonb))
      """)
    end
  end

  # Restoring the narrower checks fails when report rows exist: a rollback never silently
  # deletes saved views.
  def down do
    if prefix() do
      schema = prefix()

      execute("""
      ALTER TABLE "#{schema}".entity_views
        DROP CONSTRAINT IF EXISTS entity_views_kind_check,
        ADD CONSTRAINT entity_views_kind_check CHECK (kind IN ('list', 'pivot', 'graph')),
        DROP CONSTRAINT IF EXISTS entity_views_pivot_clauses_chk,
        ADD CONSTRAINT entity_views_pivot_clauses_chk
          CHECK (kind IN ('pivot', 'graph') OR (group_by = '[]'::jsonb AND aggregates = '[]'::jsonb))
      """)
    end
  end
end
