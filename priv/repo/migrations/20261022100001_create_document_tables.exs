# Letflow.Repo.Migrations.CreateDocumentTables
#
# REQ-500 / GH #2588, PR A (storage and integrity) -- see
# state/tasks/T-0077/design.md section 6 for the schema this migration creates and
# docs/migration/decisions/0056-versioned-documents.md for the decision it implements.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). A document is tenant
# business data; no row is ever shared across tenants. Every table carries
# `tenant_id uuid NOT NULL` as well, so the tenant stays visible inside each schema.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file
# is registered in Letflow.TenantProvisioning's manifest (both halves are required).
#
# The immutability triggers live in the next migration
# (20261022100002_create_document_immutability_triggers.exs). Nothing here is a
# trigger; the constraints below are the shape-level rules that hold on their own.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier.
defmodule Letflow.Repo.Migrations.CreateDocumentTables do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      for sql <- create_statements(schema), do: execute(sql)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      for table <-
            ~w(document_external_registrations document_sequences document_versions documents document_types) do
        execute(~s(DROP TABLE IF EXISTS "#{schema}"."#{table}"))
      end
    end
  end

  defp create_statements(schema) do
    [
      """
      CREATE TABLE "#{schema}".document_types (
        key text PRIMARY KEY,
        tenant_id uuid NOT NULL,
        owner_module text NOT NULL,
        numbering_scope text NOT NULL CHECK (numbering_scope IN ('year', 'none')),
        number_prefix text NOT NULL,
        number_pad integer NOT NULL CHECK (number_pad >= 0),
        legal_entity_required boolean NOT NULL,
        restricted_fields_allowed boolean NOT NULL DEFAULT false
          CHECK (restricted_fields_allowed = false),
        declared_fields jsonb NOT NULL,
        template_ref text NULL,
        inserted_at timestamptz NOT NULL
      )
      """,
      # documents.current_version is added below, after document_versions exists.
      """
      CREATE TABLE "#{schema}".documents (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        type_key text NOT NULL REFERENCES "#{schema}".document_types (key) ON UPDATE RESTRICT,
        legal_entity_id uuid NULL,
        issuing_org_unit_id uuid NOT NULL,
        period text NULL,
        number bigint NULL,
        source_ref jsonb NULL,
        current_version uuid NULL,
        inserted_at timestamptz NOT NULL,
        CHECK ((number IS NULL) = (period IS NULL))
      )
      """,
      """
      CREATE TABLE "#{schema}".document_versions (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        document_id uuid NOT NULL REFERENCES "#{schema}".documents (id),
        version_no integer NOT NULL CHECK (version_no >= 1),
        status text NOT NULL CHECK (status IN ('draft', 'issued', 'superseded', 'cancelled', 'discarded')),
        content jsonb NOT NULL,
        content_hash text NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
        issued_at timestamptz NULL,
        issued_by uuid NULL,
        superseded_by_version uuid NULL,
        cancelled_at timestamptz NULL,
        cancelled_by uuid NULL,
        cancel_reason text NULL,
        discarded_at timestamptz NULL,
        discarded_by uuid NULL,
        artefact_hash text NULL,
        inserted_at timestamptz NOT NULL,
        UNIQUE (document_id, version_no),
        UNIQUE (document_id, id),
        FOREIGN KEY (document_id, superseded_by_version)
          REFERENCES "#{schema}".document_versions (document_id, id),
        CHECK (status <> 'issued'
          OR (issued_at IS NOT NULL AND issued_by IS NOT NULL AND content_hash IS NOT NULL)),
        CHECK (status <> 'superseded' OR superseded_by_version IS NOT NULL),
        CHECK (status <> 'cancelled'
          OR (cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL
              AND cancel_reason IS NOT NULL AND btrim(cancel_reason) <> '')),
        CHECK (status <> 'discarded' OR discarded_at IS NOT NULL)
      )
      """,
      """
      ALTER TABLE "#{schema}".documents
        ADD CONSTRAINT documents_current_version_fkey
        FOREIGN KEY (id, current_version)
        REFERENCES "#{schema}".document_versions (document_id, id)
      """,
      # D-6: partial, so drafts (number IS NULL) never collide. NULLS NOT DISTINCT
      # makes two issued rows with a NULL legal_entity_id collide as well.
      """
      CREATE UNIQUE INDEX documents_number_key
        ON "#{schema}".documents (type_key, legal_entity_id, period, number) NULLS NOT DISTINCT
        WHERE number IS NOT NULL
      """,
      """
      CREATE INDEX documents_type_key_idx ON "#{schema}".documents (type_key)
      """,
      """
      CREATE UNIQUE INDEX document_versions_one_issued
        ON "#{schema}".document_versions (document_id) WHERE status = 'issued'
      """,
      """
      CREATE TABLE "#{schema}".document_sequences (
        tenant_id uuid NOT NULL,
        type_key text NOT NULL REFERENCES "#{schema}".document_types (key) ON UPDATE RESTRICT,
        legal_entity_key text NOT NULL,
        period text NOT NULL,
        counter bigint NOT NULL DEFAULT 0 CHECK (counter >= 0),
        PRIMARY KEY (type_key, legal_entity_key, period)
      )
      """,
      # Append-only and empty in slice 1; the writer arrives with the external
      # registration flow (a later slice).
      """
      CREATE TABLE "#{schema}".document_external_registrations (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        document_id uuid NOT NULL,
        version_id uuid NOT NULL,
        system text NOT NULL,
        external_ref text NOT NULL,
        registered_at timestamptz NOT NULL,
        FOREIGN KEY (document_id, version_id)
          REFERENCES "#{schema}".document_versions (document_id, id)
      )
      """
    ]
  end
end
