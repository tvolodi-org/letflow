# Letflow.Repo.Migrations.AllowExamManagedByStamp
#
# GH #2596 -- see lib/letflow/design/gh2596-exam-managed-types.md section 4.
#
# THE SINGLE EXCEPTION TO REQ-496 D3 IMMUTABILITY (decision 0050 D7). D3 says the `managed_by`
# stamp is written only at insert and the database refuses any later change. Exam installs that
# predate the exam manifest's `manages_entity_types` hold NULL on their six runtime definition
# rows, so the platform needs ONE deliberate way to stamp them. This migration replaces the
# trigger function `entity_definitions_managed_by_guard()` (both existing triggers keep
# pointing at it) with a version that adds exactly one guarded branch to the UPDATE path. The
# change is allowed only when ALL hold:
#
#   1. OLD.managed_by IS NULL and NEW.managed_by = 'exam' (NULL -> 'exam' only: never a change of
#      an existing stamp, never a clear, never another module id);
#   2. NEW.name is one of the six runtime names below, a literal array in the function (the ten
#      authoring names and every other name can never be stamped, whatever the application does);
#   3. current_setting('letflow.managed_by_stamp', true) = 'exam' (a transaction-local setting;
#      unset or '' keeps the branch closed);
#   4. the row is otherwise unchanged: to_jsonb(NEW) - 'managed_by' = to_jsonb(OLD) - 'managed_by'.
#
# The ONLY permitted opener of the setting is `Letflow.Entities.ManagedTypes.Stamp` (a tripwire
# test pins this; it is not a boundary against raw SQL run as the application DB role, exactly
# as before this migration). The DELETE branch is unchanged. Extending the frozen name array
# later (for example when the authoring types become managed) is a NEW reviewed migration.
# F-RETIRE: once every environment is stamped, a later migration should restore the previous
# function body and retire this exception.
#
# `down` restores the previous function body byte-for-byte (copied from
# 20261014100001_add_managed_by_to_entity_definitions.exs). It does NOT unstamp rows: stamps are
# immutable by design.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.AllowExamManagedByStamp do
  use Ecto.Migration

  # The frozen runtime names; equal to `Letflow.Entities.ManagedTypes.Stamp`'s list (test T-10).
  @stamp_names ~w(certificate session session_answer session_event session_question session_question_score)

  @doc "The six runtime entity type names the stamp exception can open for."
  @spec stamp_names() :: [String.t()]
  def stamp_names, do: @stamp_names

  def up do
    if prefix() do
      schema = prefix()
      names = Enum.map_join(@stamp_names, ", ", &"'#{&1}'")

      execute("""
      CREATE OR REPLACE FUNCTION "#{schema}".entity_definitions_managed_by_guard() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          IF OLD.managed_by IS NOT NULL THEN
            RAISE EXCEPTION 'entity_definitions.managed_by is immutable';
          END IF;
          RETURN OLD;
        END IF;

        -- GH #2596: the single exception (see the migration header).
        IF OLD.managed_by IS NULL
           AND NEW.managed_by = 'exam'
           AND NEW.name = ANY (ARRAY[#{names}]::text[])
           AND current_setting('letflow.managed_by_stamp', true) = 'exam'
           AND (to_jsonb(NEW) - 'managed_by') = (to_jsonb(OLD) - 'managed_by') THEN
          RETURN NEW;
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
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute("""
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
      """)
    end
  end
end
