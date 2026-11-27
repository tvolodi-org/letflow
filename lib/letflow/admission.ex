defmodule Letflow.Admission do
  @moduledoc """
  Admission-control core (REQ-216, closes ISS-0431 part 1) — a hand-rolled,
  pure-BEAM `GenServer` implementing a global counting semaphore composed
  with per-tenant counting semaphores, all drawing against the SAME global
  budget. See `lib/letflow/design/req216-admission-control-core.md` for the
  full design rationale; this moduledoc restates only what a caller or a
  future maintainer needs.

  This module is CORE ONLY: no HTTP or Poller-specific vocabulary appears
  anywhere here. The HTTP wiring lives in `Letflow.Plugs.Admission` (REQ-217)
  and reaches this module only through the client functions below; the
  observability surface of T-3034 (the counters, the refusal line, the stale
  sweep) is rendered by `Letflow.Admission.Observability`, which is a leaf on
  top of this module.

  ## Process shape: one GenServer, not one-per-pool

  A single supervised `GenServer` holds BOTH the global counter and the map
  of per-tenant counters in one state term (design doc §1). This is what
  makes a `{:tenant, schema}` admission decision atomic across both budgets
  with no second coordination mechanism: a single process's mailbox already
  serializes every `handle_call/3` invocation, so checking and mutating both
  counters within one callback is indivisible for free. `Letflow.SandboxPool`
  (REQ-039/ISS-0224) is prior art for the same reasoning applied to a
  structurally similar, single-resource case.

  There is no wait queue: `try_acquire/2` is a single synchronous decision
  against current state, never parked. On exhaustion it returns
  `{:error, :capacity}` immediately.

  ## Atomicity algorithm

  A `{:tenant, schema}` call is handled as ONE `handle_call/3` clause that
  first EVALUATES both admission conditions as a pure, read-only computation
  against the current state — `global_in_use < global_cap` AND
  `tenant.in_use < per_tenant_cap` — without mutating any counter or `refs`
  yet. Only if BOTH conditions hold does the same clause then mutate BOTH
  counters and insert the new ref, before returning `{:ok, ref}`. If either
  condition is false, the clause returns `{:error, :capacity}` immediately
  with ZERO mutation of any counter or of `refs`. There is no rollback step
  anywhere in this design: nothing is ever provisionally granted and then
  undone. The same order applies identically to `:global` calls, minus the
  per-tenant half of the condition.

  ## Per-tenant cap: computed, not stored

  `state.tenants` stores only each tenant's own `in_use` count — never a
  cached per-tenant cap. On every `{:tenant, _}` admission decision, that
  tenant's cap is derived fresh: `max(div(global_cap, map_size(tenants)), 1)`
  (integer division, floored at 1). Deriving it fresh on every call is what
  makes the cap track the live tracked-tenant count with no second code path
  that could let a cached value drift.

  **Invariant: recomputed caps gate only FUTURE decisions, never
  retroactively revoke an already-held admission.** The divisor
  (`map_size(tenants)`) can grow between two admissions held by the SAME
  tenant, shrinking that tenant's computed share below its current `in_use`.
  Nothing in this module walks `refs` after a recomputation to force-release
  entries, raises on a holder's own eventual `release/2`, or sends a
  forced-release message. A tenant sitting over its newly-shrunk share
  simply cannot successfully call `try_acquire/2` again until enough of its
  own `release/2` calls bring `in_use` back under the new cap — every ref it
  already holds remains valid and freely releasable for its full natural
  lifetime.

  ## Lazy tenant-entry creation; deactivation-triggered eviction (ISS-0437)

  A `{:tenant, schema}` entry is created in `state.tenants` (with
  `in_use: 0`) the first time `try_acquire/2` is called for a schema not
  already tracked, BEFORE the admission decision is evaluated — so that
  tenant is immediately counted in the fair-share divisor for its own first
  attempt. This happens regardless of whether the ensuing admission
  succeeds or is rejected.

  Entries are evicted exactly once, on tenant deactivation, via
  `Letflow.Routers.Tenants`'s call to `forget_tenant/2` after
  `Identity.deactivate_tenant/1` succeeds (see
  `lib/letflow/design/iss0437-admission-tenant-eviction.md` §3) — this
  closes the correctness/fairness gap ISS-0437 reported (a deactivated
  tenant's entry permanently diluting every remaining active tenant's
  fair-share cap), WITHOUT reintroducing the oscillation risk this same
  section otherwise warns against for a merely-*idle*-but-still-active
  tenant: deactivation is a distinct, deliberate, rare administrative act,
  not an idle/burst cycle, so an entry for a tenant that is
  idle-but-active (no deactivation) is still never evicted, exactly as
  before. A stale `Ref` acquired before eviction is tolerated at release
  time via a per-schema generation counter (`state.tenant_generations`,
  see `release_tenant/3` below) that survives eviction and distinguishes a
  reactivated tenant's fresh epoch from a prior, discarded one. Beyond the
  deactivation trigger, state growth is still bounded only by the count of
  distinct tenant schemas that have EVER attempted admission since the
  last process restart, not by concurrently-active tenants — a real
  cardinality bound for the still-open idle-but-never-deactivated case
  (time-windowed eviction or an LRU cap) remains out of scope here (design
  doc §3, §9 OQ-2, residual note). Do not implement further eviction
  against this module without a design doc revision.

  ## Crash / restart semantics

  On a crash of this process (default `:one_for_one`, no strategy
  override), `init/1` recomputes `global_cap` from current config and
  starts with `global_in_use: 0`, `tenants: %{}`, `refs: %{}` — all
  in-flight admissions are silently forgotten. This is the SAFE failure
  direction: it can only under-count (transiently widen admission), never
  over-count (permanently wedge admission shut). A caller-side crash (a
  process that acquired a ref and dies without releasing it) is a
  DIFFERENT scenario: this module does not monitor callers by default,
  unlike `Letflow.SandboxPool`'s owner-monitor mechanism — a leaked ref stays
  counted against its budget until this process itself restarts or the ref is
  explicitly released.

  ## Caller monitoring on the HTTP instance (T-3034)

  The HTTP admission instance (the one `Letflow.Plugs.Admission` talks to) is
  started with `monitor_callers: true`, so a request whose PROCESS dies while
  it still holds a ref releases that ref through the `:DOWN` path instead of
  leaking it until the next restart. This is the only change to the crash
  semantics above: the "does not monitor callers" sentence describes the
  DEFAULT of `start_link/1`, not the HTTP instance, which opts in exactly as
  `Letflow.Engine.Lua.ScriptAdmission` already does (see the next section).
  The leak it closes is real on a keep-alive connection whose peer goes away
  mid-request: without the monitor the global budget loses one unit per such
  request, and the pool wedges shut (`global_in_use` never falls back).

  ## Observability counters (T-3034)

  Besides the admission decision itself this module keeps the numbers an
  operator needs to explain a refusal (the QA evidence of T-3034: 25 of 26
  recorded 503 bodies were the GLOBAL gate, on a stable build, while one smoke
  ran):

    * `pool_size`, `reserved_headroom` and `global_cap` — the budget that is
      ACTUALLY applied, so the infra values (`POOL_SIZE`, `RESERVED_HEADROOM`)
      are visible from the running node instead of only from the config.
    * `rejections` — the number of refusals since this process started, split
      by kind (`:global` / `:tenant`).
    * `tracked_tenants` — `map_size(state.tenants)`, the fair-share divisor,
      so a per-tenant cap that shrank to 1 can be explained.
    * the per-tenant in-flight rows with the CLASS of each in-flight
      admission and its age — the "who is holding the slots" answer.

  `counters/1` is the read-only snapshot; it is the only new read surface and
  it never mutates state. The module stays free of HTTP vocabulary: the class
  is an OPAQUE label the caller passes in (`opts[:class]` — in the HTTP wiring
  the route pattern of the request) and this module stores it verbatim. It
  never parses it, never renders it into a route and never reads a request
  path.

  ## Stale in-flight requests (T-3034)

  An admission that is held longer than the age bound (config
  `:letflow, :admission, :max_in_flight_age_ms`, default 120 000 ms) is
  LOGGED ONCE with its class and its age. It is NOT released: this
  module's own contract above (the "recomputed caps gate only FUTURE
  decisions" rule) forbids revoking a held admission, and a forced release
  would hand the unit to a request that is still running. A bound of 0 (or
  less) switches the sweep off entirely.

  There is no long-poll and no SSE route in the product, so every admission
  is an ordinary request/response: the bound catches a slow ordinary request
  (a heavy import or export, a long script run), never a streaming consumer
  that would hold its slot for the life of the connection.

  ## Opt-in caller monitoring (GH 2534, decision 0053 D8)

  `start_link(monitor_callers: true)` makes every successful `try_acquire/2`
  monitor the acquiring pid; that pid's `:DOWN` releases its slot (and
  `release/2` demonitors), the same shape as
  `Letflow.Engine.Wasm.InvocationLease`. Used by the tenant-script admission
  server `Letflow.Engine.Lua.ScriptAdmission`, whose slot holder is the per-run
  watchdog: a killed watchdog (and so a dead dispatcher) can never leak a slot.
  T-3034 opts the HTTP instance in as well (see "Caller monitoring on the HTTP
  instance" above): the holder of an HTTP admission ref is the request
  process, so its death is the leak guard.

  ## Supervision-tree placement — no ordering dependency (AC6)

  `Letflow.Admission` has NO start-order dependency on any other child in
  `Letflow.Application`'s supervision tree, and no other child depends on it
  starting first: its `init/1` reads only static application config
  (`Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size]` and
  `Application.get_env(:letflow, :admission, [])`), makes no `Repo` call, no
  `Registry` lookup, and no call to any other supervised process during
  `init/1` or in either callback. Nothing in this requirement's scope calls
  `try_acquire/2` from another child's own `init/1`, so there is no analogue
  to the `SandboxPool`/`SandboxPool.TaskSupervisor` or
  `Obs.Alerts.TaskSupervisor`/`scheduler_children()` ordering hazards
  documented elsewhere in `application.ex`. This mirrors REQ-173/REQ-166's
  own "no ordering dependency" precedent comments in `application.ex`.
  """

  use GenServer

  @typedoc "Which budget an admission is checked and consumed against."
  @type pool_selector :: :global | {:tenant, tenant_schema :: String.t()}

  @default_reserved_headroom 2
  @default_max_in_flight_age_ms 120_000
  @default_stale_sweep_interval_ms 1_000
  @top_tenants 5

  defmodule Ref do
    @moduledoc """
    An opaque admission handle returned by `Letflow.Admission.try_acquire/2`.
    Callers must not pattern-match on or construct this struct directly —
    only `Letflow.Admission.release/2` consumes it. See the design doc §2.1
    for why it carries both fields rather than a bare reference.
    """

    @enforce_keys [:id, :pool]
    defstruct [:id, :pool]

    @type t :: %__MODULE__{id: reference(), pool: Letflow.Admission.pool_selector()}
  end

  @typedoc "See `Letflow.Admission.Ref` — opaque, must not be pattern-matched on by callers."
  @type admission_ref :: Ref.t()

  @typedoc """
  The read-only snapshot of this instance's admission counters (T-3034).

  `tenants` rows carry the RAW tenant schema name — the caller that renders
  them is responsible for hashing it (see `Letflow.Admission.Observability`);
  this module never renders a tenant identifier.
  """
  @type counters :: %{
          tracked_tenants: non_neg_integer(),
          in_use: non_neg_integer(),
          cap: pos_integer(),
          reserved_headroom: pos_integer(),
          pool_size: pos_integer(),
          rejections: %{global: non_neg_integer(), tenant: non_neg_integer()},
          tenants: [
            %{tenant: String.t(), in_use: non_neg_integer(), oldest_ms: non_neg_integer()}
          ],
          oldest: %{tenant: String.t(), route: String.t(), age_ms: non_neg_integer()} | nil
        }

  # Client API

  @doc """
  Starts the admission-control server. `opts` accepts `:name` (default
  `__MODULE__`), `:monitor_callers` (default `false`; see "Opt-in caller
  monitoring"), `:pool_size`/`:reserved_headroom` overrides for test
  isolation (mirrors `Letflow.SandboxPool.start_link/1`'s
  `Keyword.get_lazy/3` idiom), and `:max_in_flight_age_ms` /
  `:stale_sweep_interval_ms` (the stale in-flight sweep of T-3034; see
  "Stale in-flight requests"). Absent overrides fall back to
  `Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size]`,
  `Application.get_env(:letflow, :admission, [])[:reserved_headroom]`
  (default #{@default_reserved_headroom}),
  `Application.get_env(:letflow, :admission, [])[:max_in_flight_age_ms]`
  (default #{@default_max_in_flight_age_ms}) and
  `Application.get_env(:letflow, :admission, [])[:stale_sweep_interval_ms]`
  (default #{@default_stale_sweep_interval_ms}).
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    pool_size =
      Keyword.get_lazy(opts, :pool_size, fn ->
        Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size]
      end)

    reserved_headroom =
      Keyword.get_lazy(opts, :reserved_headroom, fn ->
        Application.get_env(:letflow, :admission, [])[:reserved_headroom] ||
          @default_reserved_headroom
      end)

    max_in_flight_age_ms =
      Keyword.get_lazy(opts, :max_in_flight_age_ms, fn ->
        Application.get_env(:letflow, :admission, [])[:max_in_flight_age_ms] ||
          @default_max_in_flight_age_ms
      end)

    stale_sweep_interval_ms =
      Keyword.get_lazy(opts, :stale_sweep_interval_ms, fn ->
        Application.get_env(:letflow, :admission, [])[:stale_sweep_interval_ms] ||
          @default_stale_sweep_interval_ms
      end)

    GenServer.start_link(
      __MODULE__,
      %{
        pool_size: pool_size,
        reserved_headroom: reserved_headroom,
        monitor_callers: Keyword.get(opts, :monitor_callers, false),
        max_in_flight_age_ms: max_in_flight_age_ms,
        stale_sweep_interval_ms: stale_sweep_interval_ms
      },
      name: name
    )
  end

  @doc """
  Attempts to acquire one admission unit against `pool`. `:global` consumes
  only the global budget; `{:tenant, schema}` consumes BOTH the global
  budget and that tenant's own fair-share budget, atomically (see
  moduledoc's "Atomicity algorithm"). Returns `{:error, :capacity}` with no
  side effect at all if either applicable condition fails.

  `server` defaults to `__MODULE__`, matching
  `Letflow.SandboxPool.claim/2`'s own convention, so tests can start an
  isolated instance under a distinct name.

  `opts[:class]` (T-3034) is an OPAQUE label the caller attaches to the
  admission — in the HTTP wiring the ROUTE CLASS of the request (the route
  pattern, never the raw path). This module stores it verbatim, uses it only
  to tell an operator which request class holds the budget, and never parses
  or renders it. A missing or empty class is stored as `"unknown"`.
  """
  @spec try_acquire(pool_selector(), server :: GenServer.server(), opts :: keyword()) ::
          {:ok, admission_ref()} | {:error, :capacity}
  def try_acquire(pool, server \\ __MODULE__, opts \\ [])

  def try_acquire(:global, server, opts) do
    GenServer.call(server, {:try_acquire, :global, class_of(opts)})
  end

  def try_acquire({:tenant, schema} = pool, server, opts) when is_binary(schema) do
    GenServer.call(server, {:try_acquire, pool, class_of(opts)})
  end

  defp class_of(opts) do
    case Keyword.get(opts, :class) do
      class when is_binary(class) and class != "" -> class
      _other -> "unknown"
    end
  end

  @doc """
  Releases a previously-acquired admission, freeing exactly the budget(s) it
  was acquired against. Idempotent up to the ref's own state membership:
  releasing a ref whose `id` is not present in the server's live-refs set
  (already released, never acquired, or a hand-constructed struct) is a
  documented no-op — always `:ok`, never a raise.

  `server` defaults to `__MODULE__`.
  """
  @spec release(admission_ref(), server :: GenServer.server()) :: :ok
  def release(%Ref{} = ref, server \\ __MODULE__) do
    GenServer.call(server, {:release, ref})
  end

  @doc """
  Evicts `schema`'s tracked entry from `state.tenants`, unconditionally and
  idempotently (a no-op, still returning `:ok`, if `schema` is not
  currently a key). Also advances `schema`'s entry in `state.tenant_generations`
  by one, independently of whether `schema` was present in `state.tenants` —
  this is what lets a stale `Ref` acquired before this call be recognized as
  stale (rather than corrupting a freshly reactivated tenant's bookkeeping)
  at release time, even across a deactivate -> reactivate interleaving. See
  `lib/letflow/design/iss0437-admission-tenant-eviction.md` §1/§2.1 and this
  module's own moduledoc "Lazy tenant-entry creation; deactivation-triggered
  eviction (ISS-0437)" section.

  Does not touch `global_cap`, `global_in_use`, or `reserved_headroom`.

  `server` defaults to `__MODULE__`, mirroring every other client function
  in this module.
  """
  @spec forget_tenant(schema :: String.t(), server :: GenServer.server()) :: :ok
  def forget_tenant(schema, server \\ __MODULE__) when is_binary(schema) do
    GenServer.call(server, {:forget_tenant, schema})
  end

  @doc """
  Returns this instance's own `reserved_headroom`, live from GenServer state —
  the identical value that instance's own `global_cap` was derived from at
  `init/1` (see moduledoc/state-shape comment below), whether this instance was
  started from config defaults or a `start_link/1` `opts` override. Added per
  `lib/letflow/design/iss0421-poller-bounded-concurrency.md` §3b/§7 so callers
  (e.g. `Letflow.Scheduler.Poller`'s unwrapped sweep) can derive a concurrency
  bound that always stays in lockstep with this instance's actual headroom,
  rather than duplicating it as an independent literal.

  `server` defaults to `__MODULE__`, mirroring `try_acquire/2`/`release/2`.
  """
  @spec reserved_headroom(server :: GenServer.server()) :: pos_integer()
  def reserved_headroom(server \\ __MODULE__) do
    GenServer.call(server, :reserved_headroom)
  end

  @doc """
  Returns this instance's own `global_cap`, live from GenServer state — the
  same value the six Admission-gated `Letflow.Scheduler.Poller` sweeps use as
  their `Task.async_stream/3` `max_concurrency:` bound, whether this instance
  was started from config defaults or a `start_link/1` `opts` override. Added
  per `lib/letflow/design/iss0421-poller-bounded-concurrency.md` §3a/§3c/§7 so
  callers derive a concurrency bound that always stays in lockstep with this
  instance's actual global cap, rather than duplicating it as an independent
  literal.

  `server` defaults to `__MODULE__`, mirroring `reserved_headroom/1`.
  """
  @spec global_cap(server :: GenServer.server()) :: pos_integer()
  def global_cap(server \\ __MODULE__) do
    GenServer.call(server, :global_cap)
  end

  @doc """
  Platform-wide admission usage: `in_use` units currently held and the `cap`
  (`pool_size - reserved_headroom`). Read-only, O(1), no tenant data; feeds the
  two label-free gauges in `Letflow.Metrics.Exposition` (T-1613).
  """
  @spec usage(server :: GenServer.server()) :: %{in_use: non_neg_integer(), cap: pos_integer()}
  def usage(server \\ __MODULE__) do
    GenServer.call(server, :usage)
  end

  @doc """
  The read-only observability snapshot of this instance (T-3034): the budget
  that is actually applied, the refusals since this process started (split by
  kind), the fair-share divisor, and the per-tenant in-flight rows with the
  route class and the age of each in-flight admission.

  The `tenants` rows carry the RAW tenant schema name and the `oldest` row
  carries the raw schema name too: the caller that renders them hashes the
  name (`Letflow.Admission.Observability` does). This module never renders a
  tenant identifier itself.

  Read-only: the snapshot never mutates the counters. `server` defaults to
  `__MODULE__`, mirroring every other client function in this module.
  """
  @spec counters(server :: GenServer.server()) :: counters()
  def counters(server \\ __MODULE__) do
    # A short timeout on purpose: the public liveness route reads these
    # counters, and a liveness probe must never wait long for an observability
    # figure. A timeout is an exit, which the caller renders as "the counters
    # are not available" -- never as a failure of the route it reads.
    GenServer.call(server, :counters, 1_000)
  end

  # GenServer callbacks

  # State shape (design doc §2.2; reserved_headroom added per
  # lib/letflow/design/iss0421-poller-bounded-concurrency.md §3b/§7;
  # generation/eviction fields added per
  # lib/letflow/design/iss0437-admission-tenant-eviction.md §2.1/§5(a);
  # pool_size/rejections/ref-metadata added per T-3034):
  #
  #   %{
  #     global_cap:         pos_integer(),               # fixed at init/1, from config
  #     global_in_use:      non_neg_integer(),
  #     tenants:            %{optional(String.t()) => %{in_use: non_neg_integer(), generation: non_neg_integer()}},
  #     refs:               %{optional(reference()) => {pool_selector(), non_neg_integer() | nil, meta}},
  #     reserved_headroom:  pos_integer(),                 # fixed at init/1, same source as global_cap
  #     pool_size:          pos_integer(),                 # fixed at init/1, the value global_cap was derived from
  #     tenant_generations: %{optional(String.t()) => non_neg_integer()}  # never deleted, only incremented (forget_tenant/2)
  #     rejections:         %{global: non_neg_integer(), tenant: non_neg_integer()}  # since init/1
  #     max_in_flight_age_ms: pos_integer(),               # the stale in-flight bound (T-3034)
  #     stale_sweep_interval_ms: pos_integer()             # the sweep period (T-3034)
  #   }
  #
  # `meta` is `%{class: String.t(), at: integer, stale_logged?: boolean}` — the
  # opaque route class the caller attached to the admission, the monotonic
  # millisecond stamp of the acquisition, and whether the stale sweep has
  # already logged this admission (so it is logged EXACTLY once).
  @impl true
  def init(%{pool_size: pool_size, reserved_headroom: reserved_headroom} = args) do
    global_cap = max(pool_size - reserved_headroom, 1)
    max_in_flight_age_ms = Map.get(args, :max_in_flight_age_ms, @default_max_in_flight_age_ms)

    stale_sweep_interval_ms =
      Map.get(args, :stale_sweep_interval_ms, @default_stale_sweep_interval_ms)

    state = %{
      global_cap: global_cap,
      global_in_use: 0,
      tenants: %{},
      refs: %{},
      reserved_headroom: reserved_headroom,
      pool_size: pool_size,
      tenant_generations: %{},
      rejections: %{global: 0, tenant: 0},
      max_in_flight_age_ms: max_in_flight_age_ms,
      stale_sweep_interval_ms: stale_sweep_interval_ms,
      # GH 2534 / decision 0053 D8: opt-in caller monitoring. When true, every
      # acquire monitors the acquiring pid and its :DOWN releases the slot, so a
      # killed holder cannot leak budget. `monitors` maps monitor ref -> admission
      # id, `ref_monitors` the reverse. Default false; the HTTP instance opts in
      # (T-3034) so a dead request process cannot leak a global slot.
      monitor_callers: Map.get(args, :monitor_callers, false),
      monitors: %{},
      ref_monitors: %{}
    }

    # The stale in-flight sweep (T-3034): a self-message, so the process keeps
    # no dependency on any other supervised process (same rule as init/1
    # itself). A bound of 0 (or less) switches the sweep off entirely.
    if max_in_flight_age_ms > 0 and stale_sweep_interval_ms > 0 do
      Process.send_after(self(), :sweep_stale, stale_sweep_interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:try_acquire, :global, class}, from, state) do
    if state.global_in_use < state.global_cap do
      id = make_ref()
      ref = %Ref{id: id, pool: :global}

      new_state = %{
        state
        | global_in_use: state.global_in_use + 1,
          refs: Map.put(state.refs, id, {:global, nil, new_meta(class)})
      }

      {:reply, {:ok, ref}, maybe_monitor(new_state, from, id)}
    else
      {:reply, {:error, :capacity}, count_rejection(state, :global)}
    end
  end

  def handle_call({:try_acquire, {:tenant, schema} = pool, class}, from, state) do
    # Lazy tenant-entry creation happens BEFORE the admission decision, and
    # regardless of whether that decision ultimately succeeds -- an attempt
    # itself, not only a successful one, is what counts a tenant into the
    # fair-share divisor (moduledoc's "Lazy tenant-entry creation").
    state = ensure_tenant_tracked(state, schema)

    tenant_entry = state.tenants[schema]
    tenant_in_use = tenant_entry.in_use
    per_tenant_cap = per_tenant_cap(state)

    if state.global_in_use < state.global_cap and tenant_in_use < per_tenant_cap do
      id = make_ref()
      ref = %Ref{id: id, pool: pool}

      new_state = %{
        state
        | global_in_use: state.global_in_use + 1,
          tenants: Map.update!(state.tenants, schema, &%{&1 | in_use: &1.in_use + 1}),
          refs: Map.put(state.refs, id, {pool, tenant_entry.generation, new_meta(class)})
      }

      {:reply, {:ok, ref}, maybe_monitor(new_state, from, id)}
    else
      {:reply, {:error, :capacity}, count_rejection(state, :tenant)}
    end
  end

  def handle_call(:reserved_headroom, _from, state) do
    {:reply, state.reserved_headroom, state}
  end

  def handle_call(:global_cap, _from, state) do
    {:reply, state.global_cap, state}
  end

  def handle_call(:usage, _from, state) do
    {:reply, %{in_use: state.global_in_use, cap: state.global_cap}, state}
  end

  def handle_call(:counters, _from, state) do
    {:reply, build_counters(state), state}
  end

  def handle_call({:release, %Ref{id: id}}, _from, state) do
    {:reply, :ok, release_id(state, id)}
  end

  def handle_call({:forget_tenant, schema}, _from, state) do
    new_state = %{
      state
      | tenants: Map.delete(state.tenants, schema),
        tenant_generations: Map.update(state.tenant_generations, schema, 1, &(&1 + 1))
    }

    {:reply, :ok, new_state}
  end

  # GH 2534 / 0053 D8: a monitored holder that exits releases its slot.
  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, id} -> {:noreply, release_id(state, id)}
      :error -> {:noreply, state}
    end
  end

  # T-3034: the stale in-flight sweep. Every admission that has been held
  # longer than the age bound is logged ONCE with its route class and its age.
  # It is NOT released: this module's own contract forbids revoking a held
  # admission (see the moduledoc's "Stale in-flight requests").
  def handle_info(:sweep_stale, state) do
    Process.send_after(self(), :sweep_stale, state.stale_sweep_interval_ms)
    {:noreply, sweep_stale(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The server's own `refs` entry (keyed by the unforgeable `id`) is the sole
  # source of truth for which pool (and, for a tenant pool, which generation) to
  # free -- the caller-supplied struct's `pool` field is never trusted, so a
  # mismatched or hand-altered `pool` field on an otherwise-valid ref cannot under-
  # or over-release. An unknown id (already released, never acquired, or a
  # hand-constructed struct) is a documented idempotent no-op.
  defp release_id(state, id) do
    state = drop_monitor(state, id)

    case Map.pop(state.refs, id) do
      {nil, _refs} ->
        state

      {{stored_pool, captured_generation, _meta}, refs} ->
        %{
          state
          | global_in_use: state.global_in_use - 1,
            tenants: release_tenant(state.tenants, stored_pool, captured_generation),
            refs: refs
        }
    end
  end

  defp maybe_monitor(%{monitor_callers: true} = state, {pid, _tag}, id) do
    monitor_ref = Process.monitor(pid)

    %{
      state
      | monitors: Map.put(state.monitors, monitor_ref, id),
        ref_monitors: Map.put(state.ref_monitors, id, monitor_ref)
    }
  end

  defp maybe_monitor(state, _from, _id), do: state

  defp drop_monitor(state, id) do
    case Map.pop(state.ref_monitors, id) do
      {nil, _} ->
        state

      {monitor_ref, ref_monitors} ->
        Process.demonitor(monitor_ref, [:flush])
        %{state | ref_monitors: ref_monitors, monitors: Map.delete(state.monitors, monitor_ref)}
    end
  end

  defp ensure_tenant_tracked(state, schema) do
    if Map.has_key?(state.tenants, schema) do
      state
    else
      generation = Map.get(state.tenant_generations, schema, 0)

      %{
        state
        | tenants: Map.put(state.tenants, schema, %{in_use: 0, generation: generation})
      }
    end
  end

  # --- observability (T-3034) -------------------------------------------------------------

  # The metadata of one admission: the opaque route class the caller attached,
  # the monotonic millisecond stamp of the acquisition, and whether the stale
  # sweep already logged this admission.
  defp new_meta(class) do
    %{class: class, at: System.monotonic_time(:millisecond), stale_logged?: false}
  end

  defp count_rejection(state, kind) do
    %{state | rejections: Map.update!(state.rejections, kind, &(&1 + 1))}
  end

  defp build_counters(state) do
    now = System.monotonic_time(:millisecond)

    {rows, oldest} =
      Enum.reduce(state.refs, {[], nil}, fn {id, {pool, _generation, meta}}, {rows, oldest} ->
        case pool do
          {:tenant, schema} ->
            age = max(now - meta.at, 0)
            row = %{tenant: schema, in_use: 1, oldest_ms: age, route: meta.class, id: id}
            {rows ++ [row], older(oldest, row)}

          :global ->
            {rows, oldest}
        end
      end)

    per_tenant =
      rows
      |> Enum.group_by(& &1.tenant)
      |> Enum.map(fn {schema, held} ->
        ages = Enum.map(held, & &1.oldest_ms)

        %{
          tenant: schema,
          in_use: length(held),
          oldest_ms: Enum.max(ages),
          routes:
            held
            |> Enum.group_by(& &1.route)
            |> Enum.map(fn {class, same} -> {class, length(same)} end)
        }
      end)
      |> Enum.sort_by(&{-&1.in_use, -&1.oldest_ms, &1.tenant})
      |> Enum.take(@top_tenants)

    oldest_row =
      case oldest do
        nil -> nil
        row -> %{tenant: row.tenant, route: row.route, age_ms: row.oldest_ms}
      end

    %{
      tracked_tenants: map_size(state.tenants),
      in_use: state.global_in_use,
      cap: state.global_cap,
      reserved_headroom: state.reserved_headroom,
      pool_size: state.pool_size,
      rejections: state.rejections,
      tenants: per_tenant,
      oldest: oldest_row
    }
  end

  defp older(nil, row), do: row
  defp older(current, row) when row.oldest_ms > current.oldest_ms, do: row
  defp older(current, _row), do: current

  # The stale sweep: every admission held longer than the bound is logged ONCE
  # (the `stale_logged?` flag makes the second sweep skip it) and stays held.
  defp sweep_stale(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.refs, {state, []}, fn {id, {pool, _generation, meta}}, {state, logged} ->
      age = now - meta.at

      if meta.stale_logged? or age <= state.max_in_flight_age_ms do
        {state, logged}
      else
        tenant =
          case pool do
            {:tenant, schema} -> schema
            :global -> nil
          end

        new_meta = %{meta | stale_logged?: true}
        refs = Map.put(state.refs, id, put_meta(state.refs[id], new_meta))

        entry = %{
          tenant: tenant,
          route: meta.class,
          age_ms: age,
          in_use: state.global_in_use,
          cap: state.global_cap
        }

        {%{state | refs: refs}, [entry | logged]}
      end
    end)
    |> then(fn {state, logged} ->
      Enum.each(logged, &log_stale/1)
      state
    end)
  end

  defp put_meta({pool, generation, _meta}, meta), do: {pool, generation, meta}

  # The stale line is emitted through Letflow.Admission.Observability (which
  # hashes the tenant schema name). A failure there must never take the
  # admission process down, so it is swallowed here.
  defp log_stale(entry) do
    Letflow.Admission.Observability.log_stale(entry)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp per_tenant_cap(%{global_cap: global_cap, tenants: tenants}) do
    max(div(global_cap, map_size(tenants)), 1)
  end

  defp release_tenant(tenants, :global, _captured_generation), do: tenants

  defp release_tenant(tenants, {:tenant, schema}, captured_generation) do
    case Map.fetch(tenants, schema) do
      {:ok, %{generation: ^captured_generation} = entry} ->
        Map.put(tenants, schema, %{entry | in_use: entry.in_use - 1})

      _absent_or_stale_generation ->
        tenants
    end
  end
end
