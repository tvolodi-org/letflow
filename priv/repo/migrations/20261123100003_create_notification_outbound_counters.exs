# Letflow.Repo.Migrations.CreateNotificationOutboundCounters
#
# T-2592 (pilot gap G4) -- the RESERVATION counter of a tenant's outbound send cap.
#
# WHY A TABLE OF ITS OWN: the cap used to be counted over the delivery log, so a
# delivery row that could not be written was a send that was never counted -- and
# the send had already left the platform (the security gate's finding: the cap
# was defeated whenever the outcome row was unwritable). The counter is written
# BEFORE the send, in one transaction with the cap check, so a send is accounted
# for whether or not the delivery log row can be written afterwards.
#
# ONE ROW per (tenant, channel, period, window): the window is the clock hour or
# the UTC day the reservation belongs to, so the row is the singleton the atomic
# `send_count = send_count + 1 WHERE send_count < cap` reservation locks. The
# row holds no address, no subject, no body and no person (INV-4): a tenant id,
# a channel name, a period, a window and a number.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateNotificationOutboundCounters do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".notification_outbound_counters (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        channel text NOT NULL,
        period text NOT NULL CONSTRAINT notification_outbound_counters_period_chk
          CHECK (period IN ('hour', 'day')),
        window_started_at timestamptz NOT NULL,
        send_count integer NOT NULL DEFAULT 0
          CONSTRAINT notification_outbound_counters_send_count_chk CHECK (send_count >= 0),
        inserted_at timestamptz NOT NULL,
        CONSTRAINT notification_outbound_counters_unique
          UNIQUE (tenant_id, channel, period, window_started_at)
      )
      """)
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."notification_outbound_counters"|)
    end
  end
end
