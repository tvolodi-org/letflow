# Letflow.Repo.Migrations.AddOutboundMappingToWebhookSubscriptions
#
# REQ-565 / GH #3201 (slice 2) -- a webhook subscription may link one outbound integration mapping
# (`webhook_subscriptions.outbound_mapping_id`). The column is nullable with no default: adding it
# is catalog-only, no existing row is rewritten, and every existing subscription reads NULL, which
# means "deliver the unmapped payload" (unchanged behaviour). There is deliberately no foreign key:
# the reference is protected by the lock protocol in Letflow.Webhooks.update/3 and
# Letflow.IntegrationMappings.delete/3 and re-checked at delivery time.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.AddOutboundMappingToWebhookSubscriptions do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute(
        ~s|ALTER TABLE "#{schema}".webhook_subscriptions ADD COLUMN IF NOT EXISTS outbound_mapping_id uuid NULL|
      )

      execute("""
      CREATE INDEX IF NOT EXISTS webhook_subscriptions_outbound_mapping_id_index
        ON "#{schema}".webhook_subscriptions (outbound_mapping_id)
        WHERE outbound_mapping_id IS NOT NULL
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(
        ~s|DROP INDEX IF EXISTS "#{schema}".webhook_subscriptions_outbound_mapping_id_index|
      )

      execute(
        ~s|ALTER TABLE "#{schema}".webhook_subscriptions DROP COLUMN IF EXISTS outbound_mapping_id|
      )
    end
  end
end
