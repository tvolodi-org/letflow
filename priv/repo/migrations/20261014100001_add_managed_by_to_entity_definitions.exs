# Letflow.Repo.Migrations.AddManagedByToEntityDefinitions
#
# REQ-496 / GH #2530 (decision 0050 D7) -- see
# lib/letflow/design/req496-managed-by-and-scope-node-paths.md section 2.1 for the design.
#
# `managed_by` names the module that owns an entity type. It is a COLUMN, never a key of the
# tenant-writable `definition_json`, so no HTTP body or pack document can carry it into storage
# (design D1). Existing rows stay NULL (unmanaged).
#
# IMMUTABILITY (design D3) -- enforced in the DATABASE: a BEFORE UPDATE trigger refuses any change
# of `managed_by` (either direction) and, on a stamped row, any change of `name` or `tenant_id`;
# a BEFORE DELETE trigger refuses deleting a stamped row. Status flips leave `managed_by` unchanged
# and pass. Same per-schema trigger-function pattern as
# 20260830020001_create_audit_entries_tenant_scoped.exs.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.AddManagedByToEntityDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:entity_definitions, prefix: schema) do
        add :managed_by, :text
      end

      # Partial: serves every `Letflow.Entities.ManagedTypes.owner_of/2` lookup.
      create index(:entity_definitions, [:tenant_id, :name],
               name: :entity_definitions_managed_by_name_idx,
               where: "managed_by IS NOT NULL",
               prefix: schema
             )

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".entity_definitions_managed_by_guard() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            IF OLD.managed_by IS NOT NULL THEN
              RAISE EXCEPTION 'entity_definitions.managed_by is immutable';
            END IF;
            RETURN OLD;
          END IF;

          IF NEW.managed_by IS DISTINCT FROM OLD.managed_by
             OR (OLD.managed_by IS NOT NULL
                 AND (NEW.name IS DISTINCT FROM OLD.name
                      OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id)) THEN
            RAISE EXCEPTION 'entity_definitions.managed_by is immutable';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".entity_definitions_managed_by_guard()
        """
      )

      execute(
        """
        CREATE TRIGGER entity_definitions_managed_by_no_update
          BEFORE UPDATE ON "#{schema}".entity_definitions
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".entity_definitions_managed_by_guard()
        """,
        """
        DROP TRIGGER IF EXISTS entity_definitions_managed_by_no_update ON "#{schema}".entity_definitions
        """
      )

      execute(
        """
        CREATE TRIGGER entity_definitions_managed_by_no_delete
          BEFORE DELETE ON "#{schema}".entity_definitions
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".entity_definitions_managed_by_guard()
        """,
        """
        DROP TRIGGER IF EXISTS entity_definitions_managed_by_no_delete ON "#{schema}".entity_definitions
        """
      )
    end
  end
end
