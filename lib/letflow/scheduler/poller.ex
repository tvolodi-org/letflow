defmodule Letflow.Scheduler.Poller do
  @moduledoc """
  Supervised `GenServer` ticker implementing REQ-185 §2's Decision 1
  (supervised `GenServer` ticker) and §6's Decision 5 (iterates tenant
  schemas per tick). See `lib/letflow/design/req186-scheduler-core.md` §3
  for the full design this module implements.

  `init/1` schedules its **first** `:tick` message with **zero** delay, so
  a restart catches up on missed timers with no special-cased recovery
  logic.

  ## State (REQ-188 addition — no longer "no meaningful state")

  Prior to REQ-188 this GenServer carried no meaningful state between
  ticks — a pure scheduling loop. REQ-188 widened `state` from `%{}` to
  `%{last_retention_run_at: DateTime.t() | nil}`, solely to track
  retention-sweep cadence (see `Letflow.Scheduler.retention_due?/1`). REQ-376
  adds a second, symmetric field, `last_partition_maintenance_run_at`, to
  track the partition pre-creation sweep's own cadence the exact same way
  (`Letflow.Scheduler.partition_maintenance_due?/1`). Both are initialized to
  `nil` in `init/1` and updated only when their respective sweep actually
  runs. No other state is introduced; the timer-poll loop itself remains
  stateless.

  Config (`config :letflow, :scheduler, [...]`, `Letflow.Scheduler`'s own
  accessors) is read fresh on every tick, so a runtime override (e.g. a
  test calling `Application.put_env/3`) takes effect on the very next tick.

  Jitter is applied only to the inter-tick scheduling delay, never to any
  `fire_at` value (SCH-06) -- when `jitter_ms()` is `0`, no random draw is
  made at all, the delay is exactly `poll_interval_ms()`.

  A raise inside one tenant schema's `Letflow.Scheduler.poll_and_fire/1` call
  is additionally guarded by a top-level `try/rescue` at this sweep's
  `Task.async_stream/3` call site (ISS-0421 design §4b), even though that
  function's own contract (design §2.2) already guarantees it never raises.
  This is no longer redundant now that iteration is concurrent:
  `Task.async_stream/3`'s failure blast radius (the whole in-flight batch,
  were an unhandled raise to reach it) is categorically larger than
  `Enum.each/2`'s ever was (only the rest of that one serial loop), so
  relying solely on the callee's own non-raising contract became a
  materially bigger bet than it was before that fix -- see the "ISS-0421
  addition" section below.

  ## REQ-219 addition -- test-only forced-crash seam (`force_poller_crash`)

  `handle_info(:tick, state)`'s first expression is a double-gated guard
  that unconditionally raises when both gates are open, used by
  `test/letflow/supervisor/pollers_test.exs`'s AC4 crash-loop-isolation
  test (`req219-supervision-layering.md` §5) to reproduce, on demand, the
  exact "Poller raises on every tick" scenario that motivated
  `Letflow.Supervisor.Pollers`' own `max_restarts: 5, max_seconds: 60`
  override. Mirrors `lib/letflow/repository/activation.ex`'s own
  `@activation_test_hooks_enabled?` double-gate pattern exactly, and
  DELIBERATELY REUSES that same existing, already-committed compile-time
  config key rather than introducing a new one (a new key would need its
  own `config/test.exs` entry, violating REQ-219 AC7's "no config file
  changes" bar). Structurally unreachable in a compiled dev/prod release:
  `@poller_test_hooks_enabled?` is resolved once at compile time and folds
  to a literal `false` in every build except one compiled with
  `:activation_test_hooks_enabled?: true` (only `config/test.exs` sets
  this), so no runtime `Application.put_env(:letflow, :force_poller_crash,
  true)` call -- by a future ops script, console session, or otherwise --
  can ever reach this branch outside a test build. The runtime
  `Application.get_env/3` check (read fresh per call, matching this
  module's own existing "config read fresh on every tick" convention) is
  what lets one specific test flip the behavior on/off without a fresh
  compile.

  ## ISS-0421 addition -- bounded per-tenant concurrency within each sweep
  (design `iss0421-poller-bounded-concurrency.md`)

  Each of the seven per-tenant sweeps below (the eighth and ninth are described in their own sections) iterates `schemas` via
  `Task.async_stream/3` instead of `Enum.each/2`, bounding how many tenants'
  calls are in flight together for that ONE sweep. The seven sweeps
  themselves remain strictly sequential relative to each other (design §2) --
  only the per-tenant iteration *inside* a single sweep is now concurrent.

  Two concurrency-bound classes (design §3):

    * The six Admission-gated sweeps (poll-and-fire, retention, alert
      detection, ordering cycle/sweeper/metrics) use
      `Letflow.Admission.global_cap/0`'s LIVE return value, read fresh inside
      `run_sweep/4` every tick, never cached or hoisted -- exactly the same
      "read the real accessor live" convention `maybe_refresh_active_instances/1`
      already uses for `reserved_headroom/0` below (design §3a/§3c, corrected
      per `handoffs/WF03-ISS0421-20260904/step-04-reviewer.json`: a hardcoded
      literal that only happened to match `Admission.global_cap` at default
      config would silently reintroduce Poller-as-its-own-contender self-
      collision at any smaller configured `POOL_SIZE`). `Admission.
      try_acquire(:global)`'s own non-blocking gate is still the true ceiling
      on concurrent `DBConnection` checkouts for these six sweeps regardless
      of this bound -- raising it above the live `global_cap` cannot push
      checkouts past `global_cap`, it would only spawn extra BEAM processes
      that immediately lose the admission race -- but deriving it live keeps
      Poller from ever becoming a *concurrent* contender against itself for
      that same cap when `global_cap` is small.
    * `maybe_refresh_active_instances/1` (the one sweep with NO Admission
      backstop) instead uses `Letflow.Admission.reserved_headroom/0`'s LIVE
      return value, read fresh inside that sweep's own function body every
      tick, never cached or hoisted -- this is the one sweep where the
      `Task.async_stream` bound IS the only thing standing between the fix
      and pool exhaustion, so it must always track Admission's own
      configured headroom rather than duplicate it as an independent literal
      (design §3b's `global_cap + max_concurrency = pool_size` identity).

  Every `Task.async_stream/3` call site sets `timeout:
  Scheduler.sweep_task_timeout_ms()`, `on_timeout: :kill_task` (a timed-out
  task is killed and yielded as an `{:exit, {schema_name, :timeout}}`
  element, rather than crashing this GenServer the way the library's own
  `on_timeout: :exit` default would), and `zip_input_on_exit: true` (so a
  timeout/crash exit tuple carries which schema it belongs to, for logging).
  The poll-and-fire loop and the retention sweep -- the two call sites with
  no pre-existing inline rescue -- additionally wrap their per-schema
  function in a top-level `try/rescue` (design §4b): `Task.async_stream/3`'s
  own failure blast radius (the whole concurrent batch) is categorically
  larger than `Enum.each/2`'s ever was, so a callee's own non-raising
  contract is no longer a safe-enough bet on its own. The other four sweeps
  already wrap their op call in an inline `try/rescue -> :ok` and need no
  second, redundant one.

  ## REQ-218 addition -- admission-control wiring on the six sequential
  per-tenant operations (design `req218-poller-admission-wiring.md`)

  Each of the six named operations below (the timer poll-and-fire loop
  plus the five `maybe_run_*` sweeps) acquires ONE `:global` admission
  unit via `Letflow.Admission.try_acquire/1` for that operation's own
  single per-schema call, and releases it via an `after` clause on the
  wrapping `try` -- guaranteeing release even if some future edit to the
  wrapped operation let an exception past its own existing rescue. On
  `{:error, :capacity}`, that one schema's turn for that one operation is
  skipped for this tick only (logged at `Logger.warning/1`, matching
  `lib/letflow/tenant_provisioning/backfill.ex:37,44` and
  `lib/letflow/obs/alerts.ex:588`'s skip-and-continue precedent) -- every
  other schema, and every other operation, proceeds independently. Only
  `:global` is ever acquired here, never the per-tenant pool -- Poller already
  iterates every tenant schema once per tick by design (REQ-186), so a
  per-tenant cap would only cause silent, unfair skips rather than bound
  anything meaningful for a background sweep. `maybe_refresh_active_instances/1`
  (REQ-194) is deliberately left UNWRAPPED -- not one of REQ-218's six
  named operations.

  ## REQ-194 addition -- `letflow_active_instances` refresh (design
  `req194-prometheus-metrics.md` §6)

  Each tick, after the timer poll-and-fire loop, sums
  `Letflow.Engine.count_instances_by_status/1`'s `:active` key across the SAME
  `tenant_schemas()` list already computed for that tick (no second query) and
  writes the platform-wide total to `Letflow.Metrics.Registry.set_active_instances/1`
  -- this is the one OBS-02 metric family that is NOT `:telemetry`-driven (see that
  module's moduledoc for why).

  Two failure isolation layers, both required so a database outage degrades this one
  metric rather than crashing the whole scheduler (a crashed Poller stops every
  tenant's timers firing platform-wide, a vastly worse regression than a stale
  gauge):

    * `tenant_schemas/0` itself raising (the DB is unreachable entirely) is caught by
      `fetch_tenant_schemas/0` below -- on failure, this tick's poll-and-fire loop
      AND the active-instances refresh are BOTH skipped (there is nothing to iterate
      either one over), `mark_active_instances_refresh_failed/0` is called, and the
      next tick is still scheduled normally. This is a deliberate, flagged deviation
      from the design's literal "the timer poll-and-fire loop for that tick still
      proceeds normally" wording: that loop's own input (`schemas`) is exactly what
      failed to compute, so "proceeding normally" over an empty/undefined list is not
      meaningfully different from skipping it outright -- flagged for REVIEWER.
    * One individual schema's `count_instances_by_status/1` call raising (a single
      tenant's schema corrupted or mid-migration) is caught per-schema in
      `count_active_for_schema/1` -- that schema contributes `0` to the sum and every
      other schema, plus the timer poll-and-fire loop, is unaffected.

  ## REQ-331 addition -- generic deadline-driven record transition sweep
  (`lib/letflow/scheduler/record_deadline_sweep.ex`)

  An EIGHTH per-tenant sweep, added on this same supervised process -- no new
  `GenServer`, no new supervisor child, no second ticker. Rules are read fresh
  every tick from `Application.get_env(:letflow, :deadline_sweep, [])`, never
  cached in `state`, exactly like every other config-gated sweep here
  (`:ordering`, `:alert_hooks`). Each configured rule runs as its own
  `run_sweep/4` call, bounded by the same live `Admission.global_cap/0` value
  read inside `maybe_run_deadline_sweep/1` on every call, and wrapped in
  `with_admission/3` plus an inline `try/rescue -> :ok`, matching
  `maybe_run_ordering_cycle/1`'s exact shape -- one tenant raising does not
  stop the sweep for the others. This module carries no vertical-specific
  vocabulary anywhere (0022 rule 1) -- see
  `Letflow.Scheduler.RecordDeadlineSweep`'s own moduledoc for the full design
  reasoning (rule declaration/authorization, INV-1, the SKIP LOCKED and
  per-record isolation mechanisms).

  ## REQ-561 addition -- tenant scheduled jobs
  (`lib/letflow/scheduler/scheduled_job_sweep.ex`)

  A NINTH per-tenant sweep, `maybe_run_scheduled_job_sweep/1`, written like
  `maybe_run_deadline_sweep/1`: one `run_sweep/4` per tick, `with_admission/3`, an inline
  `try/rescue -> :ok`, no new process and no new `Task`. It runs only while
  `Letflow.ScheduledJobs.enabled?/0` (config `:scheduled_jobs`, default off) is true, read fresh every
  tick. See `Letflow.Scheduler.ScheduledJobSweep` for how a tenant job differs from a platform timer
  and from the record transition sweep.
  """

  use GenServer

  require Logger

  alias Letflow.Admission
  alias Letflow.Engine
  alias Letflow.Metrics.Registry, as: MetricsRegistry
  alias Letflow.Obs.Alerts
  alias Letflow.ScheduledJobs
  alias Letflow.Scheduler
  alias Letflow.Scheduler.RecordDeadlineSweep
  alias Letflow.Scheduler.ScheduledJobSweep
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  alias Letflow.Repo

  @type state :: %{
          last_retention_run_at: DateTime.t() | nil,
          last_tick_started_at: DateTime.t() | nil,
          last_partition_maintenance_run_at: DateTime.t() | nil
        }

  # See "REQ-219 addition" moduledoc section above. Resolved once at
  # compile time (not a runtime Mix.env() call, which is unavailable in a
  # compiled release) -- becomes a literal true/false in the compiled BEAM
  # code. Deliberately reuses activation.ex's own
  # :activation_test_hooks_enabled? config key rather than a new one.
  @poller_test_hooks_enabled? Application.compile_env(
                                :letflow,
                                :activation_test_hooks_enabled?,
                                false
                              )

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      },
      name: __MODULE__
    )
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if @poller_test_hooks_enabled? and Application.get_env(:letflow, :force_poller_crash, false) do
      raise "forced crash for REQ-219 AC4 crash-loop isolation test"
    end

    now = DateTime.utc_now()
    observed_lag_ms = compute_lag(get_last_tick_started_at(state), now)

    new_state =
      case fetch_tenant_schemas() do
        {:ok, schemas} ->
          run_sweep(schemas, :poll_and_fire, Admission.global_cap(), fn schema_name ->
            try do
              with_admission(schema_name, :poll_and_fire, fn ->
                Scheduler.poll_and_fire(schema_name)
              end)
            rescue
              error ->
                log_task_raise(schema_name, :poll_and_fire, error, __STACKTRACE__)
            end
          end)

          maybe_refresh_active_instances(schemas)
          retention_state = maybe_run_retention_sweep(schemas, state)

          partition_maintenance_state =
            maybe_run_partition_maintenance(schemas, retention_state)

          maybe_run_alert_detection(schemas, observed_lag_ms, get_last_tick_started_at(state))
          maybe_run_ordering_cycle(schemas)
          maybe_run_ordering_sweeper(schemas)
          maybe_run_ordering_metrics(schemas)
          maybe_run_deadline_sweep(schemas)
          maybe_run_scheduled_job_sweep(schemas)
          Map.put(partition_maintenance_state, :last_tick_started_at, now)

        :error ->
          MetricsRegistry.mark_active_instances_refresh_failed()
          Map.put(state, :last_tick_started_at, now)
      end

    schedule_next_tick()

    {:noreply, new_state}
  end

  # REQ-218: acquires ONE :global admission unit for `fun`'s single
  # Repo-touching call, releasing it via an `after` clause (guaranteed even
  # if `fun` itself raises past whatever rescue it already establishes --
  # `fun` is responsible for its OWN existing rescue boundary, if any; this
  # wrapper adds admission accounting only, never a rescue of its own). On
  # `{:error, :capacity}`, logs and skips `fun` entirely for this
  # schema/operation this tick -- never raises, never halts the caller's
  # `Enum.each`.
  @spec with_admission(String.t(), atom(), (-> any())) :: :ok
  defp with_admission(schema_name, op, fun) when is_function(fun, 0) do
    admission_result = Admission.try_acquire(:global)

    :telemetry.execute(
      [:letflow, :scheduler, :admission_decision],
      %{},
      %{
        schema: schema_name,
        op: op,
        result: if(match?({:ok, _}, admission_result), do: :granted, else: :rejected)
      }
    )

    case admission_result do
      {:ok, ref} ->
        try do
          fun.()
        after
          Admission.release(ref)
        end

      {:error, :capacity} ->
        Logger.warning("poller admission capacity exhausted, skipping schema/operation",
          schema: schema_name,
          op: op
        )
    end

    :ok
  end

  # ISS-0421 §4a/§7 -- bounds `schemas`' per-tenant iteration for `fun` with
  # `Task.async_stream/3`, fully consumes the resulting stream, and logs
  # every `{:exit, _}` yield (timeout or crash) tagged with `schema:`/`op:`,
  # mirroring `with_admission/3`'s own capacity-skip log style. `fun` is
  # responsible for its own admission/rescue handling; this helper only
  # bounds concurrency and surfaces exits that escape `fun` anyway (a
  # timeout, which no rescue inside `fun` can catch).
  @spec run_sweep(list(String.t()), atom(), pos_integer(), (String.t() -> any())) :: :ok
  defp run_sweep(schemas, op, max_concurrency, fun) do
    schemas
    |> Task.async_stream(
      fun,
      max_concurrency: max_concurrency,
      timeout: Scheduler.sweep_task_timeout_ms(),
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.each(fn
      {:ok, _result} -> :ok
      {:exit, {schema_name, reason}} -> log_task_exit(schema_name, op, reason)
    end)

    :ok
  end

  defp log_task_exit(schema_name, op, reason) do
    Logger.warning("poller sweep task did not complete, skipping schema/operation",
      schema: schema_name,
      op: op,
      reason: inspect(reason)
    )
  end

  defp log_task_raise(schema_name, op, error, stacktrace) do
    Logger.warning("poller sweep task raised, skipping schema/operation",
      schema: schema_name,
      op: op,
      error: Exception.format(:error, error, stacktrace)
    )

    :ok
  end

  defp compute_lag(nil, _now), do: nil
  defp compute_lag(last, now), do: DateTime.diff(now, last, :millisecond)

  defp get_last_tick_started_at(state) do
    Map.get(state, :last_tick_started_at)
  end

  # REQ-188 design §2.4 -- runs on this same supervised process, no new
  # child, no new ticker. Reuses the `schemas` list already computed for
  # this tick's timer-poll loop above -- not queried a second time.
  defp maybe_run_retention_sweep(schemas, state) do
    if Scheduler.retention_enabled?() and Scheduler.retention_due?(state.last_retention_run_at) do
      run_sweep(schemas, :retention_sweep, Admission.global_cap(), fn schema_name ->
        try do
          with_admission(schema_name, :retention_sweep, fn ->
            Scheduler.run_retention_sweep(schema_name)
          end)
        rescue
          error ->
            log_task_raise(schema_name, :retention_sweep, error, __STACKTRACE__)
        end
      end)

      %{state | last_retention_run_at: DateTime.utc_now()}
    else
      state
    end
  end

  # REQ-376 §3.1 -- the ensure_future_partitions/2 pre-creation sweep,
  # wired onto this same tick, exact same shape as maybe_run_retention_sweep/2
  # (config-gated, cadence-gated via Scheduler.partition_maintenance_due?/1,
  # iterated per tenant schema via run_sweep/4 at the same Admission-bounded
  # concurrency as every other sweep here).
  defp maybe_run_partition_maintenance(schemas, state) do
    if Scheduler.partition_maintenance_enabled?() and
         Scheduler.partition_maintenance_due?(state.last_partition_maintenance_run_at) do
      run_sweep(schemas, :partition_maintenance, Admission.global_cap(), fn schema_name ->
        try do
          with_admission(schema_name, :partition_maintenance, fn ->
            Scheduler.run_partition_maintenance_sweep(schema_name)
          end)
        rescue
          error ->
            log_task_raise(schema_name, :partition_maintenance, error, __STACKTRACE__)
        end
      end)

      %{state | last_partition_maintenance_run_at: DateTime.utc_now()}
    else
      state
    end
  end

  # REQ-201: alert detection piggybacking on this existing tick, no new child,
  # no application.ex change (design §9.1). Reads alert_hooks config fresh on
  # every call; noop if :alert_hooks is not configured or enabled: false.
  defp maybe_run_alert_detection(schemas, observed_lag_ms, last_tick_started_at) do
    cfg = Application.get_env(:letflow, :alert_hooks, [])

    if Keyword.get(cfg, :enabled, false) do
      run_sweep(schemas, :alert_detection, Admission.global_cap(), fn schema_name ->
        with_admission(schema_name, :alert_detection, fn ->
          try do
            Alerts.build_context_and_detect(schema_name, observed_lag_ms, last_tick_started_at)
          rescue
            _ -> :ok
          end
        end)
      end)
    end
  end

  # REQ-331: config (`:deadline_sweep`, a list of rules) read fresh on every
  # tick, never cached in state. One run_sweep/4 call per configured rule --
  # matches maybe_run_ordering_cycle/1's exact with_admission + inline
  # try/rescue shape, so one tenant raising for one rule does not stop the
  # sweep for the remaining tenants or the remaining rules.
  defp maybe_run_deadline_sweep(schemas) do
    cfg = Application.get_env(:letflow, :deadline_sweep, [])
    rules = Keyword.get(cfg, :rules, [])

    Enum.each(rules, fn rule ->
      run_sweep(schemas, :deadline_sweep, Admission.global_cap(), fn schema_name ->
        with_admission(schema_name, :deadline_sweep, fn ->
          try do
            RecordDeadlineSweep.run(schema_name, rule)
          rescue
            _ -> :ok
          end
        end)
      end)
    end)
  end

  # REQ-561: tenant scheduled jobs. The flag is read fresh on every tick; while it is false (the
  # default) nothing is claimed or queried. Same shape as maybe_run_deadline_sweep/1: one run_sweep/4,
  # with_admission, inline try/rescue.
  defp maybe_run_scheduled_job_sweep(schemas) do
    if ScheduledJobs.enabled?() do
      run_sweep(schemas, :scheduled_job_sweep, Admission.global_cap(), fn schema_name ->
        with_admission(schema_name, :scheduled_job_sweep, fn ->
          try do
            ScheduledJobSweep.run(schema_name)
          rescue
            _ -> :ok
          end
        end)
      end)
    end
  end

  defp tenant_schemas do
    Registration
    |> where([r], not is_nil(r.migrations_applied_at))
    |> select([r], r.schema_name)
    |> Repo.all()
  end

  # REQ-194 (design §6): wraps tenant_schemas/0 so a fully-unreachable database (a
  # raised DBConnection.ConnectionError, per lib/letflow/routers/metrics.ex's own
  # retired moduledoc note that Ecto/DBConnection surfaces pool exhaustion this way,
  # not as an error tuple) never crashes this GenServer.
  defp fetch_tenant_schemas do
    {:ok, tenant_schemas()}
  rescue
    _error -> :error
  end

  # REQ-194 (design §6): sums count_instances_by_status/1's :active key across every
  # schema already computed for this tick (no second tenant_schemas/0 query) and
  # writes the platform-wide total. Never raises -- each schema's own failure is
  # isolated in count_active_for_schema/1.
  defp maybe_refresh_active_instances(schemas) do
    # ISS-0421 §3b/§7 -- read live, fresh on every call, never cached or
    # hoisted: this is the one sweep with NO Admission backstop, so its
    # Task.async_stream bound must always track Admission's actual
    # reserved_headroom, not an independent literal (see moduledoc).
    max_concurrency = Admission.reserved_headroom()

    total =
      schemas
      |> Task.async_stream(
        &count_active_for_schema/1,
        max_concurrency: max_concurrency,
        timeout: Scheduler.sweep_task_timeout_ms(),
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.reduce(0, fn
        {:ok, count}, acc ->
          acc + count

        {:exit, {schema_name, reason}}, acc ->
          log_task_exit(schema_name, :refresh_active_instances, reason)
          acc
      end)

    MetricsRegistry.set_active_instances(total)
  end

  # A single tenant's schema being corrupted or mid-migration must not zero out (or
  # crash) the platform-wide aggregate -- design §6 judges this acceptable
  # specifically because it is a large, low-precision-tolerant summary gauge, unlike
  # a per-tenant figure a single tenant depends on the exact precision of.
  defp count_active_for_schema(schema_name) do
    case Engine.count_instances_by_status(prefix: schema_name) do
      {:ok, counts} -> Map.get(counts, :active, 0)
      {:error, _reason} -> 0
    end
  rescue
    _error -> 0
  end

  defp schedule_next_tick do
    delay = Scheduler.poll_interval_ms() + jitter_extra_ms()
    Process.send_after(self(), :tick, delay)
  end

  defp jitter_extra_ms do
    case Scheduler.jitter_ms() do
      0 -> 0
      jitter_ms -> :rand.uniform(jitter_ms + 1) - 1
    end
  end

  # REQ-199: ordering consumer cycle, one per schema per tick, no new application.ex child.
  defp maybe_run_ordering_cycle(schemas) do
    cfg = Application.get_env(:letflow, :ordering, [])

    if Keyword.get(cfg, :enabled, true) do
      run_sweep(schemas, :ordering_cycle, Admission.global_cap(), fn schema_name ->
        with_admission(schema_name, :ordering_cycle, fn ->
          try do
            Letflow.Ordering.run_cycle(schema_name, prefix: schema_name)
          rescue
            _ -> :ok
          end
        end)
      end)
    end
  end

  # REQ-199: gap sweeper, one per schema per tick.
  defp maybe_run_ordering_sweeper(schemas) do
    cfg = Application.get_env(:letflow, :ordering, [])

    if Keyword.get(cfg, :enabled, true) do
      run_sweep(schemas, :ordering_sweeper, Admission.global_cap(), fn schema_name ->
        with_admission(schema_name, :ordering_sweeper, fn ->
          try do
            Letflow.Ordering.sweep_gaps(schema_name, prefix: schema_name)
          rescue
            _ -> :ok
          end
        end)
      end)
    end
  end

  # REQ-199: lag metrics surface, one per schema per tick.
  defp maybe_run_ordering_metrics(schemas) do
    cfg = Application.get_env(:letflow, :ordering, [])

    if Keyword.get(cfg, :enabled, true) do
      run_sweep(schemas, :ordering_metrics, Admission.global_cap(), fn schema_name ->
        with_admission(schema_name, :ordering_metrics, fn ->
          try do
            Letflow.Ordering.emit_lag_metrics(schema_name, prefix: schema_name)
          rescue
            _ -> :ok
          end
        end)
      end)
    end
  end
end
