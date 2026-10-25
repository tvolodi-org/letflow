defmodule Letflow.ScheduledJobs do
  @moduledoc """
  REQ-561 / GH #3194 -- tenant-defined scheduled jobs: the context that stores and edits them.

  A scheduled job is a row in the tenant's own schema (`scheduled_jobs`) that names a published
  process definition, a variables map, an optional scope node, an interval and a UTC anchor.
  `Letflow.Scheduler.ScheduledJobSweep` runs the due ones on the existing
  `Letflow.Scheduler.Poller` tick by calling `Letflow.Engine.create/2`; nothing in a job is ever
  evaluated (no source, expression, URL or shell), so a job can start a process and do nothing else.

  ## Feature flag

  `enabled?/0` reads `config :letflow, :scheduled_jobs, enabled: false` fresh on every call. It is
  off by default because a job starts work unattended with the authority of the user who created
  it, so a platform operator opts in. While it is false the sweep neither claims nor queries
  anything. (The management routes and the route half of the flag are a follow-up slice, REQ-561
  part 2: the permission, the router and the cross-tenant suite.)

  ## What this module does NOT decide

  The functions take an already-authorized `actor_id`. Who may create, edit, enable or disable a job
  (a new TENANT_ADMIN-only permission, plus `:InstancesStart` and the scope rule at create and
  enable) is decided by the caller, which is the router of part 2. The sweep re-checks the creating
  user at every run (`:InstancesStart` and the scope rule), so a job cannot outlive the right to
  start the process.

  ## Tenancy (INV-1, INV-6)

  Every function takes the tenant schema `prefix` and passes `prefix: prefix` to every `Repo` call.
  The tenant id is derived from the schema name, never from the attrs (`:tenant_id` in attrs is a
  validation error).

  ## Audit

  Create, update, enable, disable, automatic disable and each run write one `Letflow.Audit` entry in
  the same transaction as the row change. The entry holds the job key, the actor, the slot time, the
  outcome code and counters, and the NAMES of changed fields -- never `variables`.

  ## Errors

  `create/4` and `update/5` return `{:error, {:validation, [{field, code}]}}` on a refusal and store
  nothing (see `Letflow.ScheduledJobs.Job`); `get`/`update`/`enable`/`disable` return
  `{:error, :not_found}` for an unknown or malformed id.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Repo
  alias Letflow.ScheduledJobs.Job
  alias Letflow.ScheduledJobs.Schedule
  alias Letflow.TenantProvisioning

  @list_limit 200

  @doc "True iff the feature flag is on (`config :letflow, :scheduled_jobs, enabled: true`)."
  @spec enabled?() :: boolean()
  def enabled? do
    :letflow |> Application.get_env(:scheduled_jobs, []) |> Keyword.get(:enabled, false) == true
  end

  @doc "Creates a job (enabled) and writes its audit entry; `actor_id` becomes the run actor."
  @spec create(String.t(), map(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Job.t()} | {:error, {:validation, [Job.validation_error()]}} | {:error, term()}
  def create(prefix, attrs, actor_id, now \\ DateTime.utc_now())
      when is_binary(prefix) and is_binary(actor_id) do
    with {:ok, values} <- validate(attrs, :create),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      first_slot =
        values.anchor_at
        |> Schedule.first_slot_not_before(values.interval_minutes, Job.usec(now))
        |> Job.usec()

      fields =
        Map.merge(values, %{
          tenant_id: tenant_id,
          enabled: true,
          created_by: actor_id,
          next_run_at: first_slot,
          consecutive_failures: 0
        })

      changeset =
        %Job{}
        |> Ecto.Changeset.change(fields)
        |> Ecto.Changeset.unique_constraint(:key, name: :scheduled_jobs_key_index)

      Multi.new()
      |> Multi.insert(:job, changeset, prefix: prefix)
      |> Multi.run(:audit, fn _repo, %{job: job} ->
        Audit.insert_entry(
          Repo,
          audit_attrs("scheduled_job.created", job, actor_id, nil, %{}),
          prefix
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{job: job}} -> {:ok, job}
        {:error, :job, %Ecto.Changeset{} = cs, _} -> {:error, {:validation, changeset_errors(cs)}}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Edits `title`, `variables`, `scope_node_id`, `interval_minutes` or `anchor_at`. When the interval
  or the anchor changes, `next_run_at` is recomputed from now. The audit entry lists the changed
  field names only. A call that changes nothing writes nothing.
  """
  @spec update(String.t(), String.t(), map(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Job.t()}
          | {:error, :not_found}
          | {:error, {:validation, [Job.validation_error()]}}
          | {:error, term()}
  def update(prefix, id, attrs, actor_id, now \\ DateTime.utc_now())
      when is_binary(prefix) and is_binary(actor_id) do
    with {:ok, values} <- validate(attrs, :update),
         {:ok, uuid} <- cast_id(id) do
      decide = fn job ->
        changes = for {k, v} <- values, Map.get(job, k) != v, into: %{}, do: {k, v}

        if map_size(changes) == 0 do
          {:noop, job}
        else
          changes = maybe_reschedule(job, changes, Job.usec(now))

          {:update, changes, "scheduled_job.updated",
           %{"changed_fields" => changed_names(changes)}}
        end
      end

      locked_change(prefix, uuid, decide, actor_id)
    end
  end

  @doc "Enables a job; its `next_run_at` restarts from now and the failure counter resets."
  @spec enable(String.t(), String.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Job.t()} | {:error, :not_found} | {:error, term()}
  def enable(prefix, id, actor_id, now \\ DateTime.utc_now())
      when is_binary(prefix) and is_binary(actor_id) do
    with {:ok, uuid} <- cast_id(id) do
      decide = fn job ->
        if job.enabled and job.consecutive_failures == 0 do
          {:noop, job}
        else
          next =
            job.anchor_at
            |> Schedule.first_slot_not_before(job.interval_minutes, Job.usec(now))
            |> Job.usec()

          {:update, %{enabled: true, next_run_at: next, consecutive_failures: 0},
           "scheduled_job.enabled", %{}}
        end
      end

      locked_change(prefix, uuid, decide, actor_id)
    end
  end

  @doc "Disables a job; it stays stored and is not run."
  @spec disable(String.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, Job.t()} | {:error, :not_found} | {:error, term()}
  def disable(prefix, id, actor_id) when is_binary(prefix) and is_binary(actor_id) do
    with {:ok, uuid} <- cast_id(id) do
      decide = fn job ->
        if job.enabled,
          do: {:update, %{enabled: false}, "scheduled_job.disabled", %{}},
          else: {:noop, job}
      end

      locked_change(prefix, uuid, decide, actor_id)
    end
  end

  @doc "One job of the tenant schema, or `{:error, :not_found}` (unknown or malformed id)."
  @spec get(String.t(), String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def get(prefix, id) when is_binary(prefix) do
    with {:ok, uuid} <- cast_id(id),
         %Job{} = job <- Repo.get(Job, uuid, prefix: prefix) do
      {:ok, job}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "The tenant's jobs ordered by key (at most #{@list_limit})."
  @spec list(String.t()) :: [Job.t()]
  def list(prefix) when is_binary(prefix) do
    Repo.all(from(j in Job, order_by: [asc: j.key], limit: ^@list_limit), prefix: prefix)
  end

  @doc """
  Writes one audit entry for `job` inside the caller's `Repo.transaction/1`; rolls the transaction
  back with `{:audit_failed, reason}` when the entry cannot be written. `before_extra` is `nil` or a
  map, `after_extra` a map; neither may carry variable values.
  """
  @spec audit!(String.t(), String.t(), Job.t(), Ecto.UUID.t() | nil, map() | nil, map()) :: :ok
  def audit!(prefix, action, %Job{} = job, actor_id, before_extra, after_extra) do
    case Audit.insert_entry(
           Repo,
           audit_attrs(action, job, actor_id, before_extra, after_extra),
           prefix
         ) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  # ---------------------------------------------------------------------------

  defp validate(attrs, mode) do
    case Job.validate(attrs, mode) do
      {:ok, values} -> {:ok, values}
      {:error, errors} -> {:error, {:validation, errors}}
    end
  end

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_id), do: {:error, :not_found}

  defp maybe_reschedule(job, changes, now) do
    if Map.has_key?(changes, :interval_minutes) or Map.has_key?(changes, :anchor_at) do
      anchor = Map.get(changes, :anchor_at, job.anchor_at)
      interval = Map.get(changes, :interval_minutes, job.interval_minutes)
      next = anchor |> Schedule.first_slot_not_before(interval, now) |> Job.usec()
      Map.put(changes, :next_run_at, next)
    else
      changes
    end
  end

  defp changed_names(changes) do
    changes
    |> Map.keys()
    |> Enum.reject(&(&1 == :next_run_at))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  # One transaction: lock the row, let `decide` choose the change, apply it and audit it.
  defp locked_change(prefix, uuid, decide, actor_id) do
    result =
      Repo.transaction(fn ->
        job =
          Repo.one(from(j in Job, where: j.id == ^uuid, lock: "FOR UPDATE"), prefix: prefix) ||
            Repo.rollback(:not_found)

        case decide.(job) do
          {:noop, job} ->
            job

          {:update, changes, action, extra} ->
            updated =
              job
              |> Ecto.Changeset.change(
                Map.put(changes, :updated_at, Job.usec(DateTime.utc_now()))
              )
              |> Repo.update!(prefix: prefix)

            audit!(prefix, action, updated, actor_id, state_of(job), extra)
            updated
        end
      end)

    case result do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, reason}
    end
  end

  defp state_of(job), do: %{"enabled" => job.enabled, "interval_minutes" => job.interval_minutes}

  defp audit_attrs(action, job, actor_id, before_extra, after_extra) do
    base = %{"key" => job.key, "enabled" => job.enabled}

    %{
      actor_id: actor_id,
      action: action,
      resource_type: "scheduled_job",
      resource_id: job.id,
      before_state: before_extra && Map.merge(base, before_extra),
      after_state: Map.merge(base, after_extra)
    }
  end

  defp changeset_errors(%Ecto.Changeset{errors: errors}) do
    for {field, {_msg, opts}} <- errors do
      if Keyword.get(opts, :constraint) == :unique, do: {field, :taken}, else: {field, :invalid}
    end
  end
end
