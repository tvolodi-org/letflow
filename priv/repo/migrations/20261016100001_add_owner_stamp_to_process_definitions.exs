# Letflow.Repo.Migrations.AddOwnerStampToProcessDefinitions
#
# GH #2590 / REQ-501 PR R2 (decision 0054 D6, design
# lib/letflow/design/gh2590-req501-module-write-handlers.md 4.8, 4.10, D-R.8, D-R.15).
#
# Adds the four-column ownership stamp of a module-shipped process definition VERSION:
# `owner_module`, `owner_module_version`, `owner_manifest_hash` (the module's manifest hash
# at install) and `owner_body_hash` (the canonical hash of the definition graph at stamping,
# `Letflow.Definitions.OwnerStamp.graph_hash/1`). All NULL, no default and NO backfill: every
# existing row, and every tenant-created, edited, imported, promoted or rolled-back version,
# is unstamped.
#
# The stamp is written ONLY by the INSERT of `Letflow.Definitions.create_owned/3` (caller:
# `Letflow.Definitions.SolutionPack`, from `Letflow.Modules.Installs`); no changeset casts it.
# Two database guards back that up:
#
#   * CHECK `process_definitions_owner_stamp_all_or_none`: either all four columns are NULL
#     or all four are set.
#   * BEFORE UPDATE trigger `process_definitions_owner_stamp_immutable`: refuses ANY update
#     that changes an `owner_*` column (NULL -> value as well as value -> anything), and on a
#     stamped row any change of `graph`. Status flips, `activated_by`, `sequence_number` and
#     `updated_at` pass. There is no "one-time stamp" exception: the stamp is in the INSERT.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# Existing tenants receive the columns through the boot-time replay.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7); the only interpolation
# is the schema name from `prefix()`. Reversible: every `execute/2` carries its down.
defmodule Letflow.Repo.Migrations.AddOwnerStampToProcessDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:process_definitions, prefix: schema) do
        add :owner_module, :string, size: 255
        add :owner_module_version, :string, size: 255
        add :owner_manifest_hash, :string, size: 64
        add :owner_body_hash, :string, size: 64
      end

      create constraint(:process_definitions, :process_definitions_owner_stamp_all_or_none,
               check: """
               (owner_module IS NULL AND owner_module_version IS NULL
                  AND owner_manifest_hash IS NULL AND owner_body_hash IS NULL)
               OR
               (owner_module IS NOT NULL AND owner_module_version IS NOT NULL
                  AND owner_manifest_hash IS NOT NULL AND owner_body_hash IS NOT NULL)
               """,
               prefix: schema
             )

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".process_definitions_owner_stamp_guard() RETURNS trigger AS $$
        BEGIN
          IF NEW.owner_module IS DISTINCT FROM OLD.owner_module
             OR NEW.owner_module_version IS DISTINCT FROM OLD.owner_module_version
             OR NEW.owner_manifest_hash IS DISTINCT FROM OLD.owner_manifest_hash
             OR NEW.owner_body_hash IS DISTINCT FROM OLD.owner_body_hash THEN
            RAISE EXCEPTION 'process_definitions.owner_* is immutable';
          END IF;

          IF OLD.owner_module IS NOT NULL AND NEW.graph IS DISTINCT FROM OLD.graph THEN
            RAISE EXCEPTION 'process_definitions.graph of a module-owned version is immutable';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".process_definitions_owner_stamp_guard()
        """
      )

      execute(
        """
        CREATE TRIGGER process_definitions_owner_stamp_immutable
          BEFORE UPDATE ON "#{schema}".process_definitions
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".process_definitions_owner_stamp_guard()
        """,
        """
        DROP TRIGGER IF EXISTS process_definitions_owner_stamp_immutable ON "#{schema}".process_definitions
        """
      )
    end
  end
end
