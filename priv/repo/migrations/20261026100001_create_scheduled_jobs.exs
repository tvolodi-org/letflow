# Letflow.Repo.Migrations.CreateScheduledJobs
#
# REQ-561 / GH #3194 -- tenant-defined scheduled jobs: a recurring "start this published
# definition" row that `Letflow.Scheduler.ScheduledJobSweep` runs on the existing
# `Letflow.Scheduler.Poller` tick. One small table; no trigger, no function.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). The table carries
# `tenant_id uuid NOT NULL` as well. It starts empty: no existing row is altered, and no
# tenant has a job until a platform operator turns the feature on and a tenant admin creates one.
# There is deliberately NO truncate trigger: the test template reset truncates dirty tables.
#
# The CHECK constraints are defence in depth; `Letflow.ScheduledJobs.Job.validate/2` is the
# typed-error path.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateScheduledJobs do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()
      for sql <- statements(schema), do: execute(sql)
    end
  end

  def down do
    if prefix() do
      execute(~s(DROP TABLE IF EXISTS "#{prefix()}"."scheduled_jobs"))
    end
  end

  defp statements(schema) do
    [
      """
      CREATE TABLE "#{schema}".scheduled_jobs (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        key text NOT NULL,
        title text NOT NULL,
        definition_name text NOT NULL,
        variables jsonb NOT NULL DEFAULT '{}'::jsonb,
        scope_node_id text,
        interval_minutes integer NOT NULL CHECK (interval_minutes BETWEEN 5 AND 10080),
        anchor_at timestamptz NOT NULL,
        enabled boolean NOT NULL DEFAULT true,
        next_run_at timestamptz NOT NULL,
        last_run_at timestamptz,
        last_outcome text CHECK (last_outcome IN ('ok', 'definition_not_found',
          'definition_not_active', 'definition_needs_reactivation', 'actor_not_allowed',
          'start_failed', 'raised')),
        last_outcome_details jsonb,
        consecutive_failures integer NOT NULL DEFAULT 0 CHECK (consecutive_failures >= 0),
        created_by uuid NOT NULL,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """,
      ~s|CREATE UNIQUE INDEX scheduled_jobs_key_index ON "#{schema}".scheduled_jobs (key)|,
      ~s|CREATE INDEX scheduled_jobs_next_run_index ON "#{schema}".scheduled_jobs (next_run_at) WHERE enabled|
    ]
  end
end
