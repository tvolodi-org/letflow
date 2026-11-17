# Letflow.Repo.Migrations.CreateStockCreateIdempotency
#
# REQ-846 / GH #4560: the per-tenant idempotency table for POST /modules/stock/documents.
# Binds a client-supplied key (namespaced `client:stock_create:<actor>:<raw>`, at most
# 20+36+1+199 = 256 bytes) to the document it created and to the canonical body hash of
# that original request.  The same-body check and the advisory lock in
# `Letflow.Modules.Stock.Documents.save/4` use this table.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md §4 and
# `Letflow.Repo.Migrations.CreateEvents` for the full reasoning.
# This migration must also be listed in `@tenant_scoped_migration_manifest` in
# `lib/letflow/tenant_provisioning.ex`.
#
# No expiry: the row lives forever; a discarded document's key is still bound,
# and a later replay returns the current fetch result (404 when discarded).
#
# `key` is varchar(256) rather than 255: `"client:stock_create:"` (20 bytes) +
# a 36-byte UUID actor + `:` + a 199-byte raw key = 256 bytes.  All other
# stored client keys fit in 255; the route-specific column avoids widening the
# shared `event_idempotency` table.
#
# Existing documents and already-deployed QA tenants: the new table is empty
# on creation; documents created before this migration have no row here and
# keep today's server-minted key behaviour.  The migration is applied to existing
# tenants by the boot replay (`MigrationReplayBoot`, ISS-0771); a tenant whose
# replay failed is listed by `TenantProvisioning.list_replay_failures/0`.
defmodule Letflow.Repo.Migrations.CreateStockCreateIdempotency do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:stock_create_idempotency, primary_key: false, prefix: prefix()) do
        # The namespaced stored key, e.g. "client:stock_create:<uuid>:<raw>".
        # varchar(256): one byte wider than the shared event_idempotency column
        # because the "stock_create:" token is two bytes longer than "inst_start:".
        add :key, :string, size: 256, primary_key: true, null: false

        # The document created by this request (tracks the document even after it
        # is replaced, discarded or posted; a replay returns its current state).
        add :document_id, :binary_id, null: false

        # SHA-256 hex digest of the canonical body (recursively sorted-key JSON).
        # A mismatch on replay means 409 idempotency_key_reuse.
        add :body_hash, :string, size: 64, null: false
      end
    end
  end
end
