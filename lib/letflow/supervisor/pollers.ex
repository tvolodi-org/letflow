defmodule Letflow.Supervisor.Pollers do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §1.2/§3): owns the
  independently-gated poller `GenServer`s (a fourth, GH 3292, is the provisioner sweep
  `Letflow.TenantProvisioner.Sweep`, gated `:start_provisioner_sweep`) -- `Letflow.Scheduler.Poller`
  (REQ-186, gated `:start_scheduler`) and
  `Letflow.Engine.ServiceTaskDispatcher.Poller` (REQ-214, gated
  `:start_service_task_dispatcher`) -- each still individually gated by its
  own existing config key (REQ-214's own "independent poll cadences,
  independent boot gates" framing; letting a future host disable one
  without the other). With both gates `false` (`config/test.exs`'s current
  setting), `init/1` returns an empty children list -- fully supported by
  the `Supervisor` behaviour: this supervisor starts, holds zero children,
  and stays alive doing nothing until the application stops.

  ## Restart intensity override -- DELIBERATE, not the OTP default

  `max_restarts: 5, max_seconds: 60` -- looser than the OTP default (3
  restarts/5 seconds) to tolerate a handful of transient per-tick failures
  (a single bad HTTP dispatch, a single locked row) without this
  supervisor itself exiting, while still bounding a genuine, sustained
  crash-loop to a bounded number of restart attempts before THIS
  supervisor (only) exits and is restarted once by the top-level
  `Letflow.Supervisor`.

  This closes the documented, non-hypothetical incident this requirement
  exists for: a Poller whose zero-delay first tick
  (`Process.send_after(self(), :tick, 0)`) raises
  `DBConnection.OwnershipError` repeatedly under Ecto sandbox mode (or any
  other sustained per-tick fault) used to exhaust the SHARED top-level
  supervisor's restart intensity and take the WHOLE application --
  `Letflow.Repo` and Bandit included -- down with it (`scheduler_children/0`'s
  own historical comment, superseded by this structure, and ISS-0421).
  Now, `Letflow.Supervisor.Infrastructure` and `Letflow.Supervisor.Http`
  are never touched: `:one_for_one` at the top level means this
  supervisor's own exit only restarts itself.

  DELIBERATE, ACCEPTED CONSEQUENCE: within this supervisor, the two
  pollers are peers under `:one_for_one`. Once ONE poller's own crash-loop
  exhausts this shared 5-restarts/60-seconds budget, THIS SUPERVISOR
  itself exits and restarts, which restarts BOTH pollers together (if both
  are configured to run) -- restarting the supervisor process necessarily
  restarts everything under it. This is an accepted consequence of
  `:one_for_one`-at-two-levels, not a gap: REQ-219's own AC4 only requires
  `Letflow.Repo`/`Letflow.Supervisor.Infrastructure`/`Letflow.Supervisor.Http`
  to survive a poller crash-loop, never that the OTHER poller survives its
  sibling's crash-loop.

  ## Test-only ordering probe (`pollers_init_probe`)

  Double-gated exactly like `lib/letflow/repository/activation.ex`'s
  `@activation_test_hooks_enabled?` seam -- DELIBERATELY REUSING that same
  existing, already-committed compile-time config key
  (`:activation_test_hooks_enabled?`) rather than introducing a new one,
  because a new key would need its own `config/test.exs` entry, which
  would violate REQ-219 AC7's "no config file changes" bar; the existing
  key is already `true` under test (`config/test.exs:209`, predating this
  requirement). REVIEWER should confirm this reuse is an acceptable,
  explicitly-flagged trade rather than scope creep or accidental coupling
  between the activation and supervisor test seams -- the two features
  share nothing but this one boolean compile-time gate.

  If `@supervisor_test_hooks_enabled?` (resolved once at compile time,
  `false` in every dev/prod build since only `config/test.exs` sets the
  underlying key to `true`) is `true` AND
  `Application.get_env(:letflow, :pollers_init_probe)` is a 1-arity
  function, `init/1` calls it, as its very first expression, with
  `Process.whereis(Letflow.Obs.Alerts.TaskSupervisor)`'s result, before
  computing the two gated poller children -- used by
  `test/letflow/supervisor/pollers_test.exs`'s cold-boot ordering test
  (REQ-219 AC2) to observe, at the exact moment this module's `init/1`
  runs, whether `Letflow.Supervisor.Infrastructure` has already fully
  started. In any compiled dev/prod build, `@supervisor_test_hooks_enabled?`
  folds to a literal `false` and the whole branch is dead code -- this
  probe can never run in production regardless of any runtime
  `Application.put_env/3` call.
  """

  use Supervisor

  # See @typep test_opts-style comment in
  # lib/letflow/repository/activation.ex lines 205-247 for the full
  # rationale of this double-gate pattern. Resolved once at compile time
  # (not a runtime Mix.env() call, which is unavailable in a compiled
  # release) -- becomes a literal true/false in the compiled BEAM code.
  # Deliberately reuses activation.ex's own :activation_test_hooks_enabled?
  # config key rather than a new one -- see moduledoc above.
  @supervisor_test_hooks_enabled? Application.compile_env(
                                    :letflow,
                                    :activation_test_hooks_enabled?,
                                    false
                                  )

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    maybe_run_pollers_init_probe()

    children =
      scheduler_children() ++
        service_task_dispatcher_children() ++
        script_task_dispatcher_children() ++ provisioner_sweep_children()

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  defp maybe_run_pollers_init_probe do
    if @supervisor_test_hooks_enabled? do
      case Application.get_env(:letflow, :pollers_init_probe) do
        probe when is_function(probe, 1) ->
          probe.(Process.whereis(Letflow.Obs.Alerts.TaskSupervisor))

        _ ->
          :ok
      end
    end
  end

  # REQ-186 (design req186-scheduler-core.md §3.3): the scheduler's supervised
  # GenServer ticker. Gated the same way service_task_dispatcher_children/0 and
  # http_child/0 gate their own children (ISS-0015's own precedent) --
  # config/test.exs sets start_scheduler: false, a deliberate, flagged addition
  # beyond what the design doc itself specifies: the Poller's own first tick
  # runs with ZERO delay and queries Letflow.Repo from a process no test
  # process is an ancestor of, which under Ecto.Adapters.SQL.Sandbox's default
  # :manual mode raises DBConnection.OwnershipError on every tick, repeatedly,
  # until this supervisor's restart intensity is exceeded and it exits and is
  # restarted by the top-level Letflow.Supervisor -- verified live via a full
  # `mix test` run before this gate was added. No acceptance criterion
  # requires the Poller to run automatically inside the test suite;
  # Letflow.Scheduler's own tests call `poll_and_fire/1` directly, and any test
  # of the Poller GenServer itself starts its own instance explicitly
  # (mirroring http_child/0's own "exercised directly, not through the
  # supervised child" precedent for Bandit/Plug.Test).
  defp scheduler_children do
    if Application.get_env(:letflow, :start_scheduler, true) do
      [{Letflow.Scheduler.Poller, []}]
    else
      []
    end
  end

  # REQ-214 (design service_task_dispatcher.md §8): the SERVICE_TASK
  # dispatch-orchestration poller's supervised GenServer ticker. Gated the
  # same way scheduler_children/0 gates Letflow.Scheduler.Poller above, for
  # the IDENTICAL documented hazard (this Poller's own first tick also runs
  # with ZERO delay and queries Letflow.Repo from a process no test process
  # is an ancestor of). A NEW, distinct config key, :start_service_task_dispatcher,
  # NOT a reuse of :start_scheduler -- REQ-214's own text is explicit the two
  # pollers are independent concerns with independent poll cadences, so their
  # boot gates stay independent too, letting a future host disable one
  # without the other. config/test.exs sets start_service_task_dispatcher:
  # false. No acceptance criterion requires this Poller to run automatically
  # inside the test suite; Letflow.Engine.ServiceTaskDispatcher's own tests
  # call poll_and_dispatch/1 directly.
  defp service_task_dispatcher_children do
    if Application.get_env(:letflow, :start_service_task_dispatcher, true) do
      [{Letflow.Engine.ServiceTaskDispatcher.Poller, []}]
    else
      []
    end
  end

  # GH 2534 PR 7c-1 (design gh2534-7c-script-handler.md C2): the script SERVICE_TASK route's
  # own poller, independent of the HTTP one (a script run must not delay HTTP dispatch).
  # Gated by its own key, :start_script_task_dispatcher (false in config/test.exs: the same
  # zero-delay-first-tick OwnershipError hazard as the two pollers above).
  defp script_task_dispatcher_children do
    if Application.get_env(:letflow, :start_script_task_dispatcher, true) do
      [{Letflow.Engine.ScriptTaskDispatcher.Poller, []}]
    else
      []
    end
  end

  # GH 3292 (REQ-572 criterion 19, REQ-580 criterion 7c): the provisioner's expire-and-purge sweep, one
  # singleton timer process (not one per tenant or workflow instance). Its own key,
  # :start_provisioner_sweep (false in config/test.exs: the same OwnershipError hazard as the pollers
  # above). Without provisioned tenants a tick is a no-op, so no further gate is needed.
  defp provisioner_sweep_children do
    if Application.get_env(:letflow, :start_provisioner_sweep, true) do
      [{Letflow.TenantProvisioner.Sweep, []}]
    else
      []
    end
  end
end
