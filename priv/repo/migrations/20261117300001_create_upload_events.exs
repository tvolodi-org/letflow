# Letflow.Repo.Migrations.CreateUploadEvents
#
# T-2133: upload_events is a lightweight audit trail of successful uploads, one row per link
# created, retained after the link is deleted. `check_rate/2` in `Letflow.Attachments` counts
# from this table (not from attachment_links) so that add-then-delete cycles cannot reset the
# 60-uploads-per-hour per-actor rate limit.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). No tenant_id column: the schema is
# the tenant boundary (decision 0006 D2). No foreign key to attachment_links: the event must
# survive link deletion.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
#
# down: drops the table; a replay after down recreates it empty.
defmodule Letflow.Repo.Migrations.CreateUploadEvents do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".upload_events (
        id uuid PRIMARY KEY,
        actor_id uuid NOT NULL,
        inserted_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE INDEX upload_events_actor_inserted_at_idx ON "#{schema}".upload_events (actor_id, inserted_at)|
      )
    end
  end

  def down do
    if prefix() do
      schema = prefix()
      execute(~s|DROP TABLE IF EXISTS "#{schema}".upload_events|)
    end
  end
end
