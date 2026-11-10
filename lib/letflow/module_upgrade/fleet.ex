defmodule Letflow.ModuleUpgrade.Fleet do
  @moduledoc """
  RU-S6 (decision 0055 fact 10, T-1594): the fleet driver. A platform operator rolls the compiled
  version of one module out to every active tenant that has it installed, one tenant at a time,
  through the same plan/apply path a tenant admin uses (`Letflow.Modules.UpgradePlan.plan/3` and
  `Letflow.ModuleUpgrade.Apply.apply_upgrade/4`, both with `prefix:`).

  A plain transactional context, no process per rollout (REQ-045). Each call of `start/2` or
  `resume/2` works through a bounded batch (25 outcomes) and returns the current state; the
  caller repeats until the rollout is `completed` or `halted`.

  State (global tables, `Letflow.Platform.ModuleRollout.{Rollout,Outcome}`): one rollout per
  `(module_id, to_version)`, one outcome per tenant (`pending`, `running`, `succeeded`, `failed`,
  `skipped`). A tenant outcome is claimed with one atomic `update_all`, so two concurrent callers
  never process the same tenant; a `running` claim older than 15 minutes (a crashed caller) is
  claimable again.

  Halt: after `Letflow.ModuleUpgrade.Settings.rollout_halt_after/0` consecutive failed tenants
  (a success or a skip resets the count) the rollout is `halted` and the remaining outcomes stay
  `pending`. `resume/2` reopens a halted rollout, resets the count and retries `failed` and
  `pending` outcomes. Resume also reopens a `completed` rollout that still has `failed` outcomes.

  The driver never sends `ack_destructive`: a plan that needs an acknowledgement is refused by
  Apply and recorded as a `failed` outcome with Apply's refusal code; the tenant admin decides. A
  tenant whose newest finished journal row is a rollback is skipped (`rolled_back`): an admin's
  rollback is not undone by the fleet.

  Tenancy (INV-1): every tenant read and write goes through the `schema_name` of the tenant
  registry row as `prefix:`; the outcome rows hold ids and codes only. No branch can crash the
  batch (INV-8): each tenant step is wrapped, a raise is a `failed` outcome with `internal_error`.
  The caller is the platform operator (route gate `:ModuleRolloutsManage`); the journal actor is
  their user id.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Identity.Tenant
  alias Letflow.ModuleUpgrade.Apply
  alias Letflow.ModuleUpgrade.Settings
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Modules.UpgradePlan
  alias Letflow.Platform.ModuleRollout.Outcome
  alias Letflow.Platform.ModuleRollout.Rollout
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  @batch 25
  @stale_minutes 15
  @list_limit 50

  @type result :: %{rollout: Rollout.t(), outcomes: [Outcome.t()]}

  @doc "Outcomes processed per call."
  @spec batch_size() :: pos_integer()
  def batch_size, do: Application.get_env(:letflow, :module_rollout_batch, @batch)

  @doc """
  Starts (or continues) the rollout of the compiled version of `module_id`, then runs one batch.
  A repeat call returns the same rollout. A halted rollout is not run by `start/2` (use `resume/2`).

  `opts[:only_tenants]` (a list of tenant ids) narrows the tenants a call registers and works on;
  no route passes it, it exists for tests that share a database cluster with other tenants.
  """
  @spec start(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, result()} | {:error, :unknown_module}
  def start(module_id, actor_id, opts \\ []) when is_binary(module_id) do
    case Catalog.fetch(module_id) do
      {:ok, entry} ->
        rollout = get_or_create(module_id, entry.manifest().version, actor_id)
        register_outcomes(rollout, opts)
        reopen_if_new_work(rollout.id)
        run_batch(rollout.id, actor_id, [:pending], opts)
        {:ok, state(rollout.id)}

      _other ->
        {:error, :unknown_module}
    end
  end

  @doc """
  Resumes a rollout: a halted one is reopened with the failure count reset; `failed`, `pending`
  and stale `running` outcomes are claimable. `{:error, :version_superseded}` when the running
  build no longer carries the rollout's version (nothing is touched).
  """
  @spec resume(String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, result()} | {:error, :not_found | :version_superseded}
  def resume(id, actor_id, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Rollout{} = rollout <- Repo.get(Rollout, uuid),
         :ok <- current_version?(rollout) do
      register_outcomes(rollout, opts)
      reopen_for_resume(rollout)
      run_batch(rollout.id, actor_id, [:pending, :failed], opts)
      {:ok, state(rollout.id)}
    else
      {:error, :version_superseded} -> {:error, :version_superseded}
      _other -> {:error, :not_found}
    end
  end

  @doc "The rollout and its outcomes (read-only)."
  @spec status(String.t()) :: {:ok, result()} | {:error, :not_found}
  def status(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Rollout{} <- Repo.get(Rollout, uuid) do
      {:ok, state(uuid)}
    else
      _other -> {:error, :not_found}
    end
  end

  @doc "The latest rollouts, newest first, with outcome counts per status (read-only)."
  @spec list() :: [%{rollout: Rollout.t(), counts: %{String.t() => non_neg_integer()}}]
  def list do
    rollouts =
      Repo.all(from(r in Rollout, order_by: [desc: r.started_at, desc: r.id], limit: @list_limit))

    ids = Enum.map(rollouts, & &1.id)

    counts =
      from(o in Outcome,
        where: o.rollout_id in ^ids,
        group_by: [o.rollout_id, o.status],
        select: {o.rollout_id, o.status, count(o.id)}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_id, status, n} -> {status, n} end)

    Enum.map(rollouts, fn r ->
      %{rollout: r, counts: Map.new(Map.get(counts, r.id, []))}
    end)
  end

  # ── rollout rows ─────────────────────────────────────────────────────────────────────────

  defp get_or_create(module_id, to_version, actor_id) do
    Repo.insert_all(
      Rollout,
      [
        %{
          id: Ecto.UUID.generate(),
          module_id: module_id,
          to_version: to_version,
          status: "running",
          halt_after: Settings.rollout_halt_after(),
          consecutive_failures: 0,
          started_by: actor_id,
          started_at: now()
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:module_id, :to_version]
    )

    Repo.one!(
      from(r in Rollout, where: r.module_id == ^module_id and r.to_version == ^to_version)
    )
  end

  defp current_version?(%Rollout{module_id: module_id, to_version: to_version}) do
    case Catalog.fetch(module_id) do
      {:ok, entry} ->
        if entry.manifest().version == to_version, do: :ok, else: {:error, :version_superseded}

      _other ->
        {:error, :version_superseded}
    end
  end

  # One pending outcome per active tenant with a registered schema; later tenants are picked up
  # by the next call.
  defp register_outcomes(%Rollout{id: rollout_id}, opts) do
    tenant_ids =
      Repo.all(
        from(t in Tenant,
          join: r in Registration,
          on: r.tenant_id == t.id,
          where: t.status == :active,
          select: t.id
        )
      )
      |> only(opts)

    rows =
      Enum.map(tenant_ids, fn tenant_id ->
        %{
          id: Ecto.UUID.generate(),
          rollout_id: rollout_id,
          tenant_id: tenant_id,
          status: "pending"
        }
      end)

    rows
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Outcome, chunk,
        on_conflict: :nothing,
        conflict_target: [:rollout_id, :tenant_id]
      )
    end)
  end

  # A completed rollout that gained a pending outcome (a tenant provisioned later) runs again.
  defp only(tenant_ids, opts) do
    case Keyword.get(opts, :only_tenants) do
      nil -> tenant_ids
      only -> Enum.filter(tenant_ids, &(&1 in only))
    end
  end

  defp reopen_if_new_work(rollout_id) do
    pending? =
      Repo.exists?(
        from(o in Outcome, where: o.rollout_id == ^rollout_id and o.status == "pending")
      )

    if pending? do
      Repo.update_all(
        from(r in Rollout, where: r.id == ^rollout_id and r.status == "completed"),
        set: [status: "running", completed_at: nil]
      )
    end

    :ok
  end

  defp reopen_for_resume(%Rollout{id: rollout_id}) do
    claimable? =
      Repo.exists?(
        from(o in Outcome,
          where: o.rollout_id == ^rollout_id and o.status in ["pending", "failed", "running"]
        )
      )

    if claimable? do
      Repo.update_all(
        from(r in Rollout, where: r.id == ^rollout_id and r.status in ["halted", "completed"]),
        set: [status: "running", consecutive_failures: 0, halted_at: nil, completed_at: nil]
      )
    end

    :ok
  end

  defp state(rollout_id) do
    %{
      rollout: Repo.get!(Rollout, rollout_id),
      outcomes:
        Repo.all(
          from(o in Outcome, where: o.rollout_id == ^rollout_id, order_by: [asc: o.tenant_id])
        )
    }
  end

  # ── the batch ────────────────────────────────────────────────────────────────────────────

  defp run_batch(rollout_id, actor_id, statuses, opts) do
    if running?(rollout_id) do
      ids = candidate_ids(rollout_id, Enum.map(statuses, &Atom.to_string/1), opts)

      Enum.reduce_while(ids, :ok, fn id, :ok ->
        if running?(rollout_id) do
          process_outcome(rollout_id, id, actor_id)
          {:cont, :ok}
        else
          {:halt, :ok}
        end
      end)

      maybe_complete(rollout_id)
    end

    :ok
  end

  defp running?(rollout_id) do
    Repo.exists?(from(r in Rollout, where: r.id == ^rollout_id and r.status == "running"))
  end

  defp stale_before do
    NaiveDateTime.add(now(), -@stale_minutes * 60, :second)
  end

  defp candidate_ids(rollout_id, statuses, opts) do
    stale = stale_before()

    query =
      from(o in Outcome,
        where:
          o.rollout_id == ^rollout_id and
            (o.status in ^statuses or (o.status == "running" and o.attempted_at < ^stale)),
        order_by: [asc: o.tenant_id],
        limit: ^batch_size(),
        select: o.id
      )

    query =
      case Keyword.get(opts, :only_tenants) do
        nil -> query
        only -> from(o in query, where: o.tenant_id in ^only)
      end

    Repo.all(query)
  end

  # Atomic claim: a concurrent caller gets zero rows and skips the tenant.
  defp claim(id) do
    stale = stale_before()

    query =
      from(o in Outcome,
        where:
          o.id == ^id and
            (o.status in ["pending", "failed"] or
               (o.status == "running" and o.attempted_at < ^stale)),
        select: o
      )

    case Repo.update_all(query, set: [status: "running", attempted_at: now()]) do
      {1, [outcome]} -> {:ok, outcome}
      _other -> :lost
    end
  end

  defp process_outcome(rollout_id, id, actor_id) do
    with {:ok, outcome} <- claim(id) do
      {status, code, plan_hash} = tenant_step(rollout_id, outcome, actor_id)

      Repo.update_all(from(o in Outcome, where: o.id == ^outcome.id),
        set: [status: status, error_code: code, plan_hash: plan_hash, completed_at: now()]
      )

      count_failures(rollout_id, status)
    end

    :ok
  end

  defp count_failures(rollout_id, "failed") do
    Repo.update_all(from(r in Rollout, where: r.id == ^rollout_id),
      inc: [consecutive_failures: 1]
    )

    Repo.update_all(
      from(r in Rollout,
        where:
          r.id == ^rollout_id and r.status == "running" and r.consecutive_failures >= r.halt_after
      ),
      set: [status: "halted", halted_at: now()]
    )
  end

  defp count_failures(rollout_id, _ok_or_skipped) do
    Repo.update_all(from(r in Rollout, where: r.id == ^rollout_id),
      set: [consecutive_failures: 0]
    )
  end

  defp maybe_complete(rollout_id) do
    open? =
      Repo.exists?(
        from(o in Outcome,
          where: o.rollout_id == ^rollout_id and o.status in ["pending", "running"]
        )
      )

    if not open? do
      Repo.update_all(
        from(r in Rollout, where: r.id == ^rollout_id and r.status == "running"),
        set: [status: "completed", completed_at: now()]
      )
    end

    :ok
  end

  # ── one tenant (the shape of Letflow.ModuleUpgrade.Boot.upgrade_one/4) ────────────────────

  defp tenant_step(rollout_id, %Outcome{tenant_id: tenant_id}, actor_id) do
    rollout = Repo.get!(Rollout, rollout_id)

    case tenant_schema(tenant_id) do
      nil -> {"skipped", "tenant_inactive", nil}
      schema -> upgrade(rollout, tenant_id, schema, actor_id)
    end
  rescue
    _exception -> failed(tenant_id, "internal_error")
  catch
    _kind, _reason -> failed(tenant_id, "internal_error")
  end

  defp tenant_schema(tenant_id) do
    Repo.one(
      from(t in Tenant,
        join: r in Registration,
        on: r.tenant_id == t.id,
        where: t.id == ^tenant_id and t.status == :active,
        select: r.schema_name
      )
    )
  end

  defp upgrade(%Rollout{module_id: module_id} = rollout, tenant_id, schema, actor_id) do
    row =
      Repo.one(
        from(m in TenantModule, where: m.module_id == ^module_id and m.status == :active),
        prefix: schema
      )

    cond do
      is_nil(row) -> {"skipped", "not_installed", nil}
      current?(row) -> {"skipped", "up_to_date", nil}
      rolled_back?(schema, module_id) -> {"skipped", "rolled_back", nil}
      true -> plan_and_apply(rollout, tenant_id, schema, actor_id)
    end
  rescue
    _exception -> failed(tenant_id, "tenant_unreadable")
  end

  defp current?(%TenantModule{module_id: module_id} = row) do
    with {:ok, entry} <- Catalog.fetch(module_id),
         {:ok, hash} <- Catalog.manifest_hash(entry) do
      row.version == entry.manifest().version and row.manifest_hash == hash
    else
      _other -> true
    end
  end

  defp rolled_back?(schema, module_id) do
    latest =
      from(u in TenantModuleUpgrade,
        where: u.module_id == ^module_id and u.state == :done and not is_nil(u.finished_at),
        order_by: [desc: u.finished_at, desc: u.id],
        limit: 1,
        select: u.kind
      )
      |> Repo.one(prefix: schema)

    latest == :rollback
  end

  defp plan_and_apply(%Rollout{module_id: module_id} = rollout, tenant_id, schema, actor_id) do
    case UpgradePlan.plan(module_id, actor_id, prefix: schema) do
      {:ok, %{"up_to_date" => true}} ->
        {"skipped", "up_to_date", nil}

      {:ok, %{"plan_hash" => plan_hash}} ->
        params = %{"rationale" => "fleet rollout " <> rollout.id, "plan_hash" => plan_hash}

        case Apply.apply_upgrade(module_id, actor_id, params, prefix: schema) do
          {:ok, _body} ->
            {"succeeded", nil, plan_hash}

          {:error, {:failed, code}} ->
            log_failure(tenant_id, module_id, code)
            {"failed", clip(code), plan_hash}

          {:error, {:refused, code, _detail}} ->
            log_failure(tenant_id, module_id, code)
            {"failed", clip(code), plan_hash}

          {:error, :not_found} ->
            {"skipped", "not_installed", nil}

          {:error, other} ->
            log_failure(tenant_id, module_id, to_string(other))
            {"failed", clip(to_string(other)), plan_hash}
        end

      {:ok, _report} ->
        failed(tenant_id, "plan_failed")

      {:error, :plan_failed} ->
        failed(tenant_id, "plan_failed")

      {:error, _not_installed_or_unknown} ->
        {"skipped", "not_installed", nil}
    end
  end

  defp failed(tenant_id, code) do
    Logger.error("module rollout: tenant step failed", tenant_id: tenant_id, code: code)
    {"failed", code, nil}
  end

  defp log_failure(tenant_id, module_id, code) do
    Logger.error("module rollout: upgrade failed",
      tenant_id: tenant_id,
      module_id: module_id,
      code: code
    )
  end

  defp clip(code) when is_binary(code), do: String.slice(code, 0, 64)

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
