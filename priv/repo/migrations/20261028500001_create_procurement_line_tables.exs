# Letflow.Repo.Migrations.CreateProcurementLineTables
#
# REQ-558 / GH #3188 part 1: the line events of module `procurement` (officer, supplier and
# PO/contract reference of one purchase request line, with the idempotency store of the operation) and
# the per-line row that holds the fulfilled quantity (initialised to 0 and only read in this slice).
# Per-tenant tables (0006 D2: no tenant_id column, the schema prefix is the tenant). Insert-only by
# construction: no code path updates or deletes a row. Both tables start empty; no existing row is
# altered.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# The only SQL interpolation is the schema name from `prefix()` (INV-7), quoted as an identifier.
defmodule Letflow.Repo.Migrations.CreateProcurementLineTables do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".procurement_line_events (
        id bigserial PRIMARY KEY,
        document_id uuid NOT NULL REFERENCES "#{schema}".documents (id),
        line_no integer NOT NULL CHECK (line_no > 0),
        version_no integer NOT NULL CHECK (version_no > 0),
        kind text NOT NULL CHECK (kind IN ('officer', 'supplier', 'reference')),
        data jsonb NOT NULL,
        performer uuid NOT NULL,
        recorded_at timestamptz NOT NULL,
        idempotency_key text NOT NULL,
        inserted_at timestamptz NOT NULL
      )
      """)

      execute("""
      CREATE UNIQUE INDEX procurement_line_events_key_idx
        ON "#{schema}".procurement_line_events (document_id, idempotency_key)
      """)

      execute("""
      CREATE INDEX procurement_line_events_line_idx
        ON "#{schema}".procurement_line_events (document_id, line_no, kind, id)
      """)

      execute("""
      CREATE TABLE "#{schema}".procurement_lines (
        document_id uuid NOT NULL REFERENCES "#{schema}".documents (id),
        line_no integer NOT NULL CHECK (line_no > 0),
        fulfilled_quantity numeric(38, 4) NOT NULL DEFAULT 0 CHECK (fulfilled_quantity >= 0),
        inserted_at timestamptz NOT NULL,
        PRIMARY KEY (document_id, line_no)
      )
      """)
    end
  end

  def down do
    if prefix() do
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}".procurement_lines))
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}".procurement_line_events))
    end
  end
end
