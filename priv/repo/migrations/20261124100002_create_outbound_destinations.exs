# Letflow.Repo.Migrations.CreateOutboundDestinations
#
# T-2597 (pilot gap G14) -- the per-tenant OUTBOUND ALLOW-LIST: the channels a
# tenant may use to reach outside itself and the destinations it may reach.
#
# WHY A TABLE OF ITS OWN: the list is per tenant, it is written by a person
# (the holder of :OutboundDestinationsManage) and it is read by the activation
# fence and by the dispatcher of a notification step. It is not a definition and
# not a setting of the platform: a tenant's list belongs to the tenant.
#
# ONE ROW is one entry of the list, told apart by `destination`:
#   * `destination IS NULL` -- the CHANNEL itself is allowed (the door);
#   * `destination IS NOT NULL` -- one DESTINATION on that channel (a recipient
#     domain for the mail channel, a host for the HTTP channel).
# The two uniqueness rules are therefore two PARTIAL indexes: in Postgres a
# NULL is distinct from every other NULL, so one plain UNIQUE constraint would
# not stop a second channel row.
#
# GRANDFATHERING: a row may carry `definition_id` + `reason` (an entry listed
# because an already-active definition used it when the list arrived).
# Both columns are nullable; a human-added row leaves them empty.
#
# The row holds no address, no subject, no body and no person (INV-4): a tenant
# id, a channel name, a destination name, the actor who added it and the time.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateOutboundDestinations do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".outbound_destinations (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        channel text NOT NULL
          CONSTRAINT outbound_destinations_channel_chk
          CHECK (channel IN ('email', 'file', 'http')),
        destination text
          CONSTRAINT outbound_destinations_destination_chk
          CHECK (destination IS NULL OR (destination <> '' AND length(destination) <= 253)),
        inserted_by uuid,
        definition_id uuid,
        reason text,
        inserted_at timestamptz NOT NULL
      )
      """)

      execute("""
      CREATE UNIQUE INDEX outbound_destinations_channel_idx
        ON "#{schema}".outbound_destinations (tenant_id, channel)
        WHERE destination IS NULL
      """)

      execute("""
      CREATE UNIQUE INDEX outbound_destinations_destination_idx
        ON "#{schema}".outbound_destinations (tenant_id, channel, destination)
        WHERE destination IS NOT NULL
      """)

      # G2 (c), PM ruling 2026-11-24: definitions ALREADY ACTIVE keep working. The
      # hosts and channels they use are listed as allowed, with the definition id
      # and the reason 'grandfathered by G14'. Only NEW destinations are default-deny.
      # A tenant with no active definition (every fresh tenant) gets no row.
      flush()
      Letflow.OutboundDestinations.grandfather(schema)
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."outbound_destinations"|)
    end
  end
end
