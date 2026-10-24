defmodule Letflow.Engine.ServiceTaskDispatcher.Poller do
  @moduledoc """
  Supervised `GenServer` ticker for REQ-214's SERVICE_TASK dispatch
  orchestration. Mirrors `Letflow.Scheduler.Poller`'s shape (design
  `lib/letflow/design/service_task_dispatcher.md` §7) at the scope this
  requirement needs — no REQ-188/194/199/201-style feature accretion
  (retention, metrics, alerts, ordering all belong to
  `Letflow.Scheduler.Poller` specifically and are not duplicated here).

  `init/1` schedules its first `:tick` message with ZERO delay, so a
  restart catches up on missed dispatches with no special-cased recovery
  logic — identical rationale to `Letflow.Scheduler.Poller`.

  ## Boot-gating (design §8, INV-STD-7)

  This `GenServer`'s own first tick queries `Letflow.Repo` from a process
  no test process is an ancestor of — under `Ecto.Adapters.SQL.Sandbox`'s
  default `:manual` mode (this project's test mode) that raises
  `DBConnection.OwnershipError` on every tick, repeatedly, until the
  supervisor's restart intensity is exceeded and `Letflow.Supervisor` (and
  everything under it, including `Letflow.Repo`) shuts down — the exact
  same hazard `Letflow.Scheduler.Poller`'s own `:start_scheduler` gate
  exists to prevent (`lib/letflow/application.ex`'s `scheduler_children/0`
  comment). This module carries the identical hazard and MUST use the
  identical gating convention — but a NEW, distinct config key,
  `:start_service_task_dispatcher`, not a reuse of `:start_scheduler` (the
  two pollers are independent concerns with independent poll cadences,
  per REQ-214's own text — `lib/letflow/application.ex`'s
  `service_task_dispatcher_children/0`).

  `config :letflow, :service_task_dispatcher, [...]`
  (`Letflow.Engine.ServiceTaskDispatcher`'s own accessors) is read fresh on
  every tick, so a runtime override takes effect on the very next tick.
  Jitter is applied only to the inter-tick scheduling delay, never to any
  `next_attempt_at` value.

  ## Stuck-advance sweep (GH #2688 / REQ-513)

  Each tick also runs `StuckSweep.run_all/4`, gated to at most one sweep per
  `stuck_advance_sweep_interval_ms` and skipped entirely while `stuck_advance_mode` is `:off`
  (the default). Per-tenant keyset cursors and the tenant rotation live in this process's state
  only; a restart starts the walk over.
  """

  use GenServer

  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.StuckSweep
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  @type state :: %{
          last_tick_started_at: DateTime.t() | nil,
          last_sweep_at: DateTime.t() | nil,
          stuck_cursors: %{String.t() => StuckSweep.cursor()},
          sweep_rotation: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, initial_state(), name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    new_state =
      case fetch_tenant_schemas() do
        {:ok, schemas} ->
          Enum.each(schemas, fn schema_name ->
            ServiceTaskDispatcher.poll_and_dispatch(schema_name)
          end)

          %{maybe_sweep(state, schemas, now) | last_tick_started_at: now}

        :error ->
          %{state | last_tick_started_at: now}
      end

    schedule_next_tick()

    {:noreply, new_state}
  end

  @doc false
  @spec initial_state() :: state()
  def initial_state do
    %{last_tick_started_at: nil, last_sweep_at: nil, stuck_cursors: %{}, sweep_rotation: 0}
  end

  # GH #2688 / REQ-513: the stuck-`advanced` sweep, at most once per
  # `stuck_advance_sweep_interval_ms`, and only when its mode is not `:off`. The tenant order
  # rotates each sweep so a budget spent on early tenants cannot starve the later ones.
  defp maybe_sweep(state, schemas, now) do
    mode = ServiceTaskDispatcher.stuck_advance_mode()

    if mode != :off and sweep_due?(state.last_sweep_at, now) do
      cursors =
        schemas
        |> rotate(state.sweep_rotation)
        |> StuckSweep.run_all(state.stuck_cursors, now, mode)
        |> Map.take(schemas)

      %{
        state
        | last_sweep_at: now,
          stuck_cursors: cursors,
          sweep_rotation: state.sweep_rotation + 1
      }
    else
      state
    end
  end

  defp sweep_due?(nil, _now), do: true

  defp sweep_due?(last, now),
    do:
      DateTime.diff(now, last, :millisecond) >=
        ServiceTaskDispatcher.stuck_advance_sweep_interval_ms()

  defp rotate([], _n), do: []

  defp rotate(schemas, n) do
    {head, tail} = Enum.split(schemas, rem(n, length(schemas)))
    tail ++ head
  end

  defp tenant_schemas do
    Registration
    |> where([r], not is_nil(r.migrations_applied_at))
    |> select([r], r.schema_name)
    |> Repo.all()
  end

  # Mirrors Letflow.Scheduler.Poller's own fetch_tenant_schemas/0 -- a
  # fully-unreachable database must not crash this GenServer.
  defp fetch_tenant_schemas do
    {:ok, tenant_schemas()}
  rescue
    _error -> :error
  end

  defp schedule_next_tick do
    delay = ServiceTaskDispatcher.poll_interval_ms() + jitter_extra_ms()
    Process.send_after(self(), :tick, delay)
  end

  defp jitter_extra_ms do
    case ServiceTaskDispatcher.jitter_ms() do
      0 -> 0
      jitter_ms -> :rand.uniform(jitter_ms + 1) - 1
    end
  end
end
