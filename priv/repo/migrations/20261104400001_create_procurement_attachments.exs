# Letflow.Repo.Migrations.CreateProcurementAttachments
#
# REQ-626 / GH #3503 part A: the link table that attaches files to a purchase request. The bytes
# stay in the content-addressed `repository_artifacts` store; a row here names one file of one
# version of one request. Per-tenant table (0006 D2: no tenant_id column, the schema prefix is the
# tenant). Append-only: a trigger refuses UPDATE and DELETE, and a replacement is a new row whose
# `replaces_id` names the row it replaces. The table starts empty; no existing row is altered.
#
# Two partial unique indexes keep "exactly one current file per slot" (criteria 5 and 7 of REQ-626
# contradict as a single unique index on (document_id, version_no, slot_id), because a replace
# adds a second row for the slot in the same version):
#   * one root row (replaces_id IS NULL) per document, version and slot;
#   * a row is replaced at most once, so the chain of a slot is linear and has one head.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# The only SQL interpolation is the schema name from `prefix()` (INV-7), quoted as an identifier.
defmodule Letflow.Repo.Migrations.CreateProcurementAttachments do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".procurement_attachments (
        id uuid PRIMARY KEY,
        document_id uuid NOT NULL REFERENCES "#{schema}".documents (id),
        version_no integer NOT NULL CHECK (version_no > 0),
        slot_id uuid NOT NULL,
        content_hash bytea NOT NULL
          REFERENCES "#{schema}".repository_artifacts (content_hash) ON DELETE RESTRICT,
        file_name text NOT NULL CHECK (char_length(file_name) BETWEEN 1 AND 255),
        content_type text NOT NULL,
        byte_size bigint NOT NULL CHECK (byte_size >= 0 AND byte_size <= 26214400),
        uploaded_by uuid NOT NULL,
        uploaded_at timestamptz NOT NULL,
        replaces_id uuid REFERENCES "#{schema}".procurement_attachments (id)
      )
      """)

      execute("""
      CREATE UNIQUE INDEX procurement_attachments_root_idx
        ON "#{schema}".procurement_attachments (document_id, version_no, slot_id)
        WHERE replaces_id IS NULL
      """)

      execute("""
      CREATE UNIQUE INDEX procurement_attachments_replaces_idx
        ON "#{schema}".procurement_attachments (replaces_id)
        WHERE replaces_id IS NOT NULL
      """)

      execute("""
      CREATE INDEX procurement_attachments_version_idx
        ON "#{schema}".procurement_attachments (document_id, version_no)
      """)

      execute("""
      CREATE FUNCTION "#{schema}".procurement_attachments_immutable() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'procurement_attachments is immutable';
      END;
      $$ LANGUAGE plpgsql
      """)

      execute("""
      CREATE TRIGGER procurement_attachments_no_change
        BEFORE UPDATE OR DELETE ON "#{schema}".procurement_attachments
        FOR EACH ROW EXECUTE FUNCTION "#{schema}".procurement_attachments_immutable()
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()
      execute(~s(DROP TABLE IF EXISTS "#{schema}".procurement_attachments))
      execute(~s[DROP FUNCTION IF EXISTS "#{schema}".procurement_attachments_immutable()])
    end
  end
end
