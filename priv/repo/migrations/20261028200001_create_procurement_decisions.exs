# Letflow.Repo.Migrations.CreateProcurementDecisions
#
# REQ-544 / GH #3162 part 2: the decision record of module `procurement` (approve, reject, return of
# one purchase request version) and, in the same row, the idempotency store of the operation: one
# row per (document, idempotency key). Per-tenant table (0006 D2: no tenant_id column, the schema
# prefix is the tenant). Insert-only by construction: no code path updates or deletes a row. The
# table starts empty; no existing row is altered.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# The only SQL interpolation is the schema name from `prefix()` (INV-7), quoted as an identifier.
defmodule Letflow.Repo.Migrations.CreateProcurementDecisions do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".procurement_decisions (
        id uuid PRIMARY KEY,
        document_id uuid NOT NULL REFERENCES "#{schema}".documents (id),
        version_no integer NOT NULL CHECK (version_no > 0),
        content_hash text NOT NULL,
        decision text NOT NULL CHECK (decision IN ('approve', 'reject', 'return')),
        performer uuid NOT NULL,
        decided_at timestamptz NOT NULL,
        idempotency_key text NOT NULL,
        inserted_at timestamptz NOT NULL
      )
      """)

      execute("""
      CREATE UNIQUE INDEX procurement_decisions_key_idx
        ON "#{schema}".procurement_decisions (document_id, idempotency_key)
      """)

      execute("""
      CREATE INDEX procurement_decisions_version_idx
        ON "#{schema}".procurement_decisions (document_id, version_no, decided_at)
      """)
    end
  end

  def down do
    if prefix() do
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}".procurement_decisions))
    end
  end
end
