# Letflow.Repo.Migrations.CreateNotificationDeliveries
#
# REQ-584 / GH #3310 -- the delivery log of notification mail: one row per send attempt
# (template key, locale, recipient user id, closed status and reason, trigger reference). It holds
# no subject, body, recipient address or error text (INV-4).
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well. The table starts empty: no existing row is altered.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateNotificationDeliveries do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".notification_deliveries (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        template_key text NOT NULL,
        locale text NOT NULL,
        recipient_user_id uuid,
        status text NOT NULL CHECK (status IN ('sent', 'failed', 'skipped')),
        reason text CHECK (reason IN ('no_email', 'adapter_noop', 'adapter_error')),
        trigger_ref uuid NOT NULL,
        inserted_at timestamptz NOT NULL,
        CONSTRAINT notification_deliveries_status_reason_chk
          CHECK ((status = 'sent') = (reason IS NULL))
      )
      """)

      execute(
        ~s|CREATE INDEX notification_deliveries_inserted_at_index ON "#{schema}".notification_deliveries (inserted_at DESC, id DESC)|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."notification_deliveries"|)
    end
  end
end
