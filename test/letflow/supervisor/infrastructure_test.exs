defmodule Letflow.Supervisor.InfrastructureTest do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §8) AC1/AC3: confirms
  `Letflow.Application`'s own top-level children list is exactly the 3 new
  supervisor modules (none of the original 20 leaf children remain direct
  children of `Letflow.Supervisor`), and that
  `Letflow.Supervisor.Infrastructure` owns the 19 expected children, in
  order, including the ISS-0224 SandboxPool.TaskSupervisor-before-SandboxPool
  ordering.

  ISS-0451 (design `iss0451-poller-crash-budget-isolation.md` §3.4) added a
  4th top-level child, `Letflow.Supervisor.PollersBreaker`, listed after
  `Letflow.Supervisor.Pollers` and before `Letflow.Supervisor.Http` -- the
  top-level children-count assertion below is updated to match; nothing
  else in this module changes, since `PollersBreaker` does not touch
  `Letflow.Supervisor.Infrastructure`'s own child list or ordering.

  REQ-352 (design `req352-unauthenticated-read-platform.md` §11.3) added a
  further `Letflow.Supervisor.Infrastructure` child,
  `Letflow.Plugs.PublicReadRateLimit.Bucket`, bringing that list from 18 to
  19 -- placed directly after `Letflow.Metrics.Registry`, unaffected
  ordering everywhere else.

  REQ-377 (`lib/letflow/design/req377-history-retirement-screen.md` §1) added
  a further child, `Letflow.EventStore.RetirementTaskSupervisor` (the
  dedicated `Task.Supervisor` `RetentionOperations.retire_oldest_eligible_month/1`
  dispatches its platform-wide tenant-schema fanout under -- see that
  module's own moduledoc), bringing this list from 19 to 20 -- placed
  directly before `Letflow.Obs.Alerts.TaskSupervisor`, matching
  `lib/letflow/supervisor/infrastructure.ex`'s own updated moduledoc
  ("bringing the total to 21" top-level+nested children). ISS-0429's own
  "last child" invariant (test below) is unaffected: `Obs.Alerts.TaskSupervisor`
  remains the last child either way.

  REQ-437 (design `req434-email-first-login-directory.md` s13, s15.3) added
  `Letflow.LoginDiscovery.TaskSupervisor` directly before
  `Letflow.Obs.Alerts.TaskSupervisor`, bringing the live list from 21 to 22.

  ISS-1030 PR 2 (design `iss1030-onboarding-administrator.md` s7 step 11, OQ-16) added
  `Letflow.Identity.PendingAdminGrants.FaultThrottle` directly after
  `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket`, bringing the live list from 22 to 23.

  Read-only against the already-running, application-supervised singletons
  -- no restart, no config mutation, safe to run `async: true`.

  `Supervisor.which_children/1` returns children in REVERSE start order
  (OTP's own documented/observed behavior -- each child is prepended to
  the supervisor's internal list as it starts), so every ordering
  assertion below reverses the raw result back to child-spec/startup
  order before comparing.
  """

  use ExUnit.Case, async: true

  test "Letflow.Supervisor has exactly 4 top-level children: Infrastructure, Pollers, PollersBreaker, Http" do
    children = Supervisor.which_children(Letflow.Supervisor)

    ids =
      children
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    assert ids == [
             Letflow.Supervisor.Infrastructure,
             Letflow.Supervisor.Pollers,
             Letflow.Supervisor.PollersBreaker,
             Letflow.Supervisor.Http
           ]

    # AC1: none of the original 20 leaf children remain DIRECT children of
    # Letflow.Supervisor -- they are now two levels down.
    refute Letflow.Repo in ids
    refute Letflow.Registry in ids
    refute Letflow.InstanceSupervisor in ids
    refute Letflow.Scheduler.Poller in ids
  end

  test "Letflow.Supervisor.Infrastructure owns the 25 expected children, in order" do
    children = Supervisor.which_children(Letflow.Supervisor.Infrastructure)

    ids =
      children
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    assert ids == [
             Letflow.Repo,
             Ecto.Migrator,
             # REQ-370: the single static Oidcc.ProviderConfiguration.Worker child was
             # replaced by Letflow.Oidc.ProviderRegistry -- a DynamicSupervisor owning
             # one per-realm Oidcc.ProviderConfiguration.Worker, started lazily, per
             # design doc req370-multi-issuer-oidc-verification.md §4.2. Same list
             # position (child #3), everything else unaffected.
             Letflow.Oidc.ProviderRegistry,
             Letflow.Registry,
             Letflow.Metrics.Registry,
             # REQ-517 PR 2b: persisted shadow-evidence counters (ETS + flush). A leaf,
             # placed directly after Letflow.Metrics.Registry.
             Letflow.Api.Scope.ShadowEvidence,
             # REQ-352: ETS-backed token bucket behind
             # Letflow.Plugs.PublicReadRateLimit. No ordering dependency --
             # mirrors Letflow.Metrics.Registry's own "leaf,
             # independently-startable" placement immediately above it.
             Letflow.Plugs.PublicReadRateLimit.Bucket,
             # REQ-436: sibling leaf bucket for Letflow.Plugs.LoginDiscoveryRateLimit.
             Letflow.Plugs.LoginDiscoveryRateLimit.Bucket,
             # ISS-1030 PR 2: once-per-tenant-per-hour throttle for the pending-admin
             # bind's fault warning. A leaf with no ordering dependency.
             Letflow.Identity.PendingAdminGrants.FaultThrottle,
             Letflow.Admission,
             Letflow.InstanceSupervisor,
             Letflow.SandboxPool.TaskSupervisor,
             Letflow.SandboxPool,
             Letflow.Engine.PluginTaskSupervisor,
             # ISS-0418: WASM invocation concurrency cap. No ordering dependency --
             # it holds only its own lease state and is not consulted by any
             # sibling's start_link.
             Letflow.Engine.Wasm.InvocationLease,
             Letflow.Engine.PluginRegistry,
             Letflow.Engine.Lua.TaskSupervisor,
             # GH 2534 (decision 0053 D8): the tenant-script admission server, a second
             # Letflow.Admission with monitor_callers: true, beside the Lua TaskSupervisor.
             Letflow.Engine.Lua.ScriptAdmission,
             Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor,
             Letflow.Engine.Wasm.CapabilityGateTaskSupervisor,
             Letflow.Engine.Wasm.ModuleVersionRegistry,
             Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor,
             # REQ-377: dedicated Task.Supervisor for the platform-wide
             # event-history-retirement fanout (RetentionOperations.retire_oldest_eligible_month/1).
             # No ordering dependency -- placed directly before
             # Obs.Alerts.TaskSupervisor per infrastructure.ex's own child list.
             Letflow.EventStore.RetirementTaskSupervisor,
             # REQ-437: dedicated Task.Supervisor for login-discovery notifier tasks,
             # placed before Obs.Alerts.TaskSupervisor, which stays last.
             Letflow.LoginDiscovery.TaskSupervisor,
             Letflow.Obs.Alerts.TaskSupervisor
           ]

    assert length(ids) == 25
  end

  test "ISS-0224: SandboxPool.TaskSupervisor precedes SandboxPool" do
    ids =
      Letflow.Supervisor.Infrastructure
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    task_supervisor_index = Enum.find_index(ids, &(&1 == Letflow.SandboxPool.TaskSupervisor))
    sandbox_pool_index = Enum.find_index(ids, &(&1 == Letflow.SandboxPool))

    assert task_supervisor_index < sandbox_pool_index
  end

  test "ISS-0429: Obs.Alerts.TaskSupervisor is the last child of Infrastructure" do
    ids =
      Letflow.Supervisor.Infrastructure
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    assert List.last(ids) == Letflow.Obs.Alerts.TaskSupervisor
  end
end
