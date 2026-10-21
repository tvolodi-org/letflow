defmodule Letflow.Scheduler do
  @moduledoc """
  Context module for the `timers` table's SCH-01/02/05/06 lifecycle:
  `create/2` (arming) and the poll-and-fire machinery. See
  `lib/letflow/design/req186-scheduler-core.md` for the full design this
  module implements, and
  `lib/letflow/design/req185-scheduler-firing-architecture.md` for the
  architecture it is bound by (supervised `GenServer` ticker, no Oban,
  `FOR UPDATE SKIP LOCKED` claim, no startup-sweep lock, per-tenant-schema
  iteration, per-timer transaction isolation, exhausted timer →
  `dlq_entries` with `entry_type: "timer"`). Plain Ecto context module, no
  process — same shape as `Letflow.Dlq`/`Letflow.Tasks`.
  `Letflow.Scheduler.Poller` (a separate module) calls into this one; this
  module itself starts no processes and owns no state.

  ## Isolation mechanism (design §0, resolving REQ-185 §3's one open item)

  Each claimed timer fires inside its own `Repo.transaction/1`; a raise
  inside that function is caught by an explicit `try/rescue` before the
  transaction function returns, converting it to an `{:error, _}` tuple so
  `Repo.transaction/1`'s own rollback-on-`{:error, _}` contract applies —
  no process boundary is introduced (no new `Task.Supervisor`).

  ## `TIMER_FIRED`'s `actor_id` — flagged deviation from the design's literal text

  Design §2.4 step 5 / §6 states `actor_id: nil` for the `TIMER_FIRED`
  event append, reasoning that "no human/API actor initiates a timer
  firing." `Letflow.EventStore.append/2` itself, however, requires
  `attrs[:actor_id]` to cast via `Ecto.UUID.cast/1` (its own `fetch_uuid/3`
  helper returns `{:error, :missing_actor_id}` for `nil` — verified
  directly in `event_store.ex`) — a literal `nil` here would make every
  `fire_timer/2` call return `{:error, :missing_actor_id}` and never fire
  a single timer. `Letflow.EventStore.platform_actor_id/0` is this
  codebase's own already-established sentinel for exactly this "no human
  actor" case (`Letflow.EventStore.PlatformEvents`'s own moduledoc, point
  4: "`:actor_id` from the producer's own `event_attrs[:actor_id]` when
  present, else `EventStore.platform_actor_id()`") — used here instead of
  `nil`, without otherwise changing anything the design decided. Flagged
  for SECURITY-REVIEWER/REVIEWER, not silently substituted.

  ## REQ-188 — recurring timers (SCH-07) and the periodic retention runner

  `maybe_rearm_timer/3` re-arms a fired recurring timer (a timer whose
  `repeat_expression` is non-`nil`) by inserting a new `"pending"` row in
  the SAME `Repo.transaction/1` `fire_timer/2` already opens, anchored to
  the fired timer's own scheduled `fire_at` plus `repeat_interval_us` (not
  the actual firing time, to avoid drift). `run_retention_sweep/1` wraps
  `Letflow.EventStore.archive/1` for `Letflow.Scheduler.Poller`'s periodic
  retention sweep. See
  `lib/letflow/design/req188-recurring-timers-and-retention.md` for the
  full design.

  Two things are deliberately OUT of scope for REQ-188, each because a
  prerequisite this codebase does not yet have is missing, not because it
  was overlooked:

  PROVENANCE (historical, not current decision authority):
  1. **R-Co's `src/scheduler/partition_maintenance.zig` and
     `partition_retention.zig` are NOT ported.** Both operate on a
     `PARTITION BY RANGE` events table via `DETACH`/`ATTACH`/`DROP`.
     Letflow's `events` table is not partitioned —
     `docs/migration/decisions/0003-ecto-schema-strategy.md`'s Dimension C
     deliberately defers partitioning, and `docs/issues/ISS-0014.yaml`
     already adjudicated this exact question: it adopted option (a) — port
     row-level `archive/1` as-is — and rejected option (c) — porting
     `PartitionRetention`'s whole-partition model now, "because it would
     force partitioning early, contradicting 0003 Decision C's deliberate
     deferral." This requirement schedules the `archive/1` that already
     exists; partition-based retention stays deferred pending a future
     partitioning decision record.
  2. **SCH-04 escalation timers are deferred.** SCH-04 requires a
     `:HUMAN_TASK` node carrying an `escalation_timer_duration` attribute.
     `lib/letflow/definitions/graph.ex`'s `check_timer_duration/1` (CHK-12)
     validates `duration_iso8601` on `:TIMER` nodes only; no
     `escalation_timer_duration` attribute exists on `:HUMAN_TASK` today.
     The definition-side input this escalation mechanism would consume does
     not exist yet, so escalation timers need a definitions-side
     requirement first.
  """

  import Ecto.Query
  require Logger

  alias Ecto.Multi
  alias Letflow.Dlq
  alias Letflow.Engine.Contention
  alias Letflow.Engine.TaskActivation
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantProvisioning

  @default_poll_interval_ms 5_000
  @default_jitter_ms 0
  @default_max_timers_per_cycle 64
  @default_contended_backoff_ms 30_000
  @default_max_fire_retries 3
  # REQ-188 §2.1 -- retention must never invoke `EventStore.archive/1` on
  # an unconfigured deployment; this default is load-bearing for INV-RETENTION-1.
  @default_retention_enabled false
  @default_retention_interval_ms 86_400_000
  @default_retention_days 90

  # REQ-376 §3.1 -- the ensure_future_partitions/2 pre-creation sweep.
  # Defaults to ENABLED (unlike retention_enabled?/0's false default) --
  # this sweep is non-destructive (create-if-missing partition metadata
  # only) and its entire purpose is AC5's safety property ("no write ever
  # waits on partition creation"), which only holds if it actually runs by
  # default. Daily cadence: partition creation is cheap and infrequent
  # relative to the poller's sub-minute tick.
  @default_partition_maintenance_enabled true
  @default_partition_maintenance_interval_ms 86_400_000
  # Per lib/letflow/design/iss0421-poller-bounded-concurrency.md §4a/§7 -- the
  # per-task budget for Letflow.Scheduler.Poller's Task.async_stream/3 calls.
  @default_sweep_task_timeout_ms 10_000

  # ===========================================================================
  # create/2 -- SCH-01 arming (design §2.1)
  # ===========================================================================

  @type arm_attrs :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:timer_type) => String.t(),
          required(:node_id) => String.t(),
          required(:fire_at) => DateTime.t(),
          optional(:token_id) => Ecto.UUID.t() | nil,
          optional(:repeat_expression) => String.t() | nil,
          optional(:repeat_interval_us) => non_neg_integer() | nil,
          optional(:repeat_total) => pos_integer() | nil,
          optional(:fired_count) => non_neg_integer() | nil
        }

  @doc """
  Arms a new timer (design §2.1). Accepts either a caller-supplied
  `Ecto.Multi.t()` — appends one named `Ecto.Multi.insert/4` step and
  returns the extended `Multi.t()` **unexecuted** (this function never
  calls `Repo.transaction/1` and never touches `Repo` directly in this
  branch) — or a bare repo (`Letflow.Repo`), for a caller with no existing
  `Multi`, wrapping the same changeset in `Repo.insert/2` directly.

  `tenant_id` is derived from `opts[:prefix]`, never accepted from `attrs`.
  `id` is generated internally (`Ecto.UUID.generate/0`). `created_at` is
  set internally to the current UTC wall clock, microsecond-truncated.
  `status` is always forced to `"pending"`.
  """
  @spec create(
          multi_or_repo :: Ecto.Multi.t() | Ecto.Repo.t(),
          arm_attrs(),
          opts :: [prefix: String.t()]
        ) :: Ecto.Multi.t() | {:ok, Timer.t()} | {:error, Ecto.Changeset.t()}
  def create(%Multi{} = multi, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    # REQ-396: callers that arm escalation timers supply step_name: to avoid
    # colliding with the default :scheduler_timer step used for deadline timers.
    step_name = Keyword.get(opts, :step_name, :scheduler_timer)
    changeset = build_arm_changeset(attrs, prefix)

    Multi.insert(multi, step_name, changeset, prefix: prefix)
  end

  def create(Repo, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    changeset = build_arm_changeset(attrs, prefix)

    Repo.insert(changeset, prefix: prefix)
  end

  defp build_arm_changeset(attrs, prefix) do
    {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(prefix)

    insert_attrs =
      attrs
      |> Map.take([
        :instance_id,
        :token_id,
        :timer_type,
        :node_id,
        :fire_at,
        :repeat_expression,
        :repeat_interval_us,
        :repeat_total,
        :fired_count
      ])
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        status: "pending",
        created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    Timer.arm_changeset(%Timer{}, insert_attrs)
  end

  # ===========================================================================
  # poll_and_fire/1 -- the tick entry point (design §2.2)
  # ===========================================================================

  @type poll_result :: %{
          tenant_schema: String.t(),
          claimed: non_neg_integer(),
          fired: non_neg_integer(),
          errored: non_neg_integer(),
          exhausted: non_neg_integer(),
          contended: non_neg_integer()
        }

  # GH #2707 (PR-3): the poll cycle starts no new fire once this much monotonic time has passed
  # (half the 10 s per-tenant sweep task budget, which leaves room for one in-flight fire whose
  # several lock waits are each bounded by the fire lock timeout). Deliberately a FIXED 5 s, not
  # derived from `sweep_task_timeout_ms/0`: the sweep's `:kill_task` rollback is the accepted
  # backstop (the killed fire's transaction aborts whole, the timer stays pending, nothing is
  # counted). A `:engine_test_seams` build lets a test replace it through the process dictionary
  # key `:timer_cycle_budget_ms_override` (a non-negative integer) of the calling process.
  @default_cycle_budget_ms 5_000

  @doc false
  @spec default_cycle_budget_ms() :: pos_integer()
  def default_cycle_budget_ms, do: @default_cycle_budget_ms

  if Application.compile_env(:letflow, :engine_test_seams, false) do
    defp cycle_budget_ms do
      case Process.get(:timer_cycle_budget_ms_override) do
        ms when is_integer(ms) and ms >= 0 -> ms
        _ -> @default_cycle_budget_ms
      end
    end
  else
    defp cycle_budget_ms, do: @default_cycle_budget_ms
  end

  @doc """
  Called once per tenant schema per tick by `Letflow.Scheduler.Poller`
  (design §3), never by application code directly. Never raises — every
  per-timer failure is caught internally and folded into the returned
  counts (design §2.2, §2.5).

  GH #2707 (PR-3): a fire that hit a lock timeout (`55P03`) is `contended`, not `errored`: no failure
  is counted, the timer stays `pending` and fires on a later poll, after the contended backoff
  (GH #2864: its `fire_at`, and that of its instance's other due timers, is pushed back by
  `contended_backoff_ms/0` so it does not hold a claim slot every cycle). The first contended timer of an
  instance leaves that instance's remaining timers of this cycle untouched, and no new fire starts
  once the cycle has run for 5 s (the first fire always starts). Each contended timer emits
  `[:letflow, :scheduler, :timer_contended]` (count 1; metadata `tenant_schema`, `timer_type`,
  `code`, `postponed`, `backoff_ms`) and a warning log carrying the classified code only.
  """
  @spec poll_and_fire(tenant_schema :: String.t()) :: poll_result()
  def poll_and_fire(tenant_schema) when is_binary(tenant_schema) do
    timer_ids = claim_due_timer_ids(tenant_schema, max_timers_per_cycle())
    started_at = System.monotonic_time(:millisecond)
    budget_ms = cycle_budget_ms()

    initial = %{
      tenant_schema: tenant_schema,
      claimed: length(timer_ids),
      fired: 0,
      errored: 0,
      exhausted: 0,
      contended: 0
    }

    {result, _attempted, _skip} =
      Enum.reduce_while(timer_ids, {initial, 0, MapSet.new()}, fn timer_id,
                                                                  {acc, attempted, skip} ->
        cond do
          attempted > 0 and System.monotonic_time(:millisecond) - started_at >= budget_ms ->
            {:halt, {acc, attempted, skip}}

          MapSet.size(skip) > 0 and skipped_instance?(timer_id, tenant_schema, skip) ->
            {:cont, {acc, attempted, skip}}

          true ->
            {acc, skip} = tally_fire(attempt_fire(timer_id, tenant_schema), timer_id, acc, skip)
            {:cont, {acc, attempted + 1, skip}}
        end
      end)

    result
  end

  defp tally_fire(:fired, _timer_id, acc, skip), do: {%{acc | fired: acc.fired + 1}, skip}
  defp tally_fire(:already_final, _timer_id, acc, skip), do: {acc, skip}
  defp tally_fire(:errored, _timer_id, acc, skip), do: {%{acc | errored: acc.errored + 1}, skip}

  defp tally_fire(:exhausted, _timer_id, acc, skip),
    do: {%{acc | exhausted: acc.exhausted + 1}, skip}

  defp tally_fire(:contended, timer_id, acc, skip) do
    timer = safe_peek_timer(timer_id, acc.tenant_schema)
    postponed = postpone_contended(timer, acc.tenant_schema)
    announce_contended(acc.tenant_schema, timer, postponed)

    skip =
      case timer do
        %Timer{instance_id: instance_id} -> MapSet.put(skip, instance_id)
        nil -> skip
      end

    {%{acc | contended: acc.contended + 1}, skip}
  end

  defp skipped_instance?(timer_id, tenant_schema, skip) do
    case safe_peek_timer(timer_id, tenant_schema) do
      %Timer{instance_id: instance_id} -> MapSet.member?(skip, instance_id)
      nil -> false
    end
  end

  # poll_and_fire/1 never raises: a failed peek only loses the skip / the timer type.
  defp safe_peek_timer(timer_id, tenant_schema) do
    inject_peek_failure()
    peek_timer(timer_id, tenant_schema)
  rescue
    exception ->
      Logger.debug("scheduler: timer peek failed (#{inspect(exception.__struct__)})",
        schema: tenant_schema
      )

      nil
  end

  # `:engine_test_seams` builds only: a truthy process dictionary key `:timer_peek_failure`
  # makes the post-fire peek raise, so a test reaches the rescue above deterministically.
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    defp inject_peek_failure do
      if Process.get(:timer_peek_failure), do: raise("injected timer peek failure")
      :ok
    end
  else
    defp inject_peek_failure, do: :ok
  end

  # GH #2864: pushes `fire_at` of every due pending timer of the contended instance back by
  # `contended_backoff_ms/0`, so a stuck timer holds a claim slot once per backoff interval, not
  # once per cycle. One statement in its own transaction, timers rows only, `SKIP LOCKED`: it
  # waits on no lock and takes no `P_x` (decision 0061, "Amended (GH #2864)"). Backoff 0 or an
  # unknown instance (failed peek) runs no statement. Never raises; returns the rows postponed.
  defp postpone_contended(%Timer{instance_id: instance_id}, tenant_schema) do
    backoff_ms = contended_backoff_ms()

    if backoff_ms > 0 do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      later = DateTime.add(now, backoff_ms, :millisecond)

      due_ids =
        from(t in Timer,
          where: t.instance_id == ^instance_id and t.status == "pending" and t.fire_at <= ^now,
          select: t.id,
          lock: "FOR UPDATE SKIP LOCKED"
        )

      {count, _} =
        Repo.update_all(
          from(t in Timer, where: t.id in subquery(due_ids)),
          [set: [fire_at: later]],
          prefix: tenant_schema
        )

      count
    else
      0
    end
  rescue
    exception ->
      Logger.warning("scheduler: contended postpone failed (#{inspect(exception.__struct__)})",
        schema: tenant_schema
      )

      0
  end

  defp postpone_contended(nil, _tenant_schema), do: 0

  defp announce_contended(tenant_schema, timer, postponed) do
    timer_type = if timer, do: timer.timer_type, else: nil

    :telemetry.execute(
      [:letflow, :scheduler, :timer_contended],
      %{count: 1},
      %{
        tenant_schema: tenant_schema,
        timer_type: timer_type,
        code: :lock_not_available,
        postponed: postponed,
        backoff_ms: contended_backoff_ms()
      }
    )

    Logger.warning(
      "scheduler: timer fire contended (lock_not_available), left pending",
      schema: tenant_schema,
      timer_type: timer_type,
      postponed: postponed
    )
  end

  # ===========================================================================
  # claim_due_timer_ids/2 -- design §2.3
  # ===========================================================================

  @spec claim_due_timer_ids(tenant_schema :: String.t(), limit :: pos_integer()) :: [
          Ecto.UUID.t()
        ]
  def claim_due_timer_ids(tenant_schema, limit)
      when is_binary(tenant_schema) and is_integer(limit) and limit > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      Timer
      |> where([t], t.status == "pending" and t.fire_at <= ^now)
      |> order_by([t], asc: t.fire_at)
      |> limit(^limit)
      |> select([t], t.id)
      |> lock("FOR UPDATE SKIP LOCKED")

    Repo.all(query, prefix: tenant_schema)
  rescue
    error in Postgrex.Error ->
      if match?(
           %Postgrex.Error{postgres: %{code: code}}
           when code in [:undefined_table, :undefined_schema],
           error
         ) do
        Logger.warning(
          "scheduler: tenant schema unavailable, skipping timer poll for this tick",
          schema: tenant_schema,
          reason: :schema_unavailable
        )

        []
      else
        reraise error, __STACKTRACE__
      end
  end

  # ===========================================================================
  # fire_timer/2 -- one timer, one transaction (design §2.4)
  # ===========================================================================

  @doc """
  Fires one timer in one transaction (GH #2707, decision 0061 "Amended (GH #2707, PR-1)"). The
  row locks are taken in the order of every other instance writer: the timer is PEEKED without a
  lock (its `instance_id`, `token_id`, `node_id` and `timer_type` never change), then
  `Letflow.Engine.lock_for_timer_fire/3` locks the pending tasks of an escalation's token, the
  instance projection and, for a child, the parent group (`FOR KEY SHARE` on the immediate parent,
  or `FOR UPDATE` on the ancestor chain when the fire completes the child and runs the sub-process
  completion cascade, decision 0061 "Amended (GH #2829)"), and only then is the timer row locked. A timer that is no longer pending returns `{:ok, :already_final}`.

  GH #2707 (PR-3): the transaction's first statement is one bound-parameter, transaction-local
  `lock_timeout` setting (`Letflow.Engine.Contention.timer_fire_lock_timeout_ms/0`,
  2 s by default) that bounds EACH lock wait of the fire, not their sum; it is skipped when the
  caller already holds a transaction (a NESTED caller therefore gets no per-wait bound from this
  function, and after `{:error, :contention}` the caller's outer transaction is aborted: the rescue
  here cannot repair it; no nested caller exists in `lib/` today). A lock timeout (55P03) rolls the fire back whole and returns
  `{:error, :contention}` (nothing committed, the timer stays `pending`); a deadlock victim (40P01)
  keeps raising.

  A timer whose instance is not `:active` (cancelled, completed or errored) is SETTLED: every
  pending timer of that instance is cancelled with reason `instance_<status>` in this same
  transaction, nothing is fired, no failure is counted and no DLQ row is written; the result is
  `{:ok, :already_final}` and a `[:letflow, :scheduler, :timers_settled]` telemetry event (and an
  info log) follows the commit. A timer whose instance has no projection row at all is still
  `{:error, :instance_not_found}` (a counted failure).

  Settling an `:error` instance's timers is IRREVERSIBLE: `:error` is not a terminal status but
  nothing resumes such an instance today, so its pending timers are cancelled for good (reason
  `instance_error`, kept greppable). A future resume / reconstruct feature must RE-ARM the
  timers of the node the instance resumes at.
  """
  @spec fire_timer(timer_id :: Ecto.UUID.t(), tenant_schema :: String.t()) ::
          {:ok, :fired} | {:ok, :already_final} | {:error, :contention} | {:error, term()}
  def fire_timer(timer_id, tenant_schema) when is_binary(tenant_schema) do
    nested? = Repo.in_transaction?()

    transaction_result =
      try do
        Repo.transaction(fn ->
          # GH #2707 (PR-3): the FIRST statement bounds EVERY lock wait of this fire (per wait, not
          # cumulatively); bound parameter, transaction-local, skipped when nested.
          {:ok, _} = Letflow.Engine.set_timer_fire_lock_timeout(Repo, nested?)

          case lock_and_fire(timer_id, tenant_schema) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      rescue
        exception ->
          # a lock timeout (55P03) rolled the whole fire back: nothing committed, timer pending.
          # A deadlock victim (40P01) and every other exception keep raising (a counted failure).
          case Contention.contention_code(exception) do
            {:ok, :lock_not_available} -> {:error, :contention}
            _other -> reraise exception, __STACKTRACE__
          end
      end

    case transaction_result do
      {:ok, {:settled, instance_id, reason, count}} ->
        announce_settled(tenant_schema, instance_id, reason, count)
        {:ok, :already_final}

      other ->
        other
    end
  end

  defp lock_and_fire(timer_id, tenant_schema) do
    case peek_timer(timer_id, tenant_schema) do
      nil ->
        {:ok, :already_final}

      %Timer{status: status} when status != "pending" ->
        {:ok, :already_final}

      %Timer{} = peeked ->
        with {:ok, projection} <- Letflow.Engine.lock_for_timer_fire(peeked, Repo, tenant_schema) do
          fire_locked_timer(timer_id, projection, tenant_schema)
        end
    end
  end

  defp fire_locked_timer(timer_id, %InstanceProjection{} = projection, tenant_schema) do
    case fetch_and_lock_timer(timer_id, tenant_schema) do
      nil ->
        {:ok, :already_final}

      %Timer{status: status} when status != "pending" ->
        {:ok, :already_final}

      %Timer{} = timer ->
        if projection.status == :active do
          do_fire(timer, tenant_schema)
        else
          settle_dead_instance(timer, projection.status, tenant_schema)
        end
    end
  end

  # The instance is dead: nothing can fire against it, and nothing else ever terminates its
  # pending timers (an `:error` landing does not; a completion or cancel racing a deploy may not).
  # Runs under the `P_x` lock taken by the prelude, which protects every timer row of the instance.
  defp settle_dead_instance(%Timer{} = timer, status, tenant_schema) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reason = "instance_" <> Atom.to_string(status)

    {:ok, count} =
      TaskActivation.cancel_pending_timers(
        Repo,
        timer.instance_id,
        now,
        reason,
        tenant_schema
      )

    {:ok, {:settled, timer.instance_id, reason, count}}
  end

  defp announce_settled(tenant_schema, instance_id, reason, count) do
    :telemetry.execute(
      [:letflow, :scheduler, :timers_settled],
      %{count: count},
      %{tenant_schema: tenant_schema, reason: reason}
    )

    Logger.info(
      "scheduler: settled #{count} pending timer(s) of a dead instance (#{reason}) " <>
        "instance_id=#{instance_id}",
      schema: tenant_schema
    )
  end

  defp peek_timer(timer_id, tenant_schema) do
    Timer
    |> where([t], t.id == ^timer_id)
    |> Repo.one(prefix: tenant_schema)
  end

  defp do_fire(%Timer{} = timer, tenant_schema) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fired_late = DateTime.compare(now, timer.fire_at) == :gt

    with {:ok, _updated} <-
           timer
           |> Timer.fire_changeset(%{status: "fired", fired_at: now})
           |> Repo.update(prefix: tenant_schema),
         {:ok, _append_result} <-
           append_timer_fired_event(timer, now, fired_late, tenant_schema),
         {:ok, fire_outcome} <- route_fire(timer, tenant_schema),
         # REQ-188 §1.2 -- the LAST step of this with chain, still inside
         # fire_timer/2's one transaction. `timer` here is the struct
         # captured BEFORE fire_changeset/2's update -- none of the
         # recurrence fields change on fire, so the pre-update struct is
         # equivalent and avoids a second read.
         {:ok, _rearm_result} <- rearm_unless_stale(fire_outcome, timer, now, tenant_schema) do
      {:ok, :fired}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # REQ-396: escalation timers route to advance_after_escalation_timer_fired/3
  # (cancel original task, create new task at escalation target).
  # REQ-494 design §3.1: reminder timers route to record_reminder_fired/3,
  # which never advances the instance (a stale one is a no-op, not an error).
  # All other timer types follow the existing advance_after_timer_fired/3 path.
  # For the two advancing branches only {:ok, :advanced} / {:error, _} are
  # accepted, exactly as before; any other {:ok, _} still raises.
  @spec route_fire(Timer.t(), tenant_schema :: String.t()) ::
          {:ok, :advanced | :reminded | :reminder_stale} | {:error, term()}
  defp route_fire(%Timer{} = timer, tenant_schema) do
    case timer.timer_type do
      "escalation" ->
        timer
        |> Letflow.Engine.advance_after_escalation_timer_fired(Repo, tenant_schema)
        |> advanced_outcome()

      "reminder" ->
        Letflow.Engine.record_reminder_fired(timer, Repo, tenant_schema)

      _ ->
        timer
        |> Letflow.Engine.advance_after_timer_fired(Repo, tenant_schema)
        |> advanced_outcome()
    end
  end

  defp advanced_outcome({:ok, :advanced}), do: {:ok, :advanced}
  defp advanced_outcome({:error, reason}), do: {:error, reason}

  # REQ-494 design §3.1 step 4: a stale reminder (its task is no longer
  # pending) must not re-arm a recurring successor.
  defp rearm_unless_stale(:reminder_stale, _timer, _now, _tenant_schema),
    do: {:ok, :not_rearmed_stale}

  defp rearm_unless_stale(_fire_outcome, timer, now, tenant_schema),
    do: maybe_rearm_timer(timer, now, tenant_schema)

  # ===========================================================================
  # resolve_advance_target/3 -- ISS-0389 design §3
  # ===========================================================================
  #
  # Resolves which `timers` row a `POST /instances/:id/advance-timer` request
  # targets, without ever locking or mutating it -- the caller (the router)
  # passes the resolved `timer.id` to `fire_timer/2` separately, which does
  # its own `FOR UPDATE` fetch inside its own transaction. This keeps the
  # router's INV-RT-1 boundary intact (it never issues a `Repo.*` call
  # itself) while leaving `fire_timer/2` untouched.
  @spec resolve_advance_target(
          instance_id :: Ecto.UUID.t(),
          timer_id :: Ecto.UUID.t() | nil,
          tenant_schema :: String.t()
        ) ::
          {:ok, Timer.t()}
          | {:error, :no_pending_timer}
          | {:error, :ambiguous_pending_timers}
  def resolve_advance_target(instance_id, nil, tenant_schema)
      when is_binary(instance_id) and is_binary(tenant_schema) do
    pending_timers =
      Timer
      |> where([t], t.status == "pending" and t.instance_id == ^instance_id)
      |> Repo.all(prefix: tenant_schema)

    case pending_timers do
      [] -> {:error, :no_pending_timer}
      [timer] -> {:ok, timer}
      [_ | _] -> {:error, :ambiguous_pending_timers}
    end
  end

  def resolve_advance_target(instance_id, timer_id, tenant_schema)
      when is_binary(instance_id) and is_binary(timer_id) and is_binary(tenant_schema) do
    Timer
    |> where([t], t.id == ^timer_id)
    |> Repo.one(prefix: tenant_schema)
    |> case do
      %Timer{status: "pending", instance_id: ^instance_id} = timer -> {:ok, timer}
      _not_found_or_not_pending_or_wrong_instance -> {:error, :no_pending_timer}
    end
  end

  defp append_timer_fired_event(%Timer{} = timer, now, fired_late, tenant_schema) do
    payload =
      Jason.encode!(%{
        timer_id: timer.id,
        node_id: timer.node_id,
        timer_type: timer.timer_type,
        fired_late: fired_late,
        scheduled_fire_at: DateTime.to_iso8601(timer.fire_at),
        actual_fired_at: DateTime.to_iso8601(now)
      })

    event_attrs = %{
      instance_id: timer.instance_id,
      event_type: "TIMER_FIRED",
      payload: payload,
      actor_id: EventStore.platform_actor_id(),
      idempotency_key: "timer_fired:#{timer.id}"
    }

    EventStore.append(event_attrs, prefix: tenant_schema)
  end

  defp fetch_and_lock_timer(timer_id, tenant_schema) do
    Timer
    |> where([t], t.id == ^timer_id)
    |> lock("FOR UPDATE")
    |> Repo.one(prefix: tenant_schema)
  end

  # ===========================================================================
  # maybe_rearm_timer/3 -- SCH-07 recurring timers (REQ-188 design §1.2)
  # ===========================================================================

  @doc """
  Re-arms a fired recurring timer (REQ-188 design §1.2). Called once, from
  inside `do_fire/2` (private, this module), as the LAST step of its
  existing `with` chain -- after `Letflow.Engine.advance_after_timer_fired/3`
  succeeds, before `do_fire/2` returns `{:ok, :fired}`. Never called
  anywhere else; never opens its own transaction -- it runs on the caller's
  `Repo`/`prefix`, inside the caller's already-open `Repo.transaction/1`
  function.

  `fired_timer` is the pre-fire struct (captured BEFORE `fire_changeset/2`'s
  update) -- none of the recurrence fields change on fire, so the pre-update
  struct is equivalent and avoids a second read. `fired_at` is accepted for
  signature symmetry with the design but is NOT used to compute the new
  row's `fire_at` -- see the drift-avoidance note below.

  Behavior:

    * `fired_timer.repeat_expression == nil` -> `{:ok, :not_recurring}`, no
      row inserted (the recurrence-shape CHECK constraint guarantees the
      rest of the quartet is also `nil` in this case).
    * `fired_timer.repeat_total != nil` and the next occurrence count
      (`fired_timer.fired_count + 1`) has reached it -> `{:ok,
      :series_complete}`, no row inserted -- the series has reached its cap.
    * Otherwise -> builds and inserts a new `"pending"` row (see
      `build_rearm_attrs/2`), returning `{:ok, :rearmed}` on success or
      `{:error, changeset}` on failure (which, per the caller's `with`
      short-circuit, rolls back the whole `fire_timer/2` transaction).

  **`fire_at` anchor -- nominal, not actual.** The new row's `fire_at` is
  `fired_timer.fire_at` (the timer's own SCHEDULED fire time) plus
  `repeat_interval_us`, never the actual firing timestamp. This is
  deliberate: anchoring to the nominal schedule prevents drift accumulation
  from poll latency. Exception (GH #2864): a timer that was contended has its
  `fire_at` postponed, and the postponed `fire_at` is then the anchor.
  """
  @spec maybe_rearm_timer(
          fired_timer :: Timer.t(),
          fired_at :: DateTime.t(),
          tenant_schema :: String.t()
        ) :: {:ok, :rearmed | :not_recurring | :series_complete} | {:error, Ecto.Changeset.t()}
  def maybe_rearm_timer(%Timer{repeat_expression: nil}, _fired_at, tenant_schema)
      when is_binary(tenant_schema) do
    {:ok, :not_recurring}
  end

  def maybe_rearm_timer(%Timer{} = fired_timer, _fired_at, tenant_schema)
      when is_binary(tenant_schema) do
    new_fired_count = fired_timer.fired_count + 1

    if fired_timer.repeat_total != nil and new_fired_count >= fired_timer.repeat_total do
      {:ok, :series_complete}
    else
      attrs = build_rearm_attrs(fired_timer, new_fired_count)

      %Timer{}
      |> Timer.rearm_changeset(attrs)
      |> Repo.insert(prefix: tenant_schema)
      |> case do
        {:ok, _new_timer} -> {:ok, :rearmed}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  # REQ-188 design §1.3 -- mirrors build_arm_changeset/2's pattern exactly.
  defp build_rearm_attrs(%Timer{} = fired_timer, new_fired_count) do
    %{
      id: Ecto.UUID.generate(),
      tenant_id: fired_timer.tenant_id,
      instance_id: fired_timer.instance_id,
      token_id: fired_timer.token_id,
      timer_type: fired_timer.timer_type,
      node_id: fired_timer.node_id,
      fire_at: DateTime.add(fired_timer.fire_at, fired_timer.repeat_interval_us, :microsecond),
      status: "pending",
      repeat_expression: fired_timer.repeat_expression,
      repeat_interval_us: fired_timer.repeat_interval_us,
      repeat_total: fired_timer.repeat_total,
      fired_count: new_fired_count,
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  # ===========================================================================
  # attempt_fire/2 -- failure accounting, ISS-303/ISS-0618 (design §2.5)
  # ===========================================================================

  @spec attempt_fire(timer_id :: Ecto.UUID.t(), tenant_schema :: String.t()) ::
          :fired | :already_final | :errored | :exhausted | :contended
  def attempt_fire(timer_id, tenant_schema) when is_binary(tenant_schema) do
    result =
      try do
        fire_timer(timer_id, tenant_schema)
      rescue
        exception -> {:error, {:raised, exception}}
      end

    case result do
      {:ok, :fired} ->
        :fired

      {:ok, :already_final} ->
        :already_final

      # REQ-187 design doc §7.2 -- a real SCH-03 race (the instance became
      # terminal via a concurrent cancel_instance/3/completion between this
      # timer's own claim and advance_after_timer_fired/3's own
      # instance_projections lock+check) is not a firing failure -- matched
      # BEFORE the generic {:error, _reason} catch-all below so it never
      # wrongly increments fire_error_count / eventually lands the timer in
      # dlq_entries.
      {:error, {:instance_not_active, _status}} ->
        :already_final

      # ISS-0784 follow-up fix -- a task-activation rejection
      # (`Letflow.Engine.TaskActivation.resolve_form_schema/1`'s
      # `{:invalid_form_schema, node_id, reason}`) surfaces here as
      # `fire_timer/2`'s own `{:error, reason}` return, AFTER its
      # `Repo.transaction/1` has already fully returned (and, since we're in
      # this branch, already rolled back). This is deliberately NOT handled
      # inside `Letflow.Engine.persist_timer_fired_advance/7`'s own inline
      # clause any more -- TEST-DESIGNER proved against real Postgres that
      # doing so there just wrote into `fire_timer/2`'s own still-open outer
      # transaction, and the audit row was rolled back right along with the
      # rest of the failed attempt. Recording it here, once `fire_timer/2`
      # has genuinely returned, is a real, independent write.
      {:error, {:invalid_form_schema, node_id, form_schema_reason}} ->
        maybe_audit_task_activation_rejection(
          timer_id,
          node_id,
          form_schema_reason,
          tenant_schema
        )

        safe_record_fire_failure(timer_id, tenant_schema)

      # GH #2707 (PR-3): a lock timeout (55P03) rolled the fire back whole; it is not a firing
      # failure (nothing counted, the timer stays pending and is retried on a later poll).
      # `fire_timer/2` classifies its own raise (every statement of the fire runs inside its
      # `try`), so a 55P03 never reaches the `rescue` above as `{:raised, _}`; that form is
      # deliberately not special-cased. A deadlock victim (40P01) falls through to the counted
      # failure below, so a deterministic deadlock still reaches the retry cap and the DLQ.
      {:error, :contention} ->
        :contended

      {:error, _reason} ->
        safe_record_fire_failure(timer_id, tenant_schema)
    end
  end

  # ISS-0784 follow-up fix -- re-fetches the timer (no lock; `fire_timer/2`'s
  # own locked read is long gone by the time this runs, its transaction
  # having already returned) purely to recover `instance_id`, the one piece
  # of context `fire_timer/2`'s `{:error, reason}` return does not carry.
  # Best-effort like the helper it calls: a `nil` timer (implausible --
  # `fire_timer/2` just proved this row existed a moment ago -- but not
  # impossible if it's since been deleted) is a no-op, not a crash.
  defp maybe_audit_task_activation_rejection(timer_id, node_id, form_schema_reason, tenant_schema) do
    case Repo.get(Timer, timer_id, prefix: tenant_schema) do
      nil ->
        :ok

      %Timer{instance_id: instance_id} ->
        Letflow.Engine.record_task_activation_rejection_audit(
          instance_id,
          node_id,
          form_schema_reason,
          EventStore.platform_actor_id(),
          tenant_schema
        )
    end
  end

  # Guards the separate failure-accounting transaction (design §2.5 step 3)
  # the same way attempt_fire/2's own outer try/rescue guards fire_timer/2:
  # a raise here (e.g. a constraint violation on the retry-increment update,
  # or Letflow.Dlq.enqueue/2 itself raising) must not propagate out of
  # poll_and_fire/1's per-tenant loop -- acceptance criterion 6's "remaining
  # due timers in the same poll cycle are still attempted" depends on this
  # function never raising, exactly as it depends on fire_timer/2 never
  # raising.
  defp safe_record_fire_failure(timer_id, tenant_schema) do
    record_fire_failure(timer_id, tenant_schema)
  rescue
    _exception -> :errored
  end

  defp record_fire_failure(timer_id, tenant_schema) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      case fetch_and_lock_timer(timer_id, tenant_schema) do
        nil ->
          :already_final

        %Timer{} = timer ->
          new_count = timer.fire_error_count + 1

          {:ok, updated_timer} =
            timer
            |> Timer.retry_increment_changeset(%{fire_error_count: new_count})
            |> Repo.update(prefix: tenant_schema)

          if new_count >= max_fire_retries() do
            land_exhausted_timer(updated_timer, now, tenant_schema)
            :exhausted
          else
            :errored
          end
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, _reason} -> :errored
    end
  end

  defp land_exhausted_timer(%Timer{} = timer, now, tenant_schema) do
    {:ok, _updated} =
      timer
      |> Timer.fail_changeset(%{status: "failed", failed_at: now})
      |> Repo.update(prefix: tenant_schema)

    dlq_attrs = %{
      entry_type: "timer",
      instance_id: timer.instance_id,
      reference_id: timer.id,
      reason: "Timer #{timer.node_id} exhausted #{max_fire_retries()} fire attempts",
      error_detail: %{
        "timer_id" => timer.id,
        "node_id" => timer.node_id,
        "timer_type" => timer.timer_type,
        "fire_at" => DateTime.to_iso8601(timer.fire_at),
        "fire_error_count" => timer.fire_error_count
      },
      first_failed_at: now,
      last_failed_at: now
    }

    {:ok, _entry} = Dlq.enqueue(dlq_attrs, prefix: tenant_schema)

    :ok
  end

  # ===========================================================================
  # Configuration (design §7)
  # ===========================================================================

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    scheduler_config()[:poll_interval_ms] || @default_poll_interval_ms
  end

  @spec jitter_ms() :: non_neg_integer()
  def jitter_ms do
    scheduler_config()[:jitter_ms] || @default_jitter_ms
  end

  @spec max_timers_per_cycle() :: pos_integer()
  def max_timers_per_cycle do
    scheduler_config()[:max_timers_per_cycle] || @default_max_timers_per_cycle
  end

  @spec max_fire_retries() :: pos_integer()
  def max_fire_retries do
    scheduler_config()[:max_fire_retries] || @default_max_fire_retries
  end

  @doc """
  GH #2864: how far (ms) a contended timer's `fire_at` is pushed back. `0` disables the postponement
  (a contended timer is then re-claimed on every cycle). Anything but a non-negative integer falls
  back to the default.
  """
  @spec contended_backoff_ms() :: non_neg_integer()
  def contended_backoff_ms do
    case scheduler_config()[:contended_backoff_ms] do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @default_contended_backoff_ms
    end
  end

  @spec retention_enabled?() :: boolean()
  def retention_enabled? do
    scheduler_config()[:retention_enabled] || @default_retention_enabled
  end

  @spec retention_interval_ms() :: pos_integer()
  def retention_interval_ms do
    scheduler_config()[:retention_interval_ms] || @default_retention_interval_ms
  end

  @spec retention_days() :: non_neg_integer()
  def retention_days do
    scheduler_config()[:retention_days] || @default_retention_days
  end

  @doc """
  Per-task timeout (ms) for `Letflow.Scheduler.Poller`'s `Task.async_stream/3`
  calls (design `iss0421-poller-bounded-concurrency.md` §4a). Read fresh on
  every call, matching every other accessor in this module -- no caching.
  """
  @spec sweep_task_timeout_ms() :: pos_integer()
  def sweep_task_timeout_ms do
    scheduler_config()[:sweep_task_timeout_ms] || @default_sweep_task_timeout_ms
  end

  defp scheduler_config, do: Application.get_env(:letflow, :scheduler, [])

  # ===========================================================================
  # Periodic retention runner (REQ-188 design §2)
  # ===========================================================================

  @doc """
  Runs one retention sweep for a single tenant schema (REQ-188 design
  §2.2). Unconditional -- does NOT itself check `retention_enabled?/0`;
  that gate lives in the caller (`Letflow.Scheduler.Poller`'s `:tick`
  handler), exactly so this function stays directly unit-testable the same
  way `poll_and_fire/1` already is. Thin wrapper around
  `Letflow.EventStore.archive/1`.
  """
  @spec run_retention_sweep(tenant_schema :: String.t()) ::
          {:ok, EventStore.archive_result()} | {:error, term()}
  def run_retention_sweep(tenant_schema) when is_binary(tenant_schema) do
    EventStore.archive(prefix: tenant_schema, retention_days: retention_days())
  rescue
    error in Postgrex.Error ->
      if match?(
           %Postgrex.Error{postgres: %{code: code}}
           when code in [:undefined_table, :undefined_schema],
           error
         ) do
        Logger.warning(
          "scheduler: tenant schema unavailable, skipping retention sweep for this tick",
          schema: tenant_schema,
          reason: :schema_unavailable
        )

        {:error, {:schema_unavailable, tenant_schema}}
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Pure predicate (no DB access) deciding whether a retention sweep is due
  (REQ-188 design §2.3). `nil` means "never run before" -- due immediately,
  mirroring `Poller.init/1`'s own zero-delay-first-tick philosophy for
  `:tick`. Otherwise due once the elapsed wall-clock time since
  `last_run_at` reaches or exceeds `retention_interval_ms/0`.
  """
  @spec retention_due?(last_run_at :: DateTime.t() | nil) :: boolean()
  def retention_due?(nil), do: true

  def retention_due?(%DateTime{} = last_run_at) do
    DateTime.diff(DateTime.utc_now(), last_run_at, :millisecond) >= retention_interval_ms()
  end

  # ===========================================================================
  # Periodic partition-maintenance runner (REQ-376 §3.1)
  # ===========================================================================

  @spec partition_maintenance_enabled?() :: boolean()
  def partition_maintenance_enabled? do
    case Keyword.fetch(scheduler_config(), :partition_maintenance_enabled) do
      {:ok, value} -> value
      :error -> @default_partition_maintenance_enabled
    end
  end

  @spec partition_maintenance_interval_ms() :: pos_integer()
  def partition_maintenance_interval_ms do
    scheduler_config()[:partition_maintenance_interval_ms] ||
      @default_partition_maintenance_interval_ms
  end

  @doc """
  Runs one partition-maintenance sweep for a single tenant schema (REQ-376
  §3.1). Unconditional -- does NOT itself check `partition_maintenance_enabled?/0`;
  that gate lives in the caller (`Letflow.Scheduler.Poller`'s `:tick`
  handler), mirroring `run_retention_sweep/1`'s own division of labor. Thin
  wrapper around `Letflow.EventStore.PartitionMaintenance.ensure_future_partitions/2`.
  """
  @spec run_partition_maintenance_sweep(tenant_schema :: String.t()) ::
          {:ok, %{events_created: [String.t()], archive_created: [String.t()]}}
          | {:error, term()}
  def run_partition_maintenance_sweep(tenant_schema) when is_binary(tenant_schema) do
    EventStore.PartitionMaintenance.ensure_future_partitions(tenant_schema)
  rescue
    error in Postgrex.Error ->
      if match?(
           %Postgrex.Error{postgres: %{code: code}}
           when code in [:undefined_table, :undefined_schema],
           error
         ) do
        Logger.warning(
          "scheduler: tenant schema unavailable, skipping partition maintenance sweep for this tick",
          schema: tenant_schema,
          reason: :schema_unavailable
        )

        {:error, {:schema_unavailable, tenant_schema}}
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Pure predicate (no DB access) deciding whether a partition-maintenance
  sweep is due (mirrors `retention_due?/1`'s exact shape). `nil` means
  "never run before" -- due immediately.
  """
  @spec partition_maintenance_due?(last_run_at :: DateTime.t() | nil) :: boolean()
  def partition_maintenance_due?(nil), do: true

  def partition_maintenance_due?(%DateTime{} = last_run_at) do
    DateTime.diff(DateTime.utc_now(), last_run_at, :millisecond) >=
      partition_maintenance_interval_ms()
  end
end
