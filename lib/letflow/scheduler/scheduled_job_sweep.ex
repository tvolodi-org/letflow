defmodule Letflow.Scheduler.ScheduledJobSweep do
  @moduledoc """
  REQ-561 / GH #3194 -- the per-tenant sweep that runs due tenant scheduled jobs
  (`Letflow.ScheduledJobs`), the ninth sweep on `Letflow.Scheduler.Poller`.

  A tenant job starts a NEW instance of a published definition and is stored and edited by the
  tenant in its own schema. A platform timer (`Letflow.Scheduler`, `Timer`) belongs to one running
  instance, is created by the engine and only wakes that instance. The record transition sweep
  (`Letflow.Scheduler.RecordDeadlineSweep`) is operator config that only moves a record's status when
  one of its datetime fields has passed.

  This module is a plain context module: no process, no state, no supervisor child, no `Task`. The
  Poller calls `run/3` once per tenant schema inside its own `run_sweep/4`, only while
  `Letflow.ScheduledJobs.enabled?/0` is true (the flag is off by default, so a false flag claims and
  queries nothing).

  ## Action (INV-3, INV-9)

  The only action is `Letflow.Engine.create/2` with the job's definition name, variables, scope node,
  the creating user as actor and the idempotency key `scheduled_job:<job id>:<slot as ISO 8601 UTC>`.
  Nothing in a job is evaluated: no source, expression, URL or shell exists in this module.

  ## Three phases per job, two transactions

  1. **Claim** (transaction): the due row is taken `FOR UPDATE SKIP LOCKED` and `next_run_at` is moved
     to the first slot after `now`, `last_run_at` to the slot that runs. A job that missed several
     slots runs ONCE for the latest slot; the missed ones are counted (`skipped_slots`), not replayed.
     A second sweep skips the locked row or finds it no longer due, so one slot starts at most one
     instance (the idempotency key is the second line of defence).
  2. **Start** (no transaction, no lock held): the actor is re-checked (active user, `:InstancesStart`,
     and the scope rule for a scoped job), then `Engine.create/2` runs. Its result is reduced to one code
     of a closed list: `ok`, `definition_not_found`, `definition_not_active`,
     `definition_needs_reactivation`, `actor_not_allowed`, `start_failed`, `raised`. The error term is
     never stored or logged. By name, `Engine.create/2` resolves only an ACTIVE definition, so an
     unknown, draft, deprecated or archived name all give `definition_not_found`;
     `definition_not_active` stays in the list for completeness and the name path never produces it.
     A definition stamped with an UNINSTALLED module (REQ-627) is unknown to this path too: such a job records
     `definition_not_found`, is auto-disabled after the 5th failure, and is not re-enabled by reactivating
     the module; re-enable it by hand.
  3. **Outcome** (transaction): `last_outcome`, the failure counter, the automatic disable after the
     5th consecutive failure and the audit entries commit together.

  Why not one transaction: Ecto nested transactions use no savepoint, so a failing start inside an
  outer transaction would roll back its own failure record. The price is a crash window between phase 1
  and phase 3: the slot is then claimed with its outcome unrecorded, so that slot is at-most-once.

  ## Test seam

  `run/3` takes `start_fun:` (default `&Letflow.Engine.create/2`). The Poller never passes it; only
  tests do, to force `start_failed` and `raised`.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Engine
  alias Letflow.Identity
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.ScheduledJobs
  alias Letflow.ScheduledJobs.Job
  alias Letflow.ScheduledJobs.Schedule
  alias Letflow.TenantProvisioning

  @default_batch_limit 100
  @disable_after 5

  @doc """
  Runs the due jobs of one tenant schema (at most #{@default_batch_limit} per call). Always returns
  `:ok`; a failure of one job is recorded on its row and the loop continues.
  """
  @spec run(String.t(), DateTime.t(), keyword()) :: :ok
  def run(tenant_schema, now \\ DateTime.utc_now(), opts \\ []) when is_binary(tenant_schema) do
    start_fun = Keyword.get(opts, :start_fun, &Engine.create/2)
    sweep_one(tenant_schema, Job.usec(now), start_fun, 0)
  end

  defp sweep_one(_schema, _now, _start_fun, count) when count >= @default_batch_limit, do: :ok

  defp sweep_one(schema, now, start_fun, count) do
    case claim(schema, now) do
      :none ->
        :ok

      {:ok, job, plan} ->
        code = start(job, plan, schema, start_fun)
        record_outcome(schema, job, plan, code)
        sweep_one(schema, now, start_fun, count + 1)

      :error ->
        :ok
    end
  end

  # Phase 1.
  defp claim(schema, now) do
    result =
      Repo.transaction(fn ->
        query =
          from(j in Job,
            where: j.enabled and j.next_run_at <= ^now,
            order_by: [asc: j.next_run_at, asc: j.id],
            limit: 1,
            lock: "FOR UPDATE SKIP LOCKED"
          )

        with %Job{} = job <- Repo.one(query, prefix: schema),
             {:ok, plan} <- Schedule.due_plan(job, now) do
          job
          |> Ecto.Changeset.change(%{
            next_run_at: Job.usec(plan.next),
            last_run_at: Job.usec(plan.slot),
            updated_at: Job.usec(DateTime.utc_now())
          })
          |> Repo.update!(prefix: schema)

          {job, plan}
        else
          _none -> :none
        end
      end)

    case result do
      {:ok, :none} -> :none
      {:ok, {job, plan}} -> {:ok, job, plan}
      {:error, _reason} -> :error
    end
  rescue
    _error ->
      Logger.warning("scheduled job claim failed", schema: schema)
      :error
  end

  # Phase 2: nothing is held here. Every exit is one code of the closed list.
  defp start(job, plan, schema, start_fun) do
    if actor_allowed?(job, schema) do
      attrs =
        %{
          definition_name: job.definition_name,
          initial_variables: job.variables,
          actor_id: job.created_by,
          idempotency_key: idempotency_key(job, plan.slot)
        }
        |> put_scope_node(job.scope_node_id)

      attrs |> start_fun.(prefix: schema) |> outcome_code()
    else
      "actor_not_allowed"
    end
  rescue
    _error -> "raised"
  catch
    _kind, _reason -> "raised"
  end

  defp put_scope_node(attrs, nil), do: attrs
  defp put_scope_node(attrs, node_id), do: Map.put(attrs, :scope_node_id, node_id)

  defp idempotency_key(job, slot), do: "scheduled_job:#{job.id}:#{DateTime.to_iso8601(slot)}"

  defp outcome_code({:ok, _result}), do: "ok"
  defp outcome_code({:error, :definition_not_found}), do: "definition_not_found"
  defp outcome_code({:error, :definition_not_active}), do: "definition_not_active"
  defp outcome_code({:error, :definition_needs_reactivation}), do: "definition_needs_reactivation"
  defp outcome_code(_other), do: "start_failed"

  # The creating user must still be active and still hold :InstancesStart (and, for a scoped job,
  # the scope rule `authorize_start_scope/2` of the instances router applies).
  defp actor_allowed?(job, schema) do
    with {:ok, user} <- Identity.get_user(job.created_by, prefix: schema),
         true <- Identity.active_user?(user),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(schema) do
      platform? = PlatformTenant.platform_tenant?(tenant_id)

      roles =
        user.id
        |> Identity.list_effective_role_names(prefix: schema)
        |> Authorization.effective_roles(platform?)

      Authorization.has_permission_in_scope?(roles, :InstancesStart, platform?) and
        scope_allowed?(job.scope_node_id, user.id, schema, platform?, roles)
    else
      _denied -> false
    end
  end

  defp scope_allowed?(nil, _user_id, _schema, _platform?, _roles), do: true

  defp scope_allowed?(node_id, user_id, schema, platform?, roles) do
    principal = %Scope.Principal{
      kind: :user,
      user_id: user_id,
      prefix: schema,
      platform_tenant?: platform?,
      roles: roles,
      grants: Scope.load_grants(user_id, schema)
    }

    match?({:allow, _why}, Scope.allowed?(principal, :InstancesStart, {:node, node_id}))
  end

  # Phase 3.
  defp record_outcome(schema, job, plan, code) do
    result =
      Repo.transaction(fn ->
        case Repo.one(from(j in Job, where: j.id == ^job.id, lock: "FOR UPDATE"), prefix: schema) do
          nil -> :gone
          %Job{} = locked -> write_outcome(schema, locked, plan, code)
        end
      end)

    with {:error, reason} <- result do
      Logger.warning("scheduled job outcome not recorded",
        schema: schema,
        job_id: job.id,
        reason: inspect(reason)
      )
    end

    if code != "ok" do
      Logger.warning("scheduled job run did not start an instance",
        schema: schema,
        job_id: job.id,
        code: code
      )
    end

    :ok
  rescue
    _error ->
      Logger.warning("scheduled job outcome not recorded", schema: schema, job_id: job.id)
      :ok
  end

  defp write_outcome(schema, job, plan, code) do
    failures = if code == "ok", do: 0, else: job.consecutive_failures + 1
    disable? = code != "ok" and failures >= @disable_after and job.enabled

    changes = %{
      last_outcome: code,
      last_outcome_details: if(plan.skipped > 0, do: %{"skipped_slots" => plan.skipped}),
      consecutive_failures: failures,
      updated_at: Job.usec(DateTime.utc_now())
    }

    changes = if disable?, do: Map.put(changes, :enabled, false), else: changes

    updated = job |> Ecto.Changeset.change(changes) |> Repo.update!(prefix: schema)

    ScheduledJobs.audit!(schema, "scheduled_job.run", updated, job.created_by, nil, %{
      "slot" => DateTime.to_iso8601(plan.slot),
      "outcome" => code,
      "skipped_slots" => plan.skipped,
      "consecutive_failures" => failures
    })

    if disable? do
      ScheduledJobs.audit!(
        schema,
        "scheduled_job.auto_disabled",
        updated,
        job.created_by,
        %{"enabled" => true},
        %{"consecutive_failures" => failures}
      )
    end

    :ok
  end
end
