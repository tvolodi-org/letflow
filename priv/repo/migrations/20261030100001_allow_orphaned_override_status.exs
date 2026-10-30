# Letflow.Repo.Migrations.AllowOrphanedOverrideStatus
#
# REQ-617 / GH #3443 (decision 0069 D8 S4): an override whose artefact left the pack, or whose property is
# no longer overridable, is kept as a new version row with status `orphaned`. The status CHECK of
# `solution_pack_overrides` (the inline column check, Postgres's default name
# `solution_pack_overrides_status_check`) is widened; no table or column is added and no existing row is
# altered. `down` restores the narrower check only while no `orphaned` row exists (history is never
# deleted); otherwise it raises.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# The only SQL interpolation is the schema name from `prefix()` (INV-7), quoted as an identifier.
defmodule Letflow.Repo.Migrations.AllowOrphanedOverrideStatus do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute(
        ~s(ALTER TABLE "#{schema}".solution_pack_overrides DROP CONSTRAINT solution_pack_overrides_status_check)
      )

      execute("""
      ALTER TABLE "#{schema}".solution_pack_overrides
        ADD CONSTRAINT solution_pack_overrides_status_check
        CHECK (status IN ('active', 'retired', 'orphaned'))
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM "#{schema}".solution_pack_overrides WHERE status = 'orphaned') THEN
          RAISE EXCEPTION 'orphaned override rows exist; they are history and are not deleted';
        END IF;
      END
      $$
      """)

      execute(
        ~s(ALTER TABLE "#{schema}".solution_pack_overrides DROP CONSTRAINT solution_pack_overrides_status_check)
      )

      execute("""
      ALTER TABLE "#{schema}".solution_pack_overrides
        ADD CONSTRAINT solution_pack_overrides_status_check
        CHECK (status IN ('active', 'retired'))
      """)
    end
  end
end
