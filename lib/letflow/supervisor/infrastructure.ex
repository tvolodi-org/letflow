defmodule Letflow.Supervisor.Infrastructure do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §1.1): owns the
  infrastructure children that used to be the first 17 entries of
  `Letflow.Application`'s own flat 20-child list, in EXACTLY the same
  relative order, under `strategy: :one_for_one` with the OTP default
  restart intensity (3 restarts/5 seconds) -- unchanged, since no
  documented incident motivates loosening it here: a crash-looping infra
  child (e.g. `Letflow.Repo` itself) indicates a fault severe enough that
  taking the whole application down is still the correct behavior.

  ISS-0418 (design `iss0418-wasm-concurrency-cap.md` §5.1) adds one further
  child, `Letflow.Engine.Wasm.InvocationLease`, bringing the total to 18 --
  see that item's own note below for placement/ordering (no dependency
  either direction, same as `Letflow.Admission`).

  REQ-352 (design `req352-unauthenticated-read-platform.md` §11.3) adds one
  further child, `Letflow.Plugs.PublicReadRateLimit.Bucket`, bringing the
  total to 19 -- placed directly after `Letflow.Metrics.Registry`, the same
  "leaf, independently-startable, no ordering dependency" placement
  reasoning that child's own comment above already states.

  ISS-0771 (design `iss0771-tenant-migration-replay-on-deploy.md` §2.2/§2.3)
  adds one further child, `Letflow.TenantProvisioning.MigrationReplayBoot`,
  bringing the total to 20 -- placed immediately after `{Ecto.Migrator,
  ...}` and before `Letflow.Oidc.ProviderRegistry`, deliberately NOT gated
  by `skip_migrations?()`; see that module's own moduledoc for the full
  reasoning.

  REQ-377 (design `req377-history-retirement-screen.md` §1) adds one
  further child, `Letflow.EventStore.RetirementTaskSupervisor`, bringing the
  total to 21 -- placed directly before `Letflow.Obs.Alerts.TaskSupervisor`
  so that child's own documented "must be LAST" invariant is preserved; see
  its own child-spec comment below.

  REQ-436 (design `req436-login-discovery-rate-limiter.md` s9) adds one
  further child, `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket`, bringing the
  total to 22 -- placed directly after `Letflow.Plugs.PublicReadRateLimit.Bucket`,
  the same "leaf, independently-startable, no ordering dependency" sibling.

  REQ-437 (design `req434-email-first-login-directory.md` s13, s15.3) adds one
  further child, `Letflow.LoginDiscovery.TaskSupervisor`, bringing the live total
  to 22 (23 listed below: child 3 is a one-shot `:ignore` hook) -- placed
  directly before `Letflow.Obs.Alerts.TaskSupervisor` so that child stays LAST.

  ## Children, in order

  1. `Letflow.Repo`
  2. `Ecto.Migrator`
  3. `Letflow.TenantProvisioning.MigrationReplayBoot` (ISS-0771: a one-shot
     boot hook that replays tenant-scoped migrations against every
     already-provisioned tenant; `start_link/1` always returns `:ignore` --
     see that module's own moduledoc)
  4. `Letflow.Oidc.ProviderRegistry` (REQ-370: a `DynamicSupervisor` of
     per-realm `Oidcc.ProviderConfiguration.Worker`s, replacing the former
     single static worker child — see that module's own moduledoc and
     `lib/letflow/design/req370-multi-issuer-oidc-verification.md` §4)
  5. `Letflow.Registry` (generic `Registry`)
  6. `Letflow.Metrics.Registry`
  7. `Letflow.Plugs.PublicReadRateLimit.Bucket`
  8. `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket` (REQ-436)
  9. `Letflow.Admission`
  10. `Letflow.InstanceSupervisor`
  11. `Letflow.SandboxPool.TaskSupervisor`
  12. `Letflow.SandboxPool`
  13. `Letflow.Engine.PluginTaskSupervisor`
  14. `Letflow.Engine.Wasm.InvocationLease`
  15. `Letflow.Engine.PluginRegistry`
  16. `Letflow.Engine.Lua.TaskSupervisor`
  17. `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor`
  18. `Letflow.Engine.Wasm.CapabilityGateTaskSupervisor`
  19. `Letflow.Engine.Wasm.ModuleVersionRegistry`
  20. `Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor`
  21. `Letflow.EventStore.RetirementTaskSupervisor`
  22. `Letflow.LoginDiscovery.TaskSupervisor` (REQ-437: off-request-path
      notifier tasks of the login-discovery endpoint)
  23. `Letflow.Obs.Alerts.TaskSupervisor`

  ## Ordering guarantees preserved (both load-bearing, unchanged from
  `Letflow.Application`'s own prior flat list)

    * ISS-0224: child 11 (`SandboxPool.TaskSupervisor`) precedes child 12
      (`{Letflow.SandboxPool, []}`) -- unchanged relative order. Every
      `SandboxPool` DB operation runs under this `Task.Supervisor` via
      `Task.Supervisor.async_nolink/3`; registering it after its dependant
      would leave a window in which a `claim/2` call exits `:noproc` inside
      a pool callback and kills the pool.
    * ISS-0429: child 23 (`Obs.Alerts.TaskSupervisor`) is the LAST child of
      this supervisor. Its "must precede either Poller's first tick"
      guarantee is now a SUPERVISOR-BOUNDARY guarantee, not merely a
      list-position fact: `Letflow.Supervisor.Pollers` is started only
      after this entire module's own `Supervisor.start_link/3` call (from
      `Letflow.Application.start/2`) has returned `{:ok, pid}`, which
      happens only once every one of these 23 children -- including this
      last one -- has itself finished starting. No interleaving is
      possible between this supervisor's last child starting and
      `Letflow.Supervisor.Pollers`' first child starting, since an entire
      supervisor boundary sits between them.
    * ISS-0418: child 14 (`Engine.Wasm.InvocationLease`) has no ordering
      dependency in either direction, mirroring `Letflow.Admission`'s own
      "no ordering dependency" precedent (see that module's moduledoc) --
      its `init/1` reads only static application config, makes no `Repo`
      call, no `Registry` lookup, and no call to any other supervised
      process. Placed directly after `PluginTaskSupervisor` as a
      readability choice (both are WASM/plugin-dispatch infrastructure),
      not a correctness requirement.
    * REQ-352: child 7 (`Plugs.PublicReadRateLimit.Bucket`) has no ordering
      dependency in either direction, mirroring `Letflow.Metrics.Registry`'s
      own "leaf, independently-startable" precedent immediately above it --
      its `init/1` creates a fresh named ETS table and reads no other
      supervised process. Placed directly after `Metrics.Registry` as a
      readability choice, not a correctness requirement.
    * REQ-436: child 8 (`Plugs.LoginDiscoveryRateLimit.Bucket`) has no ordering
      dependency in either direction, mirroring child 7 -- its `init/1`
      validates application config, creates a fresh named ETS table and calls
      no other supervised process. Placed directly after child 7 as a
      readability choice, not a correctness requirement.
    * ISS-0771: child 3 (`TenantProvisioning.MigrationReplayBoot`) has one
      ordering dependency, in one direction only -- it must follow child 2
      (`{Ecto.Migrator, ...}`), since global/public-schema migrations must be
      fully applied before any tenant-scoped replay runs. It has no
      dependents: nothing later in this list, or in
      `Letflow.Supervisor.Http`/`Letflow.Supervisor.Pollers` (both start only
      after this entire supervisor has finished), reads anything
      `MigrationReplayBoot` produces -- its value is the blocking replay
      side-effect itself, completed before `start_link/1` returns `:ignore`.

  ## `Letflow.InstanceSupervisor` placement

  Matches its CURRENT behavior only (an empty `DynamicSupervisor`,
  REQ-045/ISS-0422 unaffected) -- this is not a claim about which layer it
  belongs in once (if ever) a future requirement gives it real children;
  left explicitly open (design doc §7/§9 Q3).

  ## Task.Supervisor sprawl review (REQ-220, closes ISS-0425 part 3)

  This supervisor owns 8 separate `Task.Supervisor`s (unaffected by ISS-0418's
  `InvocationLease` addition or REQ-352's `PublicReadRateLimit.Bucket`
  addition, both ordinary `GenServer`s, not `Task.Supervisor`s; REQ-377 adds
  the 8th, `Letflow.EventStore.RetirementTaskSupervisor`).
  RECOMMENDATION: KEEP ALL 8 SEPARATE. None share a crash domain or a
  resource-contention profile that would make consolidation meaningfully
  safer or cheaper, and each pairing a reader might plausibly propose
  merging already has a stated, on-record reason not to (see below).
  Consolidated here so a reader does not need to hunt 8 separate scattered
  comments to see why none should merge; each one's own comment at its
  child-spec site above remains the source of truth for its individual
  justification.

    * `SandboxPool.TaskSupervisor` (ISS-0224) -- isolates `SandboxPool`'s
      own Ecto-sandbox-ownership `async_nolink` calls so a `claim/2`
      failure cannot exit the pool.
    * `Engine.PluginTaskSupervisor` (REQ-057) -- generic plugin-handler
      execution.
    * `Engine.Lua.TaskSupervisor` (REQ-155) -- wall-clock kill isolation
      for LUA-10 layer 2, deliberately NOT sharing `PluginTaskSupervisor`:
      a killed Lua task must not risk a concurrently running plugin task.
    * `Engine.Wasm.ModuleRegistryTaskSupervisor` (REQ-166) -- crash-isolates
      `Wasmex.start_link/1`'s unresolved-import EXIT signal during module
      registration, an upload-time-only path.
    * `Engine.Wasm.CapabilityGateTaskSupervisor` (REQ-167) -- the same
      crash-isolation need, but for capability-gated instantiation, an
      orthogonal caller/input from `ModuleRegistry` per REQ-166 design
      §2.2 -- deliberately not reusing it.
    * `Engine.Wasm.ModuleVersionRegistryTaskSupervisor` (REQ-173) -- the
      hot-reload `invoke/4` path's own outer `async_nolink` task plus its
      nested instantiation-attempt task.
    * `Obs.Alerts.TaskSupervisor` (ISS-0429) -- I/O-bound HTTP alert-hook
      delivery, unrelated to any sandbox/plugin/Lua/Wasm concern above.
    * `EventStore.RetirementTaskSupervisor` (REQ-377) -- platform-wide
      event-history retirement fanout (DDL/partition-maintenance dispatch),
      an independent concern from every other supervisor above.

  TWO CONSOLIDATION CANDIDATES CONSIDERED AND REJECTED:

    * The three Wasm `Task.Supervisor`s into one shared Wasm
      `Task.Supervisor` -- rejected. Per REQ-166 design §2.2, module
      registration, capability-gated instantiation, and hot-reload
      invocation are three genuinely orthogonal call paths, each
      independently crash-isolated on purpose: sharing one supervisor
      would mean a crash-isolated task from one path could exhaust or
      contend with tasks from an unrelated path, reintroducing the
      cross-path blast radius each was split out to avoid.
    * `Engine.PluginTaskSupervisor` and `Engine.Lua.TaskSupervisor` into
      one shared Engine `Task.Supervisor` -- rejected. REQ-155's own
      wall-clock-kill mechanism must not risk a concurrently running
      plugin task's blast radius; sharing a supervisor would couple Lua's
      kill isolation to Plugin's execution, the exact coupling REQ-155
      split them apart to prevent.

  NOT IN THIS REQUIREMENT: no Task.Supervisor removed, renamed, or merged
  as a side effect of this review -- see this section's own recommendation
  (KEEP ALL 8). All 8 remain inside this module, matching REQ-219's own
  layer assignment.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Letflow.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:letflow, :ecto_repos), skip: skip_migrations?()},
      # ISS-0771 (design iss0771-tenant-migration-replay-on-deploy.md §2.2/§2.3): a
      # minimal, one-shot boot-time child that replays tenant-scoped migrations
      # against every already-provisioned tenant on every application start -- the
      # public-schema Ecto.Migrator child above only covers the public/default
      # schema, and nothing previously replayed migrations for tenants that already
      # existed before a new tenant-scoped migration merged. Deliberately NOT gated
      # by skip_migrations?() -- see the module's own moduledoc for why. Positioned
      # here: after Ecto.Migrator (global/public-schema migrations must be fully
      # applied first) and before every other child, so no request can reach any
      # route until tenant-scoped replay has finished for every tenant.
      # start_link/1 always returns :ignore, never raises -- see its own moduledoc.
      Letflow.TenantProvisioning.MigrationReplayBoot,
      # REQ-370 (design req370-multi-issuer-oidc-verification.md §4): a
      # DynamicSupervisor owning one Oidcc.ProviderConfiguration.Worker per
      # trusted realm, started lazily on first verification attempt rather
      # than enumerated eagerly here -- its own init/1 reads no config and
      # makes no Repo call, matching Letflow.Admission's/
      # Letflow.Engine.Wasm.InvocationLease's own "no DB read inside init/1"
      # precedent. Replaces the former single static
      # {Oidcc.ProviderConfiguration.Worker, ...} child that this exact list
      # position held before this requirement (REQ-016).
      Letflow.Oidc.ProviderRegistry,
      {Registry, keys: :unique, name: Letflow.Registry},
      # REQ-194 (design req194-prometheus-metrics.md §5): the ETS-backed metrics
      # collector behind GET /metrics. A leaf, independently-startable component
      # with no startup-order dependents (nothing needs to look it up during its
      # own init/1) -- placed directly after the generic Elixir Registry above,
      # mirroring the Wasm.ModuleVersionRegistry placement precedent below ("order
      # between these two is not load-bearing").
      Letflow.Metrics.Registry,
      # REQ-352 (design req352-unauthenticated-read-platform.md §11.3): the
      # ETS-backed token bucket behind Letflow.Plugs.PublicReadRateLimit. A
      # leaf, independently-startable component with no startup-order
      # dependents, mirroring Letflow.Metrics.Registry's own placement
      # reasoning directly above -- the table must survive for the life of
      # the node, but nothing else needs to look it up during its own
      # init/1.
      Letflow.Plugs.PublicReadRateLimit.Bucket,
      # REQ-436 (design req436-login-discovery-rate-limiter.md s9): ETS-backed token
      # bucket behind Letflow.Plugs.LoginDiscoveryRateLimit. A leaf with no ordering
      # dependency; own table, shares no state with the sibling directly above.
      Letflow.Plugs.LoginDiscoveryRateLimit.Bucket,
      # ISS-1030 (design iss1030-onboarding-administrator.md s7 step 11, OQ-16): the
      # once-per-tenant-per-hour throttle for the pending-admin bind's fault WARNING.
      # A leaf with no ordering dependency; nothing looks it up during its own init/1.
      Letflow.Identity.PendingAdminGrants.FaultThrottle,
      # REQ-216 (design req216-admission-control-core.md §4): the global +
      # per-tenant admission-control counting semaphore. NO ordering
      # dependency in either direction -- see Letflow.Admission's own
      # moduledoc ("Supervision-tree placement") for the full reasoning.
      # Placed here as a readability choice, grouped with the other
      # leaf/independently-startable infrastructure children (Registry,
      # Letflow.Metrics.Registry) above, not a correctness requirement.
      {Letflow.Admission, []},
      Letflow.InstanceSupervisor,
      # ISS-0224: every SandboxPool DB operation runs under this supervisor via
      # Task.Supervisor.async_nolink/3. It MUST precede {Letflow.SandboxPool, []} --
      # Supervisor starts children in list order, so registering it after its
      # dependant would leave a window in which a claim/2 makes async_nolink exit
      # :noproc inside a pool callback and kill the pool.
      {Task.Supervisor, name: Letflow.SandboxPool.TaskSupervisor},
      {Letflow.SandboxPool, []},
      {Task.Supervisor, name: Letflow.Engine.PluginTaskSupervisor},
      # ISS-0418 (design iss0418-wasm-concurrency-cap.md §5.1): the global
      # counting-semaphore primitive bounding simultaneously in-flight WASM
      # invocations. NO ordering dependency in either direction -- see
      # Letflow.Engine.Wasm.InvocationLease's own moduledoc ("Supervision-tree
      # placement") for the full reasoning, mirroring Letflow.Admission's own
      # precedent above. Placed here as a readability choice, grouped with
      # PluginTaskSupervisor (both WASM/plugin-dispatch infrastructure), not a
      # correctness requirement. NOTE: as of this addition, NOTHING in
      # production dispatch calls try_acquire/0 yet -- only the :wasm_hang
      # test suite does (see the design doc §0/§7); this child exists so that
      # test wiring, and a future dispatch-integration requirement, have a
      # supervised instance to call into.
      {Letflow.Engine.Wasm.InvocationLease, []},
      {Letflow.Engine.PluginRegistry, plugin_registrations_from_config()},
      # REQ-155: dedicated Task.Supervisor for host-enforced wall-clock kill of Lua
      # script execution (LUA-10 layer 2). Deliberately separate from
      # PluginTaskSupervisor above -- see Letflow.Engine.Lua.Executor's moduledoc
      # for why sharing it would conflate two independently-reasoned-about
      # subsystems. No other child depends on start order here.
      {Task.Supervisor, name: Letflow.Engine.Lua.TaskSupervisor},
      # REQ-166: dedicated Task.Supervisor for ModuleRegistry.register/1's
      # stage-2 real instantiation attempt (design
      # req166-wasm-module-abi-validation.md §2.2/§1.5) -- an unresolved-import
      # crash inside Wasmex.start_link/1 delivers a linked :EXIT signal to a
      # non-trapping caller, so it must run inside a Task.Supervisor-owned
      # async_nolink/2 task, never inline. Deliberately its own supervisor, not
      # a reuse of PluginTaskSupervisor or Lua.TaskSupervisor -- module
      # registration (once per upload, off any workflow-execution hot path) is
      # an independent concern from both, per §2.2's reasoning (mirroring
      # req155-lua-wallclock-kill.md §4.4's own precedent). No other child
      # depends on start order here.
      {Task.Supervisor, name: Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor},
      # REQ-167: dedicated Task.Supervisor for CapabilityGate.start_instance/2's
      # real, manifest-gated instantiation attempt (design
      # req167-wasm-import-whitelist.md §0/§2.2's identical reasoning) -- the
      # same unresolved-import crash-propagation hazard ModuleRegistryTaskSupervisor
      # exists for, but deliberately its own supervisor rather than a reuse of
      # ModuleRegistryTaskSupervisor: module registration (REQ-166) and
      # capability-gated instantiation (REQ-167) are orthogonal concerns with
      # different inputs and different callers, per req166 §2.2's own precedent.
      # No other child depends on start order here.
      {Task.Supervisor, name: Letflow.Engine.Wasm.CapabilityGateTaskSupervisor},
      # REQ-173: the hot-reload version registry (design
      # req173-wasm-module-hot-reload.md §7) and its dedicated
      # Task.Supervisor, for invoke/4's own outer async_nolink task plus
      # the nested instantiation-attempt task it spawns internally.
      # Registration order between these two specific children is not
      # load-bearing (unlike the SandboxPool/SandboxPool.TaskSupervisor
      # pair above) -- see the design doc §7's own note.
      {Letflow.Engine.Wasm.ModuleVersionRegistry,
       name: Letflow.Engine.Wasm.ModuleVersionRegistry},
      {Task.Supervisor, name: Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor},
      # REQ-377 (design req377-history-retirement-screen.md §1): dedicated
      # Task.Supervisor for Letflow.EventStore.RetentionOperations'
      # async 202+poll platform-wide event-history retirement fanout
      # (Task.Supervisor.async_nolink/3 from the HTTP-triggering request,
      # Task.Supervisor.async_stream/4 internally per tenant schema).
      # Deliberately its own supervisor, not a reuse of any Wasm/Lua/Sandbox
      # supervisor above -- DDL/partition-maintenance dispatch is an
      # independent concern from those, mirroring
      # Wasm.ModuleRegistryTaskSupervisor's own "independent concern"
      # reasoning. No other child depends on start order here; placed before
      # Obs.Alerts.TaskSupervisor only to preserve THAT child's own
      # documented "must be LAST" invariant below.
      {Task.Supervisor, name: Letflow.EventStore.RetirementTaskSupervisor},
      # REQ-437 (design req434 s13): dedicated Task.Supervisor for the login-discovery
      # notifier tasks (Letflow.LoginDiscovery.Dispatch), so request timing does not
      # depend on mail latency and a notifier crash cannot reach another subsystem.
      # `max_children` bounds concurrency (config :letflow,
      # Letflow.LoginDiscovery.Notifier, max_concurrent). No ordering dependency;
      # placed before Obs.Alerts.TaskSupervisor only to keep THAT child LAST.
      {
        Task.Supervisor,
        # x2: each delivery uses two slots (outer closure + inner async_nolink task).
        name: Letflow.LoginDiscovery.TaskSupervisor,
        max_children: 2 * Letflow.LoginDiscovery.Dispatch.max_concurrent()
      },
      # ISS-0429 (design lib/letflow/design/iss0429-async-alert-hook-delivery.md §1):
      # dedicated Task.Supervisor isolating alert-hook delivery's HTTP POST +
      # retry/backoff loop (Letflow.Obs.Alerts.deliver_with_retry/4, dispatched from
      # fire_hooks/4) off Letflow.Scheduler.Poller's own process. Deliberately its own
      # supervisor, not a reuse of any of the six above: alert-hook delivery is
      # I/O-bound HTTP dispatch to tenant-operator-configured external endpoints, an
      # independent concern from sandbox provisioning, plugin/Lua/Wasm execution --
      # mirroring Wasm.ModuleRegistryTaskSupervisor's own "independent concern"
      # reasoning above. MUST be the LAST child of this supervisor: the Poller's own
      # first :tick runs with ZERO delay (`Process.send_after(self(), :tick, 0)` in
      # poller.ex's init/1) and, from that very first tick, can dispatch to this
      # supervisor via fire_hooks/4 -- since Letflow.Supervisor.Pollers only starts
      # after this ENTIRE supervisor (all 20 children, ISS-0418's InvocationLease,
      # REQ-352's PublicReadRateLimit.Bucket, and ISS-0771's MigrationReplayBoot
      # additions included) has finished starting, this
      # name is guaranteed registered before any Poller's first tick can run,
      # matching the ISS-0429 guarantee restated in this module's own moduledoc.
      {Task.Supervisor, name: Letflow.Obs.Alerts.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # REQ-057 §4.4/§6.4 — the seed list `Letflow.Engine.PluginRegistry.start_link/1`
  # registers at boot, then freezes automatically. Ordinary config/*.exs (or
  # runtime.exs) data -- empty by default since no plugin handler module ships yet.
  defp plugin_registrations_from_config do
    Application.get_env(:letflow, :plugin_handlers, [])
  end

  # Migrations run automatically on boot, but only inside a compiled
  # release (deploy/Dockerfile's `bin/letflow start`) — `mix ecto.migrate`
  # already covers local dev/test via README's `mix ecto.setup` /
  # the `test` alias in mix.exs, and RELEASE_NAME is unset in both.
  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
