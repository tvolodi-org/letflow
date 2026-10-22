# Letflow.Repo.Migrations.AddWriteClassToEntityDefinitions
#
# GH #2618 (decision 0054 D4a.2 amendment, GH #2618): the refusal of `writable_by_process` reads a
# write class of the entity type, not its name. See docs/migration/decisions/0054-process-step-writes-entity.md,
# "Amendment (GH #2618)", items 2 and 4.
#
# `write_class` is a COLUMN, never a key of the tenant-writable `definition_json`, and no route writes it
# (same reasoning as `managed_by`, REQ-496 D1). Core assigns it in `Letflow.Entities.Definitions.create_definition/3`.
#
# EXISTING ROWS: the backfill below classifies every row from the interim denied-name list it replaces
# (`lib/letflow/entities/process_writable.ex` before GH #2618), so every type that list refused stays refused.
# The rules run in order on `lower(name)`; the names and prefixes are the list's literals, copied verbatim.
#
# IMMUTABILITY: after the backfill, a BEFORE UPDATE trigger refuses any change of `write_class`. The class
# is fixed per type. `managed_by` (stamp) updates are not affected: this trigger is separate from
# the `managed_by` guard of 20261014100001.
#
# ORDER: add the nullable column, backfill, then NOT NULL and CHECK (so a partial backfill fails the migration
# instead of leaving NULL), then the trigger (created last so the backfill's UPDATE is not refused).
#
# Each step has an `up` and a matching `down`; the migration runs in one transaction per tenant schema.
#
# TENANT-SCOPED MIGRATION -- the `if prefix()` guard is MANDATORY, and so is this file's registration in
# Letflow.TenantProvisioning's @tenant_scoped_migration_manifest.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7); the only interpolation is the
# schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.AddWriteClassToEntityDefinitions do
  use Ecto.Migration

  @classes ~w(managed org_tree identity_adjacent attachment_metadata ordinary)

  def up do
    if prefix() do
      schema = prefix()

      alter table(:entity_definitions, prefix: schema) do
        add :write_class, :text
      end

      execute(backfill_sql(schema), "")

      execute(
        ~s(ALTER TABLE "#{schema}".entity_definitions ALTER COLUMN write_class SET NOT NULL),
        ""
      )

      check_sql =
        "ALTER TABLE \"#{schema}\".entity_definitions ADD CONSTRAINT entity_definitions_write_class_chk " <>
          "CHECK (write_class IN (#{class_list()}))"

      execute(
        check_sql,
        ~s(ALTER TABLE "#{schema}".entity_definitions DROP CONSTRAINT IF EXISTS entity_definitions_write_class_chk)
      )

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".entity_definitions_write_class_guard() RETURNS trigger AS $$
        BEGIN
          IF NEW.write_class IS DISTINCT FROM OLD.write_class THEN
            RAISE EXCEPTION 'entity_definitions.write_class is immutable';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".entity_definitions_write_class_guard()
        """
      )

      execute(
        """
        CREATE TRIGGER entity_definitions_write_class_no_update
          BEFORE UPDATE ON "#{schema}".entity_definitions
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".entity_definitions_write_class_guard()
        """,
        """
        DROP TRIGGER IF EXISTS entity_definitions_write_class_no_update ON "#{schema}".entity_definitions
        """
      )
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(
        ~s(DROP TRIGGER IF EXISTS entity_definitions_write_class_no_update ON "#{schema}".entity_definitions),
        ""
      )

      execute(
        ~s[DROP FUNCTION IF EXISTS "#{schema}".entity_definitions_write_class_guard()],
        ""
      )

      execute(
        ~s(ALTER TABLE "#{schema}".entity_definitions DROP CONSTRAINT IF EXISTS entity_definitions_write_class_chk),
        ""
      )

      execute(
        ~s(ALTER TABLE "#{schema}".entity_definitions ALTER COLUMN write_class DROP NOT NULL),
        ""
      )

      alter table(:entity_definitions, prefix: schema) do
        remove :write_class
      end
    end
  end

  defp class_list, do: Enum.map_join(@classes, ", ", &"'#{&1}'")

  # The interim denied-name rules (GH #2587 PR A4), as a CASE over `lower(name)`. Order matters: a
  # stamped row is `managed` whatever its name; the first matching class wins.
  defp backfill_sql(schema) do
    """
    UPDATE "#{schema}".entity_definitions SET write_class = CASE
      WHEN managed_by IS NOT NULL THEN 'managed'
      WHEN lower(name) IN ('org', 'orgs') OR starts_with(lower(name), 'org_') THEN 'org_tree'
      WHEN lower(name) IN ('user', 'users', 'role', 'roles', 'permission', 'permissions',
                           'principal', 'principals', 'group', 'groups', 'membership', 'memberships')
        OR starts_with(lower(name), 'user_') OR starts_with(lower(name), 'users_')
        OR starts_with(lower(name), 'role_') OR starts_with(lower(name), 'roles_')
        OR starts_with(lower(name), 'permission_') OR starts_with(lower(name), 'permissions_')
        OR starts_with(lower(name), 'principal_') OR starts_with(lower(name), 'principals_')
        OR starts_with(lower(name), 'group_') OR starts_with(lower(name), 'groups_')
        OR starts_with(lower(name), 'membership_') THEN 'identity_adjacent'
      WHEN lower(name) IN ('attachment', 'attachments')
        OR starts_with(lower(name), 'attachment_') OR starts_with(lower(name), 'attachments_')
        THEN 'attachment_metadata'
      ELSE 'ordinary'
    END
    """
  end
end
