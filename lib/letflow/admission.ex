defmodule Letflow.Admission do
  @moduledoc """
  Admission-control core (REQ-216, closes ISS-0431 part 1) — a hand-rolled,
  pure-BEAM `GenServer` implementing a global counting semaphore composed
  with per-tenant counting semaphores, all drawing against the SAME global
  budget. See `lib/letflow/design/req216-admission-control-core.md` for the
  full design rationale; this moduledoc restates only what a caller or a
  future maintainer needs.

  This module is CORE ONLY: no HTTP or Poller-specific vocabulary appears
  anywhere here, and no plug/route wiring exists yet (REQ-217/REQ-218).

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
  DIFFERENT scenario: by default this module does not monitor callers,
  unlike `Letflow.SandboxPool`'s owner-monitor mechanism — a leaked ref stays
  counted against its budget until this process itself restarts or the ref is
  explicitly released.

  ## Opt-in caller monitoring (GH 2534, decision 0053 D8)

  `start_link(monitor_callers: true)` makes every successful `try_acquire/2`
  monitor the acquiring pid; that pid's `:DOWN` releases its slot (and
  `release/2` demonitors), the same shape as
  `Letflow.Engine.Wasm.InvocationLease`. Used by the tenant-script admission
  server `Letflow.Engine.Lua.ScriptAdmission`, whose slot holder is the per-run
  watchdog: a killed watchdog (and so a dead dispatcher) can never leak a slot.
  The HTTP admission keeps the default (`false`), unchanged.

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

  # Client API

  @doc """
  Starts the admission-control server. `opts` accepts `:name` (default
  `__MODULE__`), `:monitor_callers` (default `false`; see "Opt-in caller
  monitoring"), and `:pool_size`/`:reserved_headroom` overrides for test
  isolation (mirrors `Letflow.SandboxPool.start_link/1`'s
  `Keyword.get_lazy/3` idiom). Absent overrides fall back to
  `Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size]` and
  `Application.get_env(:letflow, :admission, [])[:reserved_headroom]`
  (default #{@default_reserved_headroom}).
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

    GenServer.start_link(
      __MODULE__,
      %{
        pool_size: pool_size,
        reserved_headroom: reserved_headroom,
        monitor_callers: Keyword.get(opts, :monitor_callers, false)
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
  """
  @spec try_acquire(pool_selector(), server :: GenServer.server()) ::
          {:ok, admission_ref()} | {:error, :capacity}
  def try_acquire(pool, server \\ __MODULE__)

  def try_acquire(:global, server) do
    GenServer.call(server, {:try_acquire, :global})
  end

  def try_acquire({:tenant, schema} = pool, server) when is_binary(schema) do
    GenServer.call(server, {:try_acquire, pool})
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

  # GenServer callbacks

  # State shape (design doc §2.2; reserved_headroom added per
  # lib/letflow/design/iss0421-poller-bounded-concurrency.md §3b/§7;
  # generation/eviction fields added per
  # lib/letflow/design/iss0437-admission-tenant-eviction.md §2.1/§5(a)):
  #
  #   %{
  #     global_cap:         pos_integer(),               # fixed at init/1, from config
  #     global_in_use:      non_neg_integer(),
  #     tenants:            %{optional(String.t()) => %{in_use: non_neg_integer(), generation: non_neg_integer()}},
  #     refs:               %{optional(reference()) => {pool_selector(), non_neg_integer() | nil}},
  #     reserved_headroom:  pos_integer(),                 # fixed at init/1, same source as global_cap
  #     tenant_generations: %{optional(String.t()) => non_neg_integer()}  # never deleted, only incremented (forget_tenant/2)
  #   }
  @impl true
  def init(%{pool_size: pool_size, reserved_headroom: reserved_headroom} = args) do
    global_cap = max(pool_size - reserved_headroom, 1)

    {:ok,
     %{
       global_cap: global_cap,
       global_in_use: 0,
       tenants: %{},
       refs: %{},
       reserved_headroom: reserved_headroom,
       tenant_generations: %{},
       # GH 2534 / decision 0053 D8: opt-in caller monitoring. When true, every
       # acquire monitors the acquiring pid and its :DOWN releases the slot, so a
       # killed holder cannot leak budget. `monitors` maps monitor ref -> admission
       # id, `ref_monitors` the reverse. Default false: the HTTP admission is unchanged.
       monitor_callers: Map.get(args, :monitor_callers, false),
       monitors: %{},
       ref_monitors: %{}
     }}
  end

  @impl true
  def handle_call({:try_acquire, :global}, from, state) do
    if state.global_in_use < state.global_cap do
      id = make_ref()
      ref = %Ref{id: id, pool: :global}

      new_state = %{
        state
        | global_in_use: state.global_in_use + 1,
          refs: Map.put(state.refs, id, {:global, nil})
      }

      {:reply, {:ok, ref}, maybe_monitor(new_state, from, id)}
    else
      {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call({:try_acquire, {:tenant, schema} = pool}, from, state) do
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
          refs: Map.put(state.refs, id, {pool, tenant_entry.generation})
      }

      {:reply, {:ok, ref}, maybe_monitor(new_state, from, id)}
    else
      {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call(:reserved_headroom, _from, state) do
    {:reply, state.reserved_headroom, state}
  end

  def handle_call(:global_cap, _from, state) do
    {:reply, state.global_cap, state}
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

      {{stored_pool, captured_generation}, refs} ->
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
