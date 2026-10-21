defmodule Letflow.Support.BpmDefaultRealmDisplacement do
  @moduledoc """
  REQ-370 rework (TEST-RUNNER report `test/reports/report-20260918-WF02REQ370-20260918.yaml`,
  group A): `priv/repo/migrations/20260918173137_seed_default_tenant.exs` now
  permanently binds exactly one tenant to `idp_realm_id: "bpm-default"` in every
  migrated database (`tenants_idp_realm_id_partial_index` enforces at most one row per
  `idp_realm_id`, REQ-019). Several pre-existing test files need EXCLUSIVE, test-owned
  control of that binding for one test's duration — a fresh, empty schema they alone
  write to (`test/letflow/plugs/auth_pipeline_test.exs`'s AC1 tests,
  `test/letflow/plugs/api_pipeline_integration_test.exs`'s AC2/AC4/AC5 tests,
  `test/letflow/routers/req077_promotion_pipeline_test.exs`'s design §12.9 smoke test),
  or, for one case (`auth_pipeline_test.exs`'s AC4 "tenant resolution fails" test), no
  binding at all. `test/letflow/identity_test.exs`'s
  `resolve_tenant_by_realm/1`/`resolve_realm_by_tenant/1` tests only need a
  consistent READ of whichever tenant currently holds the binding.

  `displace!/0` deletes whatever tenant currently holds the `"bpm-default"` binding
  (normally the migration-seeded row) and registers an `on_exit/1` that re-inserts a
  row with the SAME `slug`/`display_name`/`idp_realm_id`, so every later test still
  finds the permanently-seeded tenant it expects.

  ## Self-healing repair (ISS-0766 — REQUIRED, do not remove)

  The migration-seeded `"bpm-default"` row is a singleton — `mix ecto.migrate` never
  re-inserts it once the seed migration is recorded as applied. This project's test
  databases (`letflow_test#{N}`) are long-lived and reused across many unrelated
  `mix test`/`scripts/test_parallel.sh` invocations, so if the OS process running a
  `displace!/0` caller is ever killed abnormally (SIGKILL, OOM-kill, CI
  timeout/cancellation) between its `Repo.delete!` and its `on_exit`-deferred
  restoration, the row is gone from that physical database PERMANENTLY — and every
  later `displace!/0`/`with_lock/1` call against that same database would otherwise
  observe `nil` forever, with no re-seeding path (confirmed via live reproduction:
  killing a `scripts/test_parallel.sh` run mid-flight left `letflow_test1` with zero
  rows bound to `"bpm-default"`, reproducing `test/letflow/identity_test.exs`'s
  REQ-019 AC1 failures deterministically on every subsequent run). Both `displace!/0`
  and `with_lock/1` therefore call `ensure_seeded!/1` first, under the advisory lock,
  which idempotently re-inserts the row
  (`INSERT ... ON CONFLICT (slug) DO NOTHING`, the exact shape
  `priv/repo/migrations/20260918173137_seed_default_tenant.exs` uses) on the SAME
  dedicated connection that holds the lock — so a genuinely-fresh/never-seeded
  database and a previously-corrupted one are repaired identically, and no
  lost-update race between two repairing callers is possible (the advisory lock
  already serializes them).

  ## Connection bound (GH #2656 — REQUIRED, do not remove)

  The dedicated lock connection sits outside Ecto's pool, so every caller that holds
  one adds a connection beyond `pool_size`. Before this bound, N callers that queued
  on the advisory lock in one BEAM held N such connections at once (12 contenders on a
  pool of 20 gave 32 open database sockets). `Letflow.Support.BpmDefaultRealmDisplacement.Gate`
  lets one caller per BEAM at a time acquire a lock connection: other callers wait in
  the BEAM holding no connection. The advisory lock still arbitrates across BEAMs. The
  regression test is test/support/bpm_default_realm_displacement_gate_test.exs.

  ## Mutual exclusion (REQUIRED — do not remove)

  **Two escalating bugs fixed while building this, both reproduced live, neither
  merely suspected:**

  1. First cut assumed `async: false` alone gave full mutual exclusion against every
     other test in the suite — it does not (only against other `async: false`
     modules, and even that boundary is not the whole story once other genuinely
     concurrent processes are touching the same database).
  2. Second cut used a plain BEAM-process `Agent` as a mutex — this correctly
     serializes every test PROCESS within one `mix test` VM, but this project
     routinely has **multiple separate `mix test`/`scripts/test_parallel.sh`
     invocations running as distinct OS processes against the same shared,
     non-partitioned default test database** (confirmed live via
     `SELECT application_name, count(*) FROM pg_stat_activity GROUP BY
     application_name`, which showed two distinct `letflow_mixtest_*` connections
     simultaneously while diagnosing this). An `Agent` is per-VM state — it cannot
     serialize across OS processes at all, so this still raced.

  The actual fix: a real Postgres session-scoped advisory lock
  (`pg_advisory_lock`/`pg_advisory_unlock`), held on a **dedicated `Postgrex`
  connection opened outside Ecto's own pool** (`Postgrex.start_link/1`, config
  copied from `Letflow.Repo.config/0`) — deliberately NOT `Repo.query!/2`, since
  Ecto's pool checks out a (potentially different) physical connection per call, and
  advisory locks are tied to the specific session/connection that acquired them: a
  release attempted from a different connection than the one that acquired the lock
  silently does nothing, leaking the lock for the life of that connection. Owning one
  dedicated connection end to end (acquire on it, release on that exact same one)
  sidesteps that hazard entirely, and — being a real Postgres lock, not BEAM state —
  correctly serializes across any number of concurrently-running `mix test` OS
  processes sharing the same database, which is the actual scope this problem needs
  covering at.

  Switches `Ecto.Adapters.SQL.Sandbox` to global `:auto` mode itself (idempotent to
  call again if the caller already has) — the migration-seeded row is real, committed
  Postgres state, invisible to/unreachable from a normal sandboxed transaction.
  """

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Support.BpmDefaultRealmDisplacement.Gate

  # A fixed, arbitrary 63-bit-safe integer -- pg_advisory_lock's key, scoped to this
  # one purpose only (any other advisory-lock use elsewhere in this codebase must
  # pick its own distinct key to avoid an unrelated collision).
  @lock_key 847_331_009

  # 2026-10-06 (second occurrence of the same CI flake: main CI 206338d3
  # `bpm_default_realm_displacement_test.exs:141`, PR #2313 run 37490851195
  # `req077_promotion_pipeline_test.exs:1279` -- both `DBConnection.ConnectionError:
  # connection not available and request was dropped from queue after 4000ms` out of
  # `acquire_dedicated_lock!/0`). Root cause: the dedicated Postgrex connection is a
  # brand-new DBConnection pool of ONE whose physical connect is ASYNCHRONOUS, so the
  # first `Postgrex.query!/3` queues while it connects. With no explicit queue options
  # it inherits DBConnection's overload-SHEDDING defaults (`:queue_target` 50 ms,
  # `:queue_interval` 2000 ms): if the queue wait exceeds `:queue_target` for a whole
  # `:queue_interval`, queued requests are dropped. That is meant for a shared,
  # saturated pool and is wrong for a private pool of one -- on a CPU-starved CI runner
  # (several `mix test` partitions) a connect slower than ~4 s (DBConnection sheds on the
  # second `:queue_interval` poll that still sees the same queued request) is shed with
  # exactly the message above. Secondary latent flake: `pg_advisory_lock` legitimately BLOCKS while
  # another process on the same database holds the lock, and Postgrex's default query
  # timeout is 15 s. Hence: push the queue options far out (never shed), give the
  # connect/handshake a generous bound, and pass one explicit `:timeout` to every
  # query issued on the dedicated connection. The regression test is
  # test/support/bpm_default_realm_displacement_connect_test.exs.
  @queue_window_ms 30_000
  @connect_timeout_ms 30_000
  @query_timeout_ms 120_000

  @doc """
  Removes whatever tenant currently holds the `"bpm-default"` `idp_realm_id` binding
  (a no-op if none does), and schedules its restoration via `ExUnit.Callbacks.on_exit/1`
  — the lock acquired here is held on its own dedicated connection until that
  restoration completes, then released and that connection closed, as the very last
  step. Must be called from within a running ExUnit test process.
  """
  @spec displace!() :: :ok
  def displace! do
    lock_conn = acquire_dedicated_lock!()

    # Until on_exit/1 is registered below, nothing else releases the lock; a failure
    # here must release it (and the gate) itself, or every later caller in this BEAM
    # would wait forever.
    existing =
      try do
        Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
        ensure_seeded!(lock_conn)
        Repo.get_by(Tenant, idp_realm_id: "bpm-default")
      catch
        kind, reason ->
          release_dedicated_lock!(lock_conn)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case existing do
      nil ->
        # ISS-0766: ensure_seeded!/1 above just guaranteed this row exists (inserting
        # it if a prior caller's interrupted on_exit permanently lost it, a no-op
        # otherwise) -- reaching `nil` here would mean that repair itself silently
        # failed, so this is kept only as a defensive branch, never expected to run.
        ExUnit.Callbacks.on_exit(fn -> release_dedicated_lock!(lock_conn) end)
        :ok

      %Tenant{} = existing ->
        restore_attrs = %{
          slug: existing.slug,
          display_name: existing.display_name,
          idp_realm_id: existing.idp_realm_id
        }

        ExUnit.Callbacks.on_exit(fn ->
          Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

          %Tenant{}
          |> Tenant.create_changeset(restore_attrs, :enabled)
          |> Repo.insert!()

          release_dedicated_lock!(lock_conn)
        end)

        Repo.delete!(existing)
        :ok
    end
  end

  @doc """
  Runs `fun` (typically a read of whichever tenant currently holds the `"bpm-default"`
  binding) while holding the same advisory lock `displace!/0` uses, on its own
  dedicated connection released immediately after — for a caller that only needs a
  consistent snapshot, not exclusive ownership for a whole test's duration.
  """
  @spec with_lock((-> result)) :: result when result: term()
  def with_lock(fun) when is_function(fun, 0) do
    lock_conn = acquire_dedicated_lock!()

    try do
      # ISS-0766: repair before reading -- a caller here (e.g.
      # test/letflow/identity_test.exs's `insert_default_tenant!/0`) only ever reads
      # the binding, so it would otherwise inherit a permanently-corrupted database
      # forever with no way to self-heal on its own.
      ensure_seeded!(lock_conn)
      fun.()
    after
      release_dedicated_lock!(lock_conn)
    end
  end

  # ISS-0766: idempotently re-inserts the migration-seeded "bpm-default" tenant row
  # if (and only if) it is currently missing -- reusing the exact
  # `INSERT ... ON CONFLICT (slug) DO NOTHING` shape
  # `priv/repo/migrations/20260918173137_seed_default_tenant.exs` uses, executed on
  # `lock_conn` (the same dedicated connection already holding the advisory lock)
  # rather than through `Repo`, so it commits immediately regardless of `Repo`'s
  # current sandbox mode and needs no coordination with the caller's own Ecto
  # transaction/connection.
  defp ensure_seeded!(lock_conn) do
    Postgrex.query!(
      lock_conn,
      """
      INSERT INTO tenants (id, slug, display_name, status, idp_realm_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'bpm-default', 'Default Tenant', 'active', 'bpm-default', NOW(), NOW())
      ON CONFLICT (slug) DO NOTHING
      """,
      [],
      timeout: @query_timeout_ms
    )

    :ok
  end

  @doc false
  # Exposed (not part of the public API) so the regression test exercises the REAL
  # production options rather than a copy. See the 2026-10-06 note at `@lock_key`.
  #
  # Repo.config/0 includes :pool (config/test.exs's Ecto.Adapters.SQL.Sandbox, this
  # repo's own sandbox pool adapter) and :pool_size -- neither is a valid Postgrex
  # pool option (Postgrex.start_link/1 raises UndefinedFunctionError against
  # Ecto.Adapters.SQL.Sandbox.child_spec/1 if passed through unchanged, confirmed
  # empirically). Dropped here so this dedicated connection is a genuinely separate,
  # unpooled Postgrex connection outside Ecto's own pool machinery entirely.
  @spec dedicated_connection_opts() :: keyword()
  def dedicated_connection_opts do
    Repo.config()
    |> Keyword.drop([:pool, :pool_size])
    |> Keyword.merge(
      queue_target: @queue_window_ms,
      queue_interval: @queue_window_ms,
      connect_timeout: @connect_timeout_ms,
      timeout: @query_timeout_ms
    )
  end

  # GH #2656: the gate is taken BEFORE the connection is opened, so a caller waiting
  # for its turn in this BEAM holds no connection. release_dedicated_lock!/1 gives it back.
  defp acquire_dedicated_lock! do
    Gate.start()
    :ok = Gate.acquire()

    try do
      open_dedicated_lock!()
    catch
      kind, reason ->
        Gate.release()
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp open_dedicated_lock! do
    opts = dedicated_connection_opts()
    {:ok, lock_conn} = Postgrex.start_link(opts)
    # Postgrex.start_link/1 is a plain GenServer.start_link/3, linked to the calling
    # process by default. displace!/0's release runs inside an ExUnit.Callbacks.on_exit/1
    # callback, which executes in a SEPARATE process AFTER the original test process has
    # already exited -- so a still-linked lock_conn dies along with that test process
    # (default link propagation) before release_dedicated_lock!/1 ever gets to use it,
    # producing a live "no process"/DBConnection.Holder.checkout crash in the on_exit
    # callback (reproduced for real in CI, 10 failures across every caller of
    # displace!/0 -- auth_pipeline_test.exs/api_pipeline_integration_test.exs/
    # req077_promotion_pipeline_test.exs). Unlinking here decouples lock_conn's lifecycle
    # from whichever process happens to be calling acquire_dedicated_lock! at the time,
    # which is required for a connection meant to outlive the current process until an
    # on_exit callback releases it.
    Process.unlink(lock_conn)

    Postgrex.query!(lock_conn, "SELECT pg_advisory_lock($1)", [@lock_key],
      timeout: @query_timeout_ms
    )

    lock_conn
  end

  defp release_dedicated_lock!(lock_conn) do
    try do
      Postgrex.query!(lock_conn, "SELECT pg_advisory_unlock($1)", [@lock_key],
        timeout: @query_timeout_ms
      )

      GenServer.stop(lock_conn)
    after
      Gate.release()
    end
  end
end

defmodule Letflow.Support.BpmDefaultRealmDisplacement.Gate do
  @moduledoc """
  In-BEAM queue that lets one caller of `BpmDefaultRealmDisplacement` hold a dedicated
  lock connection at a time (GH #2656). It is a plain GenServer, started unlinked and
  named, so it outlives the test process that first used it. The waiting callers
  block inside `acquire/0` and hold no connection.

  There is no ownership check: `displace!/0` releases from its `on_exit/1` callback,
  which runs in a different process than the one that acquired the gate. Waiting
  is unbounded (`:infinity`), because a caller that times out here would leave a
  stale entry in the queue; the advisory lock it waits for had the same unbounded
  wait before this gate existed.
  """

  use GenServer

  @spec start() :: :ok
  def start do
    case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @spec acquire() :: :ok
  def acquire, do: GenServer.call(__MODULE__, :acquire, :infinity)

  @spec release() :: :ok
  def release, do: GenServer.call(__MODULE__, :release, :infinity)

  @impl true
  def init(:ok), do: {:ok, %{held?: false, waiters: :queue.new()}}

  @impl true
  def handle_call(:acquire, _from, %{held?: false} = state) do
    {:reply, :ok, %{state | held?: true}}
  end

  def handle_call(:acquire, from, state) do
    {:noreply, %{state | waiters: :queue.in(from, state.waiters)}}
  end

  def handle_call(:release, _from, state) do
    case :queue.out(state.waiters) do
      {{:value, next}, rest} ->
        GenServer.reply(next, :ok)
        {:reply, :ok, %{state | waiters: rest}}

      {:empty, _} ->
        {:reply, :ok, %{state | held?: false}}
    end
  end
end
