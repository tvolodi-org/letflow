defmodule Letflow.Scheduler.PollerTest do
  @moduledoc """
  Tests for REQ-186's `Letflow.Scheduler.Poller` `GenServer` ticker itself.
  See `test/specs/REQ-186.md` (AC8) for the full acceptance-criterion ->
  test-case mapping.

  `config/test.exs` sets `start_scheduler: false` (see
  `lib/letflow/application.ex`'s own `scheduler_children/0` comment) --
  the Poller is deliberately never started under the ordinary test
  supervision tree, because its very first tick runs with zero delay and
  queries `Letflow.Repo` from a process no test process is an ancestor of,
  which under `Ecto.Adapters.SQL.Sandbox`'s default `:manual` mode raises
  `DBConnection.OwnershipError` repeatedly. This file starts its own Poller
  instance explicitly, per
  `handoffs/WF02-REQ186-20260829/step-03-test-designer.json`'s own
  instruction -- made safe here because `use Letflow.DataCase, async: false`
  puts `Ecto.Adapters.SQL.Sandbox` into `{:shared, self()}` mode for the
  whole test (see `test/support/data_case.ex`), so the Poller's own process
  (not a descendant of the test process) shares the same sandboxed
  connection as the test without needing an explicit `Sandbox.allow/3` call.

  `Letflow.SchedulerTest` (`test/letflow/scheduler_test.exs`) covers every
  other REQ-186 acceptance criterion by calling `Letflow.Scheduler`'s own
  functions directly, matching this codebase's established "context module
  tested without its process wrapper" precedent -- not duplicated here.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Admission
  alias Letflow.AdmissionTestHelpers
  alias Letflow.Definitions
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.ArchivedEvent
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.Identity.Tenant
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Poller
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.WebhookTestServer

  defp provisioned_tenant(slug_prefix \\ "req186-poller") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-186 Poller Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # REQ-187: task's own node_type is TIMER (not HUMAN_TASK) -- firing a
  # timer now re-enters Letflow.Engine to advance the token off the :TIMER
  # node it's found sitting on via the timer's own token_id, so a timer
  # this file expects to actually *fire* successfully must be armed with
  # `token_id: live_token_id!/2`, matching this graph's own real live
  # token. `duration_iso8601` is far in the future (`P1D`) so
  # start_instance!/1's own automatic REQ-187 timer-arm never becomes due
  # during this test.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp live_token_id!(schema_name, instance_id) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id and t.status == :active)
    |> select([t], t.id)
    |> Repo.one!(prefix: schema_name)
    |> to_string()
  end

  defp start_instance!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("req186-poller-def"),
                 version: "1.0.0",
                 graph: graph_human_task_end(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: activated.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_name("req186-poller-start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  # ISS-0581: local, file-scoped poll-until-condition helper, matching this
  # codebase's established per-file-duplicate convention (see
  # invocation_lease_test.exs's identical pair, sandbox_pool_test.exs's
  # wait_until_pool_state/3 and wait_until_schema_dropped/2) rather than a
  # new shared test/support/ helper.
  @spec wait_until((-> boolean()), non_neg_integer()) :: boolean()
  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  @spec do_wait_until((-> boolean()), integer()) :: boolean()
  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  defp put_scheduler_config(overrides) do
    original = Application.get_env(:letflow, :scheduler)
    Application.put_env(:letflow, :scheduler, overrides)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :scheduler)
        val -> Application.put_env(:letflow, :scheduler, val)
      end
    end)
  end

  describe "AC8: Poller.handle_info(:tick, _) reads config fresh and uses the overridden poll_interval_ms" do
    test "a timer armed after the Poller's own first tick is still fired well within the overridden interval, far faster than the 5000ms default would allow" do
      put_scheduler_config(
        poll_interval_ms: 30,
        jitter_ms: 0,
        max_timers_per_cycle: 64,
        max_fire_retries: 3
      )

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      start_supervised!(Poller)

      # Let the Poller's own immediate (zero-delay) first tick run and
      # complete -- at this point no due timer exists yet, so it's a no-op.
      Process.sleep(20)

      fire_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      assert {:ok, timer} =
               Scheduler.create(
                 Letflow.Repo,
                 %{
                   instance_id: instance_id,
                   timer_type: "deadline",
                   node_id: "poller-ac8",
                   fire_at: fire_at,
                   token_id: live_token_id!(schema_name, instance_id)
                 },
                 prefix: schema_name
               )

      # Only a SECOND tick, scheduled at (overridden) poll_interval_ms after
      # the first, can pick this timer up. 300ms comfortably fits ~10 ticks
      # at the 30ms override, but is nowhere near one tick at the 5000ms
      # documented default -- if the Poller ignored the override (e.g. a
      # mutation hardcoding the default, or caching poll_interval_ms/0's
      # value at init/1 time instead of reading it fresh every tick), this
      # timer would still be pending when we check.
      #
      # ISS-0581: a fixed Process.sleep(300) + single assertion was flaky
      # under parallel-suite contention (tick wall-clock duration inflates
      # under CPU/DB contention, so fewer ticks complete inside a fixed
      # 300ms budget) -- polled with wait_until/2 instead, up to a 2000ms
      # ceiling, so a healthy/unloaded run still completes in roughly the
      # original ~300ms (returns as soon as the predicate is true) while a
      # contended run gets real margin. See
      # lib/letflow/design/iss0581-poller-ac8-timing-fix.md.
      fired? =
        wait_until(
          fn -> Repo.get!(Timer, timer.id, prefix: schema_name).status == "fired" end,
          2_000
        )

      assert fired?,
             "expected timer #{timer.id} to reach status \"fired\" within 2000ms " <>
               "of arming (poll_interval_ms override was 30ms); got status " <>
               "#{Repo.get!(Timer, timer.id, prefix: schema_name).status} instead -- " <>
               "see ISS-0581 for the wall-clock-tick-cadence-under-contention rationale"
    end
  end

  # ===================================================================================
  # REQ-188 Part 2 -- the periodic retention runner (ACs 5-7). See
  # test/specs/REQ-188.md for the full acceptance-criterion -> test-case map.
  # `Poller.handle_info(:tick, state)` is called directly as a plain function
  # (it is a public `@impl true` function, callable without starting the
  # GenServer process), matching the design doc's own §2.4 "Default-disabled
  # proof" note -- this sidesteps the Ecto.Sandbox ownership issue
  # `application.ex`'s own comment documents for why the Poller is disabled
  # by default in `config/test.exs`, and lets these tests assert on real row
  # counts (no mocking library exists in this codebase) rather than a call
  # count on a mock.
  # ===================================================================================

  defp table_count(schema, schema_name) do
    Repo.aggregate(schema, :count, prefix: schema_name)
  end

  defp unique_idempotency_key(prefix \\ "req188-poller-idk"),
    do: prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp seed_instance_sequence!(schema_name, instance_id, next_seq \\ 1) do
    %InstanceSequence{}
    |> InstanceSequence.insert_changeset(%{instance_id: instance_id, next_seq: next_seq})
    |> Repo.insert!(prefix: schema_name)
  end

  # Direct events row seeding with a caller-chosen created_at (deliberately in
  # the past for retention-eligibility), mirroring
  # test/letflow/event_store_test.exs's own seed_event!/7 fixture idiom (this
  # file's own copy since that one is private to its own module).
  defp seed_event!(schema_name, instance_id, created_at, seq \\ 1) do
    %Event{}
    |> Event.insert_changeset(%{
      event_id: Ecto.UUID.generate(),
      created_at: created_at,
      instance_id: instance_id,
      event_type: "req188_poller_test_event",
      payload: %{"seeded" => true},
      actor_id: Ecto.UUID.generate(),
      sequence_number: seq,
      idempotency_key: unique_idempotency_key()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  describe "AC5: the retention runner is disabled by default -- zero archive/1 calls over a full poll cycle" do
    test "an old, otherwise-eligible event is untouched after a tick, with no :retention_enabled config set" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, instance_id)

      old_created_at = ~U[2020-01-01 00:00:00.000000Z]
      seed_event!(schema_name, instance_id, old_created_at)

      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 0

      assert Application.get_env(:letflow, :scheduler) == nil
      assert Scheduler.retention_enabled?() == false

      assert {:noreply, new_state} =
               Poller.handle_info(:tick, %{
                 last_retention_run_at: nil,
                 last_partition_maintenance_run_at: nil
               })

      assert new_state.last_retention_run_at == nil
      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 0
    end

    test "the guard stays closed across several ticks, regardless of how much wall-clock time has elapsed" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, instance_id)
      seed_event!(schema_name, instance_id, ~U[2020-01-01 00:00:00.000000Z])

      state =
        Enum.reduce(
          1..5,
          %{last_retention_run_at: nil, last_partition_maintenance_run_at: nil},
          fn _, state ->
            assert {:noreply, next_state} = Poller.handle_info(:tick, state)
            next_state
          end
        )

      assert state.last_retention_run_at == nil
      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 0
    end
  end

  describe "AC6: enabling retention invokes archive/1 and moves rows older than the configured retention" do
    test "a tick moves the old event into events_archive and leaves the recent one in events" do
      put_scheduler_config(retention_enabled: true, retention_interval_ms: 0, retention_days: 30)

      %{schema_name: schema_name} = provisioned_tenant()
      old_instance_id = Ecto.UUID.generate()
      recent_instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, old_instance_id)
      seed_instance_sequence!(schema_name, recent_instance_id)

      old_created_at =
        DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:microsecond)

      recent_created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      seed_event!(schema_name, old_instance_id, old_created_at)
      seed_event!(schema_name, recent_instance_id, recent_created_at)

      assert table_count(Event, schema_name) == 2
      assert table_count(ArchivedEvent, schema_name) == 0

      assert {:noreply, new_state} =
               Poller.handle_info(:tick, %{
                 last_retention_run_at: nil,
                 last_partition_maintenance_run_at: nil
               })

      assert %DateTime{} = new_state.last_retention_run_at

      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 1

      assert [remaining] = Repo.all(Event, prefix: schema_name)
      assert remaining.instance_id == recent_instance_id
    end

    test "retention_due?/1 gates a second tick from re-sweeping before its own interval elapses" do
      put_scheduler_config(
        retention_enabled: true,
        retention_interval_ms: 86_400_000,
        retention_days: 30
      )

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, instance_id)

      old_created_at =
        DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:microsecond)

      seed_event!(schema_name, instance_id, old_created_at)

      assert {:noreply, state_after_first} =
               Poller.handle_info(:tick, %{
                 last_retention_run_at: nil,
                 last_partition_maintenance_run_at: nil
               })

      assert %DateTime{} = first_run_at = state_after_first.last_retention_run_at
      assert table_count(Event, schema_name) == 0
      assert table_count(ArchivedEvent, schema_name) == 1

      # A second event, old enough that it WOULD be archived if the guard
      # re-swept -- retention_interval_ms: 86_400_000 (24h) has not elapsed
      # since first_run_at, so this second tick must be a no-op.
      seed_event!(schema_name, instance_id, old_created_at, 2)
      assert table_count(Event, schema_name) == 1

      assert {:noreply, state_after_second} = Poller.handle_info(:tick, state_after_first)

      assert DateTime.compare(state_after_second.last_retention_run_at, first_run_at) == :eq
      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 1
    end
  end

  # ===================================================================================
  # ISS-0429 -- a dispatched alert-hook delivery mid-backoff must not block the
  # Poller's own subsequent :tick. See
  # lib/letflow/design/iss0429-async-alert-hook-delivery.md §6 for the full test
  # rationale this describe block implements.
  # ===================================================================================

  defp put_alert_config(overrides) do
    original = Application.get_env(:letflow, :alert_hooks)
    Application.put_env(:letflow, :alert_hooks, overrides)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :alert_hooks)
        val -> Application.put_env(:letflow, :alert_hooks, val)
      end
    end)
  end

  describe "ISS-0429: a dispatched hook delivery mid-backoff does not block a subsequent :tick" do
    test "the Poller's own last_tick_started_at advances more than once while the only " <>
           "configured hook is still retrying its (slow) backoff schedule" do
      # Always-500 server -- deliver_with_retry/4 enters its Process.sleep(backoff_delay/2)
      # branch on every attempt. base_backoff_ms/max_backoff_ms are both 2_000ms (test-local
      # RetryPolicy override, not the production default) so the mid-backoff window is
      # comfortably wide -- long enough to straddle several real ticks at the overridden
      # poll_interval_ms below, but short enough this test still finishes in well under a
      # second either way (pass or fail-first).
      server = WebhookTestServer.start(500, "internal error")

      put_alert_config(
        enabled: true,
        thresholds: [dlq_depth_threshold: 5],
        hooks: [
          [
            hook_id: "iss0429-poller-block-hook",
            enabled: true,
            destination_url: server.url,
            timeout_ms: 1_000,
            auth_secret_ref: nil,
            retry_policy: [
              max_attempts: 5,
              base_backoff_ms: 2_000,
              max_backoff_ms: 2_000,
              multiplier: 2.0
            ]
          ]
        ]
      )

      # Short poll interval so several real ticks fall well inside the hook's
      # still-in-progress 2_000ms backoff window from the first tick's dispatch.
      put_scheduler_config(poll_interval_ms: 40, jitter_ms: 0, max_timers_per_cycle: 64)

      %{schema_name: schema_name} = provisioned_tenant("iss0429-poller-block")

      # Push dlq_count over the threshold=5 BEFORE the Poller starts, so its very
      # first (zero-delay) tick's alert detection pass fires the hook immediately.
      for _ <- 1..6 do
        assert {:ok, _entry} =
                 Dlq.enqueue(%{entry_type: "iss0429_poller_block_test"}, prefix: schema_name)
      end

      pid = start_supervised!(Poller)

      # Let the first tick (and its synchronous check_and_record_emission/4 commit +
      # fire-and-forget dispatch) run and settle.
      Process.sleep(30)

      timestamps =
        for _ <- 1..8 do
          Process.sleep(40)
          state = :sys.get_state(pid)
          state.last_tick_started_at
        end

      distinct_timestamps = Enum.uniq(timestamps)

      # Regression proof: at least two DIFFERENT last_tick_started_at values must have
      # been observed within this ~350ms sampling window, which is well inside the
      # hook's still-mid-backoff 2_000ms window from the first dispatch. Pre-fix, the
      # Poller's own handle_info(:tick, _) call ran deliver_with_retry/4 synchronously
      # and would still be blocked inside Process.sleep(2_000) at this point --
      # schedule_next_tick/0 is only ever reached AFTER that call returns, so
      # last_tick_started_at would never have advanced past its first value.
      assert length(distinct_timestamps) >= 2,
             "expected the Poller to process more than one :tick within #{8 * 40}ms while " <>
               "the dispatched hook was still mid-backoff (2_000ms); observed only " <>
               "#{length(distinct_timestamps)} distinct last_tick_started_at value(s) -- " <>
               "the Poller's own tick appears to be blocked on hook delivery"
    end
  end

  # ===================================================================================
  # REQ-218 -- admission-control wiring on Poller's six sequential per-tenant
  # operations. See lib/letflow/design/req218-poller-admission-wiring.md for the
  # full design; test shapes below follow its §6 (with the AC3 "precise
  # interleaving harness" and AC5 "fault-injection point" both explicitly left to
  # TEST-DESIGNER/ELIXIR-DEV's discretion there).
  # ===================================================================================

  defp due_timer_for!(schema_name, node_id) do
    instance_id = start_instance!(schema_name)

    fire_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    assert {:ok, timer} =
             Scheduler.create(
               Repo,
               %{
                 instance_id: instance_id,
                 timer_type: "deadline",
                 node_id: node_id,
                 fire_at: fire_at,
                 token_id: live_token_id!(schema_name, instance_id)
               },
               prefix: schema_name
             )

    timer.id
  end

  defp timer_status!(schema_name, timer_id) do
    Repo.get!(Timer, timer_id, prefix: schema_name).status
  end

  # A fully-provisioned (normal) tenant schema, minus its ordering table --
  # this is a surgical fault injection targeting ONLY the ordering rows
  # (maybe_run_ordering_cycle/1, maybe_run_ordering_sweeper/1,
  # maybe_run_ordering_metrics/1), which all query "effect_completions"
  # (lib/letflow/ordering/consumer.ex, sweeper.ex, metrics.ex) and have no
  # internal self-rescue, unlike Letflow.Obs.Alerts's own safe_* helpers
  # (design doc's §7 Q4). A schema whose Postgres schema was never created at
  # all was tried first and rejected: Letflow.Scheduler.poll_and_fire/1 (row
  # 1, contract-documented to never raise, with NO poller-side rescue at all)
  # turned out to ALSO raise for a schema missing its "timers" table entirely
  # -- crashing the whole tick before ever reaching the ordering rows this AC
  # is actually about. Dropping only "effect_completions" from an otherwise
  # intact, fully-migrated schema leaves "timers" (and everything else)
  # intact, so poll_and_fire/1, retention, and REQ-194's per-schema-rescued
  # active-instance refresh are all unaffected -- only the three ordering
  # rows' own queries fail.
  defp drop_ordering_table!(schema_name) do
    Repo.query!(~s(DROP TABLE IF EXISTS "#{schema_name}"."effect_completions" CASCADE))
  end

  describe "REQ-218 AC1: forced-zero admission cap skips every schema; capacity restored resumes normally" do
    test "holding the sole global unit before a tick leaves all 3 schemas' timers pending; releasing it lets the next tick fire all 3" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)

      schemas =
        for i <- 1..3 do
          %{schema_name: schema_name} = provisioned_tenant("req218-ac1-#{i}")
          timer_id = due_timer_for!(schema_name, "req218-ac1")
          {schema_name, timer_id}
        end

      assert {:ok, probe_ref} = Admission.try_acquire(:global)

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      assert {:noreply, state_after_zero} = Poller.handle_info(:tick, state)

      for {schema_name, timer_id} <- schemas do
        assert timer_status!(schema_name, timer_id) == "pending"
      end

      :ok = Admission.release(probe_ref)

      assert {:noreply, _state_after_restore} = Poller.handle_info(:tick, state_after_zero)

      for {schema_name, timer_id} <- schemas do
        assert timer_status!(schema_name, timer_id) == "fired"
      end
    end
  end

  describe "REQ-218 AC2: a cap of exactly 1 still drains all schemas sequentially within a single tick" do
    test "3 schemas' due timers all fire within one tick, with no probe held and global_cap == 1" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)

      schemas =
        for i <- 1..3 do
          %{schema_name: schema_name} = provisioned_tenant("req218-ac2-#{i}")
          timer_id = due_timer_for!(schema_name, "req218-ac2")
          {schema_name, timer_id}
        end

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      assert {:noreply, _new_state} = Poller.handle_info(:tick, state)

      for {schema_name, timer_id} <- schemas do
        assert timer_status!(schema_name, timer_id) == "fired"
      end
    end
  end

  # AC3 is made DETERMINISTIC by construction (GH #2364: the previous
  # spinning-antagonist design was probabilistic and flaked on CI).
  #
  # Facts this relies on (lib/letflow/scheduler/poller.ex):
  #   * with global_cap == 1 the poll-and-fire sweep's Task.async_stream has
  #     max_concurrency == 1, so schemas are processed strictly one after
  #     another, each as try_acquire(:global) -> :admission_decision telemetry
  #     (emitted synchronously, in the sweep task process) -> poll_and_fire
  #     while holding the unit -> release.
  #   * the test process holds the sole unit (`probe_ref`) BEFORE the tick, so
  #     the first @ac3_reject_count poll_and_fire attempts are rejected with
  #     no race at all (same strict happens-before as the AC3b test below).
  #   * the telemetry handler releases the probe synchronously, on the sweep
  #     task process, when it observes the @ac3_reject_count-th rejected
  #     :poll_and_fire decision -- i.e. strictly BEFORE the next schema's
  #     try_acquire. Every later schema in the same tick is therefore admitted.
  # Result: exactly the first @ac3_reject_count schemas rejected and every
  # other schema admitted, in ONE tick, independent of timing/CPU speed.
  @ac3_reject_count 4

  defp attach_ac3_release_after_n_rejections(test_pid, probe_ref, n) do
    handler_id = "poller-ac3-release-after-n-#{System.unique_integer([:positive, :monotonic])}"
    rejected = :counters.new(1, [])

    :telemetry.attach(
      handler_id,
      [:letflow, :scheduler, :admission_decision],
      fn _event, _measurements, metadata, _config ->
        if metadata.op == :poll_and_fire do
          send(test_pid, {:ac3_decision, metadata.schema, metadata.result})

          if metadata.result == :rejected do
            :counters.add(rejected, 1, 1)
            if :counters.get(rejected, 1) == n, do: Admission.release(probe_ref)
          end
        end
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp drain_ac3_decisions(acc) do
    receive do
      {:ac3_decision, schema, result} -> drain_ac3_decisions([{schema, result} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "REQ-218 AC3: a capacity rejection for one schema/operation does not block the rest of the same tick" do
    test "a deterministic partial skip admits the rest of the tick; skipped timers fire next tick" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)
      # The strict sequential order this test relies on requires a cap of exactly 1.
      assert Admission.global_cap() == 1

      timers =
        for i <- 1..10 do
          %{schema_name: schema_name} = provisioned_tenant("req218-ac3-#{i}")
          {schema_name, due_timer_for!(schema_name, "req218-ac3")}
        end

      ours = Map.new(timers)

      assert {:ok, probe_ref} = Admission.try_acquire(:global)
      handler_id = attach_ac3_release_after_n_rejections(self(), probe_ref, @ac3_reject_count)

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      assert {:noreply, state_after_tick1} = Poller.handle_info(:tick, state)
      :telemetry.detach(handler_id)

      all_decisions = drain_ac3_decisions([])

      # Only OUR 10 schemas' decisions are asserted on (a leaked registration
      # from elsewhere in the DB would add decisions, but cannot reorder ours).
      decisions = Enum.filter(all_decisions, fn {schema, _} -> Map.has_key?(ours, schema) end)
      assert length(decisions) == 10

      rejected = for {schema, :rejected} <- decisions, do: schema
      granted = for {schema, :granted} <- decisions, do: schema

      # Sequential processing + release on the N-th rejection => (among our
      # schemas) a rejected prefix followed by only grants.
      expected_prefix = List.duplicate(:rejected, length(rejected))

      assert Enum.map(decisions, &elem(&1, 1)) ==
               expected_prefix ++ List.duplicate(:granted, length(granted))

      # Genuine partial skip: some rejected, some admitted, all 10 accounted for.
      assert length(rejected) in 1..@ac3_reject_count
      assert granted != []

      # A rejection did not block the rest of the tick: admitted => fired.
      for schema <- granted, do: assert(timer_status!(schema, ours[schema]) == "fired")

      # Rejected schemas' timers are left due (not fired, not deleted) ...
      for schema <- rejected, do: assert(timer_status!(schema, ours[schema]) == "pending")

      # ... and fire on the next tick once capacity is free.
      assert {:noreply, _} = Poller.handle_info(:tick, state_after_tick1)

      for {schema, timer_id} <- timers do
        assert timer_status!(schema, timer_id) == "fired"
      end
    end
  end

  # A retention-eligible event NOT archived on a rejected attempt stays
  # pending in the "events" table -- left alone, it would still be there (and
  # still eligible) on the NEXT attempt, so a later attempt's successful
  # retention sweep could archive TWO (or more, across several skipped
  # attempts) events at once, breaking a simple "archived count went up by
  # exactly 1" delta check. Deleting any leftover pending event before each
  # fresh attempt keeps every attempt's own delta isolated.
  defp clear_pending_events!(schema_name) do
    Repo.delete_all(Event, prefix: schema_name)
  end

  # AC3's requirement text has TWO independent sub-clauses: (a) a rejection
  # for one schema's operation does not block a DIFFERENT schema's SAME
  # operation later in the tick (covered above by the 10-schema deterministic
  # test, all racing for the same poll_and_fire operation), and (b) a
  # rejection for one schema's operation does not block that SAME schema's
  # OTHER operations later in the tick. (a) alone does not exercise (b) --
  # a coarser, forbidden design (one acquire/release per SCHEMA covering all
  # six of its operations, ruled out by design doc §1/§3) would still pass
  # every assertion in the test above, since that test only ever looks at
  # one operation (poll_and_fire) across many schemas.
  #
  # This test exercises (b) with a LARGELY DETERMINISTIC harness rather than
  # a two-sided race: an earlier draft used a continuous antagonist Task
  # (mirroring the since-removed AC3 spinning antagonist) contending against BOTH the
  # target schema's poll_and_fire AND its retention-sweep admission calls at
  # once. Diagnostic runs (temporary IO.puts instrumentation, since removed)
  # showed that shape is not merely occasionally flaky but structurally
  # biased: with a single sole global unit and a tight-looping antagonist,
  # BOTH of the target's admission attempts overwhelmingly land on the SAME
  # side of the race together (both admitted, or both rejected) far more
  # often than they split -- a two-sided race does not reliably produce the
  # one outcome this test needs. The fix removes one whole side of the race:
  # the probe is acquired by the TEST process itself BEFORE `handle_info/2`
  # is even invoked, so the tick's very FIRST admission attempt (this
  # schema's poll_and_fire, with no other schema ahead of it in the
  # `Enum.each`) is DETERMINISTICALLY rejected -- no race at all, since the
  # test process's own `try_acquire/1` call has already completed, and
  # nothing else could have taken or released that unit before
  # `handle_info/2`'s own first line runs (same-process, strict
  # happens-before ordering; `Task.async/1` below does not block this
  # process from proceeding straight into the tick call). Only ONE race
  # remains: whether the probe is released (by a short-lived helper Task)
  # before the SAME schema's LATER retention-sweep admission attempt, which
  # runs only after the entire poll_and_fire loop plus the unwrapped
  # `maybe_refresh_active_instances/1` pass have completed -- a comfortably
  # wide, one-sided margin rather than a symmetric coin flip.
  # ISS-0695: attaches a test-only `:telemetry` handler to
  # `[:letflow, :scheduler, :admission_decision]` (emitted once per
  # `with_admission/3` call -- see `lib/letflow/scheduler/poller.ex`),
  # filtered to `schema_name`'s own `:poll_and_fire` admission decision.
  # Handler id/attach/detach shape follows
  # `test/letflow/plugs/http_metrics_test.exs`'s `attach_test_handler/2`
  # precedent (unique handler id, `on_exit/1` detach).
  #
  # Deviates from `lib/letflow/design/iss0695-poller-ac3b-telemetry-sync-fix.md`
  # on ONE point, deliberately: the design's own text has the release happen
  # in the *test process*, driven by the signal via `assert_receive`. That
  # shape was tried first and reproduced the flake it was meant to fix
  # (observed 1/8 local runs): `:telemetry.execute/3` invokes this handler
  # SYNCHRONOUSLY in the *Poller process* itself, but a `send/2` to the test
  # process only *schedules* a wakeup -- the Poller process is free to keep
  # running (finish this schema's `Enum.each` iteration, call
  # `maybe_refresh_active_instances/1`, reach retention's own
  # `with_admission/3` call for this same schema) before the test process is
  # even scheduled to run its `assert_receive` continuation, let alone
  # complete the `Admission.release/1` GenServer round trip after it. That
  # reintroduces exactly the kind of scheduler-timing race this fix exists to
  # remove, just with a different two-sided shape than the original
  # `Process.sleep/1` one. Calling `Admission.release/1` *inside the handler
  # itself* (still running on the Poller process, synchronously, before
  # `:telemetry.execute/3` returns to `with_admission/3`) makes the release
  # happen-before any later admission attempt in the same tick with actual
  # BEAM process-ordering guarantees, not a probabilistic race window --
  # this is what step 4's "no wall-clock estimate is involved anywhere in
  # this step" claim actually requires to hold. The `send/2` to `test_pid`
  # is kept as the safety-net `assert_receive` signal the design also calls
  # for, just no longer load-bearing for the release ordering itself.
  defp attach_ac3b_admission_probe(test_pid, schema_name, probe_ref) do
    handler_id = "poller-ac3b-admission-probe-#{System.unique_integer([:positive, :monotonic])}"

    :telemetry.attach(
      handler_id,
      [:letflow, :scheduler, :admission_decision],
      fn _event, _measurements, metadata, _config ->
        if metadata.schema == schema_name and metadata.op == :poll_and_fire do
          Admission.release(probe_ref)
          send(test_pid, {:ac3b_admission_decision, metadata})
        end
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # ISS-0695: the release-vs-retention-sweep race that used to require a
  # fixed `Process.sleep/1` plus 12 filler tenant schemas to widen the gap
  # (see prior revision's comment, removed) is eliminated, not narrowed --
  # the probe is released synchronously, on the Poller process itself,
  # inside the `[:letflow, :scheduler, :admission_decision]` telemetry
  # handler (see `attach_ac3b_admission_probe/3`'s own comment for why this
  # differs from the design doc's test-process-release shape). This makes
  # the target schema's retention sweep running after its own poll_and_fire
  # rejection deterministic, so a single attempt (no retry loop) suffices.
  defp ac3b_attempt(schema_name, instance_id) do
    clear_pending_events!(schema_name)
    timer_id = due_timer_for!(schema_name, "req218-ac3b")

    old_created_at =
      DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:microsecond)

    seed_event!(schema_name, instance_id, old_created_at, 1)
    archived_before = table_count(ArchivedEvent, schema_name)

    assert {:ok, probe_ref} = Admission.try_acquire(:global)
    attach_ac3b_admission_probe(self(), schema_name, probe_ref)

    state = %{
      last_retention_run_at: nil,
      last_tick_started_at: nil,
      last_partition_maintenance_run_at: nil
    }

    assert {:noreply, _new_state} = Poller.handle_info(:tick, state)

    # Safety-net confirmation only -- by the time this returns, the handler
    # has already released the probe synchronously on the Poller process
    # (see above). Not load-bearing for ordering, just a bounded wait
    # against a genuine hang/regression (design doc's own framing).
    assert_receive {:ac3b_admission_decision, %{result: :rejected}}, 2_000

    # Deterministic per the comment above: the probe was held before the
    # tick began, so this schema's poll_and_fire admission call -- the very
    # first admission attempt of the whole tick -- must have been rejected.
    assert timer_status!(schema_name, timer_id) == "pending",
           "expected this schema's poll_and_fire to be deterministically rejected (probe held " <>
             "before the tick began), but its timer fired anyway"

    table_count(ArchivedEvent, schema_name) == archived_before + 1
  end

  describe "REQ-218 AC3 (per-schema clause): a rejected schema's other ops still proceed" do
    test "the same schema's retention sweep still runs after its own poll_and_fire was rejected, in the same tick" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)
      put_scheduler_config(retention_enabled: true, retention_interval_ms: 0, retention_days: 30)

      %{schema_name: schema_name} = provisioned_tenant("req218-ac3b")
      instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, instance_id)

      assert ac3b_attempt(schema_name, instance_id),
             "expected this schema's retention sweep to still run (old event archived) after " <>
               "its own poll_and_fire admission call was deterministically rejected in the " <>
               "same tick -- proving a rejected operation for a schema does not block that " <>
               "SAME schema's OTHER operations from being attempted later in the same tick"
    end
  end

  # ISS-0695: `attach_ac3b_admission_probe/3` above only ever exercises ONE
  # op (`:poll_and_fire`) and ONE result (`:rejected`) of the
  # `[:letflow, :scheduler, :admission_decision]` telemetry event -- that is
  # sufficient for AC3b's own synchronization need, but leaves the event's
  # `:granted` branch, and its `op`/`schema`/`measurements` shape in
  # general, with no coverage of its own. Now that this event is load-bearing
  # for a test's correctness (not merely an OBS-02-style metric nobody reads
  # the value of), a regression here -- wrong metadata key, event dropped on
  # the granted branch, non-empty measurements -- deserves its own direct
  # unit coverage, independent of AC3b's specific rejected/poll_and_fire use.
  defp attach_admission_decision_collector(test_pid, schema_name) do
    handler_id =
      "poller-admission-decision-collector-#{System.unique_integer([:positive, :monotonic])}"

    :telemetry.attach(
      handler_id,
      [:letflow, :scheduler, :admission_decision],
      fn _event, measurements, metadata, _config ->
        if metadata.schema == schema_name do
          send(test_pid, {:admission_decision, measurements, metadata})
        end
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "ISS-0695: [:letflow, :scheduler, :admission_decision] telemetry emission" do
    test "a granted admission emits the event with empty measurements and :granted metadata" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)

      %{schema_name: schema_name} = provisioned_tenant("iss0695-telemetry-granted")
      timer_id = due_timer_for!(schema_name, "iss0695-telemetry-granted")

      attach_admission_decision_collector(self(), schema_name)

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      assert {:noreply, _new_state} = Poller.handle_info(:tick, state)

      assert_receive {:admission_decision, measurements, metadata}, 2_000

      assert measurements == %{}
      assert metadata.schema == schema_name
      assert metadata.op == :poll_and_fire
      assert metadata.result == :granted

      # Real-world corroboration: an uncontended admission that was really
      # granted let this schema's due timer actually fire.
      assert timer_status!(schema_name, timer_id) == "fired"
    end

    test "a rejected admission emits the event with :rejected metadata, distinct from :granted" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)

      %{schema_name: schema_name} = provisioned_tenant("iss0695-telemetry-rejected")
      timer_id = due_timer_for!(schema_name, "iss0695-telemetry-rejected")

      assert {:ok, probe_ref} = Admission.try_acquire(:global)
      attach_admission_decision_collector(self(), schema_name)

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      assert {:noreply, _new_state} = Poller.handle_info(:tick, state)

      assert_receive {:admission_decision, measurements, metadata}, 2_000

      assert measurements == %{}
      assert metadata.schema == schema_name
      assert metadata.op == :poll_and_fire
      assert metadata.result == :rejected

      # Real-world corroboration: the deterministically-held probe really
      # did block this schema's poll_and_fire from running.
      assert timer_status!(schema_name, timer_id) == "pending"

      :ok = Admission.release(probe_ref)
    end
  end

  describe "REQ-218 AC4: Letflow.Admission.try_acquire({:tenant, _}) is never called from poller.ex" do
    test "the source text of lib/letflow/scheduler/poller.ex contains no {:tenant, admission call" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/scheduler/poller.ex"))

      refute source =~ "{:tenant,",
             "poller.ex must only ever call Letflow.Admission.try_acquire(:global) -- " <>
               "REQ-218 decision 3 explicitly excludes the per-tenant pool for Poller"
    end
  end

  describe "REQ-218 AC5: an existing per-operation rescue still catches its own raise, with the admission slot released (no leak)" do
    test "a schema missing its ordering table raises inside maybe_run_ordering_cycle/1's own rescue, without leaking its admission slot or crashing the tick" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)

      %{schema_name: broken_schema_name} = provisioned_tenant("req218-ac5-broken")
      drop_ordering_table!(broken_schema_name)

      %{schema_name: real_schema_name} = provisioned_tenant("req218-ac5-real")
      timer_id = due_timer_for!(real_schema_name, "req218-ac5")

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      # Must not crash the calling (test) process -- maybe_run_ordering_cycle/1's
      # (and _sweeper/1's and _metrics/1's) existing `rescue _ -> :ok` must still
      # catch the raise this broken schema forces, with the new acquire/release
      # wrapped around it per the design's §1 point 2 (the acquire/release wraps
      # AROUND the existing rescue, never replacing it).
      assert {:noreply, _new_state} = Poller.handle_info(:tick, state)

      # The real schema's own operations were unaffected by the broken schema's raise.
      assert timer_status!(real_schema_name, timer_id) == "fired"

      # No leak: with global_cap == 1 (pool_size: 3, reserved_headroom: 2), if any
      # of the broken schema's raised ordering admission round trips had failed to
      # release, this probe would observe {:error, :capacity} instead.
      assert {:ok, probe_ref} = Admission.try_acquire(:global)
      :ok = Admission.release(probe_ref)
    end
  end

  # ===================================================================================
  # ISS-0421 -- bounded per-tenant concurrency within each sweep. See
  # lib/letflow/design/iss0421-poller-bounded-concurrency.md. The REQ-218 tests
  # above (AC1/AC2/AC3/AC3-per-schema/AC5) all pre-date this fix and were left
  # byte-for-byte untouched by it (confirmed by REVIEWER's own diff check,
  # handoffs/WF03-ISS0421-20260904/step-04d-reviewer-recheck.json) -- they
  # exercise Admission's own capacity gate, not the Task.async_stream
  # concurrency mechanism this fix adds. The describes below are this fix's
  # OWN dedicated coverage.
  # ===================================================================================

  describe "ISS-0421 regression: the gated sweeps' max_concurrency derives live via sweep_concurrency/0, not a literal" do
    test "with global_cap forced to 1 (pool_size: 3, reserved_headroom: 2), all 5 schemas' due timers fire within a single tick" do
      # This is the same class of proof REVIEWER and ELIXIR-DEV both
      # independently confirmed by hand (sed-substituting the old hardcoded
      # `8` back into poller.ex and re-running REQ-218's AC1/AC2/AC3/AC5
      # tests, all 4 of which failed) -- committed here as its own,
      # explicitly-labeled, permanent test rather than relying only on that
      # REQ-218 side effect.
      #
      # With max_concurrency correctly derived LIVE as Admission.global_cap()
      # (== 1 for this config), Task.async_stream admits schemas strictly one
      # at a time -- Poller never holds more than one admission unit at a
      # time (no concurrent self-contention), so every schema's poll_and_fire
      # attempt is uncontested and succeeds, exactly like Enum.each did
      # before this fix.
      #
      # If a future edit reintroduced a hardcoded max_concurrency literal
      # (e.g. the old `8`) instead of this live call, Task.async_stream would
      # launch all 5 of these schemas' tasks concurrently at once, all racing
      # for the SAME sole global admission unit at (very nearly) the same
      # instant -- Admission grants exactly one of them and permanently
      # rejects the rest (try_acquire is a single synchronous decision, never
      # retried), so strictly fewer than all 5 timers would fire. This makes
      # the assertion below deterministically distinguish the two cases
      # rather than merely being probabilistically likely to catch a
      # regression.
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)

      schemas =
        for i <- 1..5 do
          %{schema_name: schema_name} = provisioned_tenant("iss0421-hardcode-#{i}")
          timer_id = due_timer_for!(schema_name, "iss0421-hardcode")
          {schema_name, timer_id}
        end

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      assert {:noreply, _new_state} = Poller.handle_info(:tick, state)

      for {schema_name, timer_id} <- schemas do
        assert timer_status!(schema_name, timer_id) == "fired"
      end
    end
  end

  # AC1 (fault isolation): `Scheduler.poll_and_fire/1` and
  # `Scheduler.run_retention_sweep/1` each already have their OWN internal
  # rescue (lib/letflow/scheduler.ex), but it catches ONLY a `Postgrex.Error`
  # whose code is `:undefined_table`/`:undefined_schema` (ISS-0444) --
  # anything else re-raises. Before this fix, that re-raise had no poller-side
  # backstop at all for these two specific call sites (design §4b: "the two
  # that do NOT currently have one... need one added at their
  # Task.async_stream/3 call site"). This describe proves the NEW top-level
  # per-task rescue this fix adds actually catches a raise that Scheduler's
  # own narrower rescue does NOT, without crashing the tick and without
  # blocking any other schema's own poll_and_fire in the same sweep.
  # A Postgrex `:undefined_column` error -- NOT one of the two codes
  # (:undefined_table, :undefined_schema) Scheduler.poll_and_fire/1's own
  # rescue matches -- so it re-raises out of claim_due_timer_ids/2, reaching
  # poller.ex's Task.async_stream call site as a genuine, uncaught exception
  # for this fix's new rescue to catch.
  defp drop_timers_fire_at_column!(schema_name) do
    Repo.query!(~s(ALTER TABLE "#{schema_name}"."timers" DROP COLUMN fire_at))
  end

  describe "ISS-0421 AC1: new top-level per-task rescue" do
    test "a schema's raise past Scheduler's own rescue is caught+logged, and does not block another schema's poll_and_fire" do
      %{schema_name: broken_schema_name} = provisioned_tenant("iss0421-ac1-broken")
      drop_timers_fire_at_column!(broken_schema_name)

      %{schema_name: real_schema_name} = provisioned_tenant("iss0421-ac1-real")
      timer_id = due_timer_for!(real_schema_name, "iss0421-ac1")

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Must not crash the calling (test) process -- this is exactly
          # AC1's "a slow/erroring tenant doesn't block others" property,
          # for the crash sub-case specifically.
          assert {:noreply, _new_state} = Poller.handle_info(:tick, state)
        end)

      # The unrelated, healthy schema's own poll_and_fire was unaffected by
      # the broken schema's raise -- proves the fault's blast radius is
      # exactly one task, not the whole Task.async_stream batch.
      assert timer_status!(real_schema_name, timer_id) == "fired"

      # The new rescue's own log line (poller.ex's log_task_raise/4), not
      # Scheduler's "tenant schema unavailable" line -- proving this was
      # caught by the NEW poller-level rescue, not the pre-existing
      # Scheduler-level one.
      assert log =~ "poller sweep task raised"
      assert log =~ broken_schema_name
    end
  end

  # AC4 (preserved, unchanged by this fix -- design §5): `fetch_tenant_schemas/0`
  # is still called exactly once per `handle_info(:tick, state)` invocation, and
  # the resulting list is threaded, unqueried again, into all seven sweeps.
  describe "ISS-0421 AC4: tenant_schemas/0 is still queried exactly once per tick" do
    test "handle_info(:tick, state)'s source calls fetch_tenant_schemas() exactly once" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/scheduler/poller.ex"))

      [handle_info_body | _] =
        source
        |> String.split("def handle_info(:tick, state) do", parts: 2)
        |> Enum.reverse()

      # Cut off at the next top-level function definition so we don't also
      # count fetch_tenant_schemas/0's own (different) definition further
      # down the file.
      [handle_info_body | _] = String.split(handle_info_body, "\n  defp with_admission", parts: 2)

      occurrences =
        handle_info_body
        |> String.split("fetch_tenant_schemas()")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1,
             "expected handle_info(:tick, state) to call fetch_tenant_schemas() exactly once, " <>
               "found #{occurrences}"
    end
  end

  describe "no second ticker -- lib/letflow/scheduler/ has exactly one GenServer module" do
    test "lib/letflow/scheduler/ contains exactly one GenServer module (Poller) -- no second ticker" do
      root = File.cwd!()
      files = Path.wildcard(Path.join(root, "lib/letflow/scheduler/**/*.ex"))

      genserver_files =
        for path <- files,
            source = File.read!(path),
            source =~ ~r/use\s+GenServer/,
            do: path

      assert genserver_files == [Path.join(root, "lib/letflow/scheduler/poller.ex")]
    end
  end

  # ===================================================================================
  # ISS-0444 -- a tenant_schemas row whose PHYSICAL Postgres schema was never
  # created (or was dropped out-of-band) must not crash the whole tick. See
  # lib/letflow/design/iss0444-poller-schema-availability.md §1/§4/§6. This is
  # the "blast-radius" scenario: `tenant_schemas/0` (poller.ex) lists this row
  # exactly like any other provisioned schema (it only filters on
  # `migrations_applied_at` not being nil, matching
  # `lib/letflow/tenant_provisioning/backfill.ex`'s own documented "Registration
  # row exists but its physical schema no longer exists" case), so
  # `Scheduler.poll_and_fire/1`/`run_retention_sweep/1` are called against it
  # exactly as for any real schema -- pre-fix, this crashed the whole
  # `Enum.each` (and therefore `handle_info/2`) the moment the bad schema was
  # reached; post-fix, each is caught and logged at its own call site,
  # `Enum.each` continues, and every OTHER schema's own operations proceed
  # unaffected.
  #
  # A dedicated, real `Tenant`/`Registration` row pair is built directly here
  # (NOT `TenantFixture.provisioned_tenant!/1`, which always calls
  # `provision_tenant_schema/1` + `replay_migrations/2` -- this fixture
  # deliberately skips both, since the whole point is a Registration row with
  # NO physical `CREATE SCHEMA` ever run for it) -- teared down manually since
  # there is no physical schema for `TenantFixture`'s own teardown to `DROP
  # SCHEMA` against.
  # ===================================================================================

  defp registered_but_unprovisioned_schema_name! do
    # Matches `TenantFixture.provisioned_tenant!/1`'s own first line -- without
    # this, a bad-schema fixture built BEFORE any `provisioned_tenant/1` call
    # in the same test stays scoped to the DataCase's shared-mode transaction,
    # while `provisioned_tenant/1`'s own later `Sandbox.mode(Repo, :auto)`
    # call switches the connection this test's later queries actually use --
    # making the row invisible to `Poller.handle_info/2`'s own `tenant_schemas/0`
    # query. Idempotent to call from either ordering.
    Sandbox.mode(Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("iss0444-missing-schema"),
          display_name: "ISS-0444 missing-schema tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    %Registration{}
    |> Registration.changeset(%{
      tenant_id: tenant.id,
      schema_name: schema_name,
      migrations_applied_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    })
    |> Repo.insert!()

    on_exit(fn ->
      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    schema_name
  end

  describe "ISS-0444: a registered-but-physically-absent tenant schema does not crash the tick, either ordering" do
    test "bad schema registered BEFORE the real schema is provisioned -- real schema's timer still fires" do
      bad_schema_name = registered_but_unprovisioned_schema_name!()

      %{schema_name: real_schema_name} = provisioned_tenant("iss0444-order-a-real")
      timer_id = due_timer_for!(real_schema_name, "iss0444-order-a")

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, _new_state} = Poller.handle_info(:tick, state)
        end)

      assert timer_status!(real_schema_name, timer_id) == "fired"
      assert log =~ "tenant schema unavailable"
      assert log =~ bad_schema_name
    end

    test "bad schema registered AFTER the real schema is provisioned -- real schema's timer still fires" do
      %{schema_name: real_schema_name} = provisioned_tenant("iss0444-order-b-real")
      timer_id = due_timer_for!(real_schema_name, "iss0444-order-b")

      bad_schema_name = registered_but_unprovisioned_schema_name!()

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, _new_state} = Poller.handle_info(:tick, state)
        end)

      assert timer_status!(real_schema_name, timer_id) == "fired"
      assert log =~ "tenant schema unavailable"
      assert log =~ bad_schema_name
    end
  end

  describe "ISS-0444: the retention sweep for the same registered-but-absent schema does not crash the tick" do
    test "with retention enabled, the bad schema's sweep is skipped-and-logged while the real schema's own sweep still runs" do
      put_scheduler_config(retention_enabled: true, retention_interval_ms: 0, retention_days: 30)

      %{schema_name: real_schema_name} = provisioned_tenant("iss0444-retention-real")
      instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(real_schema_name, instance_id)

      old_created_at =
        DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:microsecond)

      seed_event!(real_schema_name, instance_id, old_created_at)

      bad_schema_name = registered_but_unprovisioned_schema_name!()

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, new_state} = Poller.handle_info(:tick, state)
          assert %DateTime{} = new_state.last_retention_run_at
        end)

      assert table_count(Event, real_schema_name) == 0
      assert table_count(ArchivedEvent, real_schema_name) == 1
      assert log =~ "tenant schema unavailable"
      assert log =~ "retention sweep"
      assert log =~ bad_schema_name
    end
  end

  describe "T-2950: no user-gate unit is consumed while the node is booting" do
    test "a tick during boot takes no admission unit and re-arms; after boot it sweeps" do
      AdmissionTestHelpers.restart_admission!(pool_size: 3, reserved_headroom: 2)
      %{schema_name: schema_name} = provisioned_tenant("t2950-boot")
      timer_id = due_timer_for!(schema_name, "t2950-boot")

      state = %{
        last_retention_run_at: nil,
        last_tick_started_at: nil,
        last_partition_maintenance_run_at: nil
      }

      on_exit(fn -> Letflow.BootReady.mark_done() end)
      Letflow.BootReady.begin()

      assert {:noreply, ^state} = Poller.handle_info(:tick, state)
      assert timer_status!(schema_name, timer_id) == "pending"
      assert_receive :tick, 2_000

      Letflow.BootReady.mark_done()
      assert {:noreply, _} = Poller.handle_info(:tick, state)
      assert timer_status!(schema_name, timer_id) == "fired"
    end
  end
end
