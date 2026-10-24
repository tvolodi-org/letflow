# Letflow.Repo.Migrations.AllowExamAuthoringManagedByStamp
#
# GH #2680 slice 3 (REQ-510). Extends the GH #2596 stamp exception (see
# `20261016120001_allow_exam_managed_by_stamp.exs` for the full rationale and the four guards)
# from the six runtime names to the sixteen names the exam module now manages: the six runtime
# types and the ten authoring types (`exam`, `exam_section`, `exam_question_rule`,
# `exam_question_rule_tag`, `exam_manual_question`, `question`, `answer_option`, `question_tag`,
# `tag`, `category`).
#
# The trigger function body is the same as #2596's, with the name array widened to sixteen. The
# guards are unchanged: NULL -> 'exam' only, the name must be in the literal array, the
# transaction-local `letflow.managed_by_stamp` setting must be 'exam' (only
# `Letflow.Entities.ManagedTypes.Stamp` sets it), and the row must be otherwise unchanged. The
# DELETE branch is unchanged. The only permitted opener is still `Stamp`, pinned by the opener scan
# test.
#
# `down` restores the SIX-name body (the body `AllowExamManagedByStamp.up` creates), so a rollback
# keeps the #2596 state and does not reopen the ten authoring names. It does NOT unstamp rows:
# stamps are immutable by design.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.AllowExamAuthoringManagedByStamp do
  use Ecto.Migration

  # The frozen sixteen names; equal to `Letflow.Entities.ManagedTypes.Stamp`'s list (test T-10).
  @stamp_names ~w(certificate session session_answer session_event session_question session_question_score exam exam_section exam_question_rule exam_question_rule_tag exam_manual_question question answer_option question_tag tag category)

  # The #2596 six, restored by `down`.
  @previous_stamp_names ~w(certificate session session_answer session_event session_question session_question_score)

  @doc "The sixteen exam entity type names the stamp exception can open for."
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

        -- GH #2596 / GH #2680 slice 3: the single exception (see the migration header).
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
      names = Enum.map_join(@previous_stamp_names, ", ", &"'#{&1}'")

      execute("""
      CREATE OR REPLACE FUNCTION "#{schema}".entity_definitions_managed_by_guard() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          IF OLD.managed_by IS NOT NULL THEN
            RAISE EXCEPTION 'entity_definitions.managed_by is immutable';
          END IF;
          RETURN OLD;
        END IF;

        -- GH #2596: the single exception, restored to its six names (GH #2680 slice 3 `down`).
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
end
