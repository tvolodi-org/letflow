# Letflow.Repo.Migrations.CreateRecordTriggerOutbox
#
# REQ-606 / GH #3411 part 1 (decision 0067 D1/D2/D9, slice T-2) -- the durable outbox of record
# triggers: a record write that matches an active binding leaves one `pending` row here in the same
# transaction. Nothing claims or runs a row yet (later slices). The table starts empty, so no
# existing row is altered.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). NO `tenant_id` column: the tenant is the
# schema (decision 0006 D2), the same as `solution_pack_overrides`. No foreign key: the row carries
# its own pin of the script version (0067 D4) and outlives an unbound binding. No record value, field
# name or variable content is stored (0067 D8).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
#
# `down` drops the table (a dev tool only).
defmodule Letflow.Repo.Migrations.CreateRecordTriggerOutbox do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".record_trigger_outbox (
        id uuid PRIMARY KEY,
        binding_id uuid NOT NULL,
        entity_type text NOT NULL CHECK (char_length(entity_type) >= 1),
        record_id uuid NOT NULL,
        event text NOT NULL CHECK (event IN ('created', 'updated', 'deleted')),
        source_seq bigint NOT NULL,
        occurred_at timestamptz NOT NULL,
        script_key text NOT NULL,
        script_version integer NOT NULL CHECK (script_version >= 1),
        script_sha256 text NOT NULL CHECK (script_sha256 ~ '^[0-9a-f]{64}$'),
        depth integer NOT NULL DEFAULT 0 CHECK (depth >= 0),
        chain uuid[] NOT NULL DEFAULT '{}',
        actor_id uuid,
        status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'done', 'dead')),
        attempt integer NOT NULL DEFAULT 0 CHECK (attempt >= 0),
        next_attempt_at timestamptz NOT NULL,
        claimed_at timestamptz,
        lease_expires_at timestamptz,
        last_code text,
        done_at timestamptz
      )
      """)

      execute("""
      CREATE INDEX record_trigger_outbox_backlog_index ON "#{schema}".record_trigger_outbox (status)
        WHERE status IN ('pending', 'running')
      """)
    end
  end

  def down do
    if prefix() do
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}".record_trigger_outbox))
    end
  end
end
