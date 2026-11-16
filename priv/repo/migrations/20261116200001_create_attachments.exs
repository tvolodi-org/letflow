# Letflow.Repo.Migrations.CreateAttachments
#
# T-2040 (Photos P1): the attachment service core. Two tables per tenant schema:
#   attachment_blobs  -- deletable bytes, one row per sha256 within a tenant (deduplicated)
#   attachment_links  -- owner (kind + id), purpose, position, main flag, caption, thumbnail
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`), created empty in every schema; nothing to
# backfill. No foreign key to a public-schema table. The owner is polymorphic, so `owner_id` has no FK.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, registered in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
defmodule Letflow.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".attachment_blobs (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
        content_type text NOT NULL CHECK (content_type IN ('image/jpeg','image/png','image/webp')),
        byte_size integer NOT NULL,
        width integer CHECK (width IS NULL OR width BETWEEN 1 AND 16384),
        height integer CHECK (height IS NULL OR height BETWEEN 1 AND 16384),
        bytes bytea NOT NULL,
        inserted_at timestamptz NOT NULL,
        CONSTRAINT attachment_blobs_byte_size CHECK (byte_size > 0 AND byte_size = octet_length(bytes))
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX attachment_blobs_sha256_index ON "#{schema}".attachment_blobs (sha256)|
      )

      # JPEG/PNG/WebP do not compress; skip the TOAST compression attempt.
      execute(
        ~s|ALTER TABLE "#{schema}".attachment_blobs ALTER COLUMN bytes SET STORAGE EXTERNAL|
      )

      execute("""
      CREATE TABLE "#{schema}".attachment_links (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        owner_kind text NOT NULL CHECK (owner_kind ~ '^[a-z][a-z0-9_]{0,62}$'),
        owner_id uuid NOT NULL,
        purpose text NOT NULL CHECK (purpose IN ('photo','evidence','file','screenshot')),
        position smallint NOT NULL CHECK (position >= 1),
        is_main boolean NOT NULL DEFAULT false,
        caption text CHECK (caption IS NULL OR char_length(caption) <= 200),
        blob_id uuid NOT NULL REFERENCES "#{schema}".attachment_blobs(id) ON DELETE RESTRICT,
        thumb_blob_id uuid REFERENCES "#{schema}".attachment_blobs(id) ON DELETE RESTRICT,
        uploaded_by uuid NOT NULL,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        locked_at timestamptz,
        retain_until timestamptz,
        CONSTRAINT attachment_links_position_key
          UNIQUE (owner_kind, owner_id, purpose, position) DEFERRABLE INITIALLY IMMEDIATE
      )
      """)

      execute("""
      CREATE UNIQUE INDEX attachment_links_one_main_index
        ON "#{schema}".attachment_links (owner_kind, owner_id, purpose) WHERE is_main
      """)

      execute("""
      CREATE UNIQUE INDEX attachment_links_blob_per_owner_index
        ON "#{schema}".attachment_links (owner_kind, owner_id, purpose, blob_id)
      """)

      execute(
        ~s|CREATE INDEX attachment_links_blob_id_index ON "#{schema}".attachment_links (blob_id)|
      )

      execute(
        ~s|CREATE INDEX attachment_links_thumb_blob_id_index ON "#{schema}".attachment_links (thumb_blob_id)|
      )

      execute(
        ~s|CREATE INDEX attachment_links_uploaded_by_index ON "#{schema}".attachment_links (uploaded_by, inserted_at)|
      )
    end
  end

  def down do
    if prefix() do
      schema = prefix()
      execute(~s|DROP TABLE IF EXISTS "#{schema}".attachment_links|)
      execute(~s|DROP TABLE IF EXISTS "#{schema}".attachment_blobs|)
    end
  end
end
