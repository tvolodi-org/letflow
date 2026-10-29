# Letflow.Repo.Migrations.AllowCancelLineEvent
#
# REQ-558 / GH #3188 part 2: the cancelled mark of a purchase request line is a fourth event kind
# `cancel` in `procurement_line_events`. The kind CHECK of part 1 (the inline column check, Postgres's
# default name `procurement_line_events_kind_check`) is widened; no table is added and no existing row
# is altered. `down` restores the narrower check only while no `cancel` row exists (history is never
# deleted); otherwise it raises.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# The only SQL interpolation is the schema name from `prefix()` (INV-7), quoted as an identifier.
defmodule Letflow.Repo.Migrations.AllowCancelLineEvent do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute(
        ~s(ALTER TABLE "#{schema}".procurement_line_events DROP CONSTRAINT procurement_line_events_kind_check)
      )

      execute("""
      ALTER TABLE "#{schema}".procurement_line_events
        ADD CONSTRAINT procurement_line_events_kind_check
        CHECK (kind IN ('officer', 'supplier', 'reference', 'cancel'))
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM "#{schema}".procurement_line_events WHERE kind = 'cancel') THEN
          RAISE EXCEPTION 'cancel line events exist; they are history and are not deleted';
        END IF;
      END
      $$
      """)

      execute(
        ~s(ALTER TABLE "#{schema}".procurement_line_events DROP CONSTRAINT procurement_line_events_kind_check)
      )

      execute("""
      ALTER TABLE "#{schema}".procurement_line_events
        ADD CONSTRAINT procurement_line_events_kind_check
        CHECK (kind IN ('officer', 'supplier', 'reference'))
      """)
    end
  end
end
