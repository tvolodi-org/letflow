defmodule Letflow.TenantProvisioner.Sweep do
  @moduledoc """
  GH #3292 / REQ-572 criteria 1, 4, 8, 19 / REQ-580 criterion 7(c) (QA only): the timer-driven sweep of
  provisioned tenants. One singleton `GenServer` (a timer, not a process per tenant or workflow
  instance; REQ-045 is untouched), started by `Letflow.Supervisor.Pollers` when `:start_provisioner_sweep`
  is on (off in `config/test.exs`). The first tick runs after one interval, not at boot. The interval is
  `Letflow.TenantProvisioner.Config.sweep_interval_minutes/0`
  (`LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES`, default 60).

  `run/1` does two steps, each tenant in its own `try`:

  1. **Expire**: a `demo` tenant whose lifecycle is `active` or `suspended` and whose `expires_at` has
     passed goes through `Letflow.TenantProvisioner.transition/2` with `:expire`, the function the expire
     route calls, so the outcome is the same.
  2. **Purge**: a tenant whose lifecycle is `suspended` or `expired`, that is not `production` (tier or
     `tenant_type`), and whose reference time (`expires_at` when expired, `deletion_requested_at` when
     suspended) plus the retention has passed goes through `Letflow.TenantPurge.purge/3` with trigger
     `:sweep`. `purge/3` re-checks eligibility under the row lock.

  Never selected: an active tenant (unless its `expires_at` has passed, then only step 1), a suspended
  tenant with neither `deletion_requested_at` nor `expires_at`, a production tenant, a purged one.

  ## Invariants

  * INV-1/6: the sweep builds no schema name or prefix; it passes only ids read from the global
    `tenant_lifecycles` table to the two functions that derive everything from the locked row.
  * INV-8: a tenant that fails (a raise, `:purge_failed`, `:internal`) is logged by tenant id, step and
    exception class only, and the sweep goes on. Not-found and conflict results (another caller got there
    first) are counted as skipped and not logged.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioner
  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantPurge

  @type counters :: %{
          expired: non_neg_integer(),
          purged: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms) || Config.sweep_interval_minutes() * 60_000
    schedule(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:tick, %{interval_ms: interval_ms} = state) do
    try do
      run()
    rescue
      exception ->
        Logger.error("provisioner sweep tick failed (exception=#{inspect(exception.__struct__)})")
    catch
      kind, _reason ->
        Logger.error("provisioner sweep tick failed (kind=#{inspect(kind)})")
    end

    schedule(interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  @doc """
  One sweep. `opts`: `now:` (the clock, default the real one); `expire:` and `purge:` (replacements of
  `TenantProvisioner.transition/2` and `TenantPurge.purge/3`, a seam for the failure test only; the
  `GenServer` always calls `run/0`).
  """
  @spec run(keyword()) :: counters()
  def run(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    expire = Keyword.get(opts, :expire, &TenantProvisioner.transition/2)
    purge = Keyword.get(opts, :purge, &TenantPurge.purge/3)

    counters = %{expired: 0, purged: 0, skipped: 0, failed: 0}

    counters =
      now
      |> expirable_ids()
      |> Enum.reduce(counters, fn id, acc ->
        guarded(id, :expire, acc, fn -> expire.(id, :expire) end, fn
          {:ok, _moved} -> :expired
          {:error, reason} when reason in [:not_found, :conflict] -> :skipped
          _other -> :failed
        end)
      end)

    now
    |> purgeable_ids()
    |> Enum.reduce(counters, fn id, acc ->
      guarded(id, :purge, acc, fn -> purge.(id, :sweep, now: now) end, fn
        {:ok, :purged} -> :purged
        {:ok, :already_purged} -> :skipped
        {:error, reason} when reason in [:not_found, :not_eligible] -> :skipped
        _other -> :failed
      end)
    end)
  end

  defp guarded(id, step, counters, call, classify) do
    outcome =
      try do
        classify.(call.())
      rescue
        exception ->
          log_failure(id, step, inspect(exception.__struct__))
          :failed
      catch
        kind, _reason ->
          log_failure(id, step, inspect(kind))
          :failed
      else
        :failed ->
          log_failure(id, step, "error_result")
          :failed

        other ->
          other
      end

    Map.update!(counters, outcome, &(&1 + 1))
  end

  # Id, step and exception class (or a fixed word) only: no tenant data (INV-8).
  defp log_failure(id, step, reason) do
    Logger.error(
      "provisioner sweep failed for tenant (tenant_id=#{inspect(id)}, step=#{step}, reason=#{reason})"
    )
  end

  defp expirable_ids(now) do
    Repo.all(
      from(l in Lifecycle,
        join: t in Tenant,
        on: t.id == l.tenant_id,
        where:
          l.tier == "demo" and l.lifecycle in ["active", "suspended"] and is_nil(l.purged_at) and
            not is_nil(l.expires_at) and l.expires_at <= ^now and t.tenant_type != "production",
        select: l.tenant_id
      )
    )
  end

  defp purgeable_ids(now) do
    retention = Config.retention_days() * 86_400

    rows =
      Repo.all(
        from(l in Lifecycle,
          join: t in Tenant,
          on: t.id == l.tenant_id,
          where:
            l.lifecycle in ["suspended", "expired"] and is_nil(l.purged_at) and
              l.tier != "production" and t.tenant_type != "production",
          select: {l.tenant_id, l.lifecycle, l.expires_at, l.deletion_requested_at}
        )
      )

    for {id, lifecycle, expires_at, requested_at} <- rows,
        reference = if(lifecycle == "expired", do: expires_at, else: requested_at),
        DateTime.compare(now, DateTime.add(reference, retention, :second)) != :lt,
        do: id
  end
end
