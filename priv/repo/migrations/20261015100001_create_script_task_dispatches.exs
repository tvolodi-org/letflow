# Letflow.Repo.Migrations.CreateScriptTaskDispatches
#
# GH 2534 PR 7c-1 (decision 0053 D2, D3, D7, F-E) -- see
# lib/letflow/design/gh2534-7c-script-handler.md section 3.1 for the design.
#
# `script_task_dispatches`: one row per activation of a SERVICE_TASK bound to a tenant script
# (route `:script`). Separate from `service_task_dispatches` (C1): the HTTP table and its
# at-most-once path stay byte-unchanged. A row is `pending` -> `running` (claimed, leased,
# attempt + 1) -> `applied` | `failed` | `cancelled`, or back to `pending` on `script_busy`
# only (C5). The terminal status is written in the SAME transaction as the instance effect,
# behind a CAS on (id, instance_id, node_id, attempt, status = 'running') (C4).
#
# Every column is value-free (section 7.1): identity, codes, counters and timestamps only. No
# input, output, fail detail or source is ever stored here.
#
# The guard trigger (ERRCODE 'LF001') refuses any UPDATE of a row already terminal and any
# change of the identity columns. DELETE is not refused (a future instance purge must be able
# to remove rows).
#
# The timestamp follows 20261015025331 (role_scope_grants on main) so tenant migrations stay
# ordered; the design's 20261015000001 placeholder is taken as "next free" (design 3.1).
#
# PLACEMENT: per-tenant (0006 D2: no tenant_id column).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.CreateScriptTaskDispatches do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:script_task_dispatches, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :instance_id, :binary_id, null: false
        add :token_id, :binary_id, null: false
        add :node_id, :text, null: false
        add :script_key, :text, null: false
        add :script_version, :integer, null: false
        add :script_sha256, :text, null: false
        add :status, :text, null: false, default: "pending"
        add :attempt, :integer, null: false, default: 0
        add :busy_retries, :integer, null: false, default: 0
        add :sweep_failures, :integer, null: false, default: 0
        add :next_attempt_at, :utc_datetime_usec, null: false
        add :claimed_at, :utc_datetime_usec
        add :lease_expires_at, :utc_datetime_usec
        add :claimed_by, :text
        add :event_time, :utc_datetime_usec, null: false
        add :triggering_user_id, :binary_id
        add :outcome, :text
        add :outcome_detail, :text
        add :finished_at, :utc_datetime_usec

        timestamps(type: :utc_datetime_usec)
      end

      create constraint(:script_task_dispatches, :script_task_dispatches_key_format,
               check: "script_key ~ '^[a-z][a-z0-9_]{0,63}$'",
               prefix: schema
             )

      create constraint(:script_task_dispatches, :script_task_dispatches_version_positive,
               check: "script_version > 0",
               prefix: schema
             )

      create constraint(:script_task_dispatches, :script_task_dispatches_sha256_format,
               check: "script_sha256 ~ '^[0-9a-f]{64}$'",
               prefix: schema
             )

      create constraint(:script_task_dispatches, :script_task_dispatches_status,
               check: "status IN ('pending', 'running', 'applied', 'failed', 'cancelled')",
               prefix: schema
             )

      create constraint(:script_task_dispatches, :script_task_dispatches_counters,
               check: "attempt >= 0 AND busy_retries >= 0 AND sweep_failures >= 0",
               prefix: schema
             )

      create constraint(:script_task_dispatches, :script_task_dispatches_running_lease,
               check: "status <> 'running' OR lease_expires_at IS NOT NULL",
               prefix: schema
             )

      create constraint(:script_task_dispatches, :script_task_dispatches_claimed_by_length,
               check: "char_length(claimed_by) <= 255",
               prefix: schema
             )

      create constraint(:script_task_dispatches, :script_task_dispatches_outcome,
               check:
                 "outcome IN ('ok', 'script_error', 'budget_exceeded', 'memory_limit_exceeded', " <>
                   "'output_invalid', 'timeout', 'script_failed', 'script_rejected', 'script_busy')",
               prefix: schema
             )

      create constraint(:script_task_dispatches, :script_task_dispatches_outcome_detail_format,
               check: "outcome_detail ~ '^[a-z][a-z0-9_]{0,63}$'",
               prefix: schema
             )

      create index(:script_task_dispatches, [:next_attempt_at],
               where: "status = 'pending'",
               name: :script_task_dispatches_pending_due_idx,
               prefix: schema
             )

      create index(:script_task_dispatches, [:lease_expires_at],
               where: "status = 'running'",
               name: :script_task_dispatches_running_lease_idx,
               prefix: schema
             )

      create index(:script_task_dispatches, [:instance_id],
               name: :script_task_dispatches_instance_idx,
               prefix: schema
             )

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".script_task_dispatches_guard() RETURNS trigger AS $$
        BEGIN
          IF OLD.status IN ('applied', 'failed', 'cancelled') THEN
            RAISE EXCEPTION 'script_task_dispatches: a terminal row is immutable'
              USING ERRCODE = 'LF001';
          END IF;

          IF NEW.id IS DISTINCT FROM OLD.id
             OR NEW.instance_id IS DISTINCT FROM OLD.instance_id
             OR NEW.token_id IS DISTINCT FROM OLD.token_id
             OR NEW.node_id IS DISTINCT FROM OLD.node_id
             OR NEW.script_key IS DISTINCT FROM OLD.script_key
             OR NEW.script_version IS DISTINCT FROM OLD.script_version
             OR NEW.script_sha256 IS DISTINCT FROM OLD.script_sha256
             OR NEW.event_time IS DISTINCT FROM OLD.event_time
             OR NEW.triggering_user_id IS DISTINCT FROM OLD.triggering_user_id THEN
            RAISE EXCEPTION 'script_task_dispatches: identity columns are immutable'
              USING ERRCODE = 'LF001';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".script_task_dispatches_guard()
        """
      )

      execute(
        """
        CREATE TRIGGER script_task_dispatches_guard
          BEFORE UPDATE ON "#{schema}".script_task_dispatches
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".script_task_dispatches_guard()
        """,
        """
        DROP TRIGGER IF EXISTS script_task_dispatches_guard ON "#{schema}".script_task_dispatches
        """
      )
    end
  end
end
