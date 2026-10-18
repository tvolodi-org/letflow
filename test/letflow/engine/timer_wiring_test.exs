defmodule Letflow.Engine.TimerWiringTest do
  @moduledoc """
  Tests for REQ-187's engine wiring of `:TIMER` nodes — arming on token
  arrival, firing via `Letflow.Scheduler`'s poll-and-fire path re-entering
  `Letflow.Engine`, and cancellation on instance completion/cancellation
  (SCH-01/SCH-03). See
  `handoffs/WF02-REQ187-20260829/step-03-test-designer.json`'s own
  acceptance-criteria list and `lib/letflow/design/req187-timer-engine-wiring.md`
  (the gate-approved design this file's tests verify against).

  Does NOT re-cover ground the 4 ELIXIR-DEV-updated test files already own:
  `test/letflow/engine/transition_test.exs`'s own `"transition/3 -- :TIMER
  entry/fired"` describe block already proves `dispatch_timer_arrival/3`'s
  pure `{:timer_armed, ...}` emission (not caught by the catch-all) and
  `dispatch_timer_fired/4`'s pure hop + defensive `:token_not_at_timer`
  error, so those pure-kernel cases are not repeated here.
  `test/letflow/engine/task_activation_test.exs`'s own `"cancel_pending_timers/5"`
  describe block already proves the function's `@doc` names SCH-03 and both
  call sites textually — explicitly deferring the real DB-level coverage of
  both call sites to `test/letflow/engine_test.exs` (its own moduledoc says
  so), which never actually landed that coverage; this file is that missing
  DB-level coverage. `test/letflow/scheduler_test.exs`/`scheduler/poller_test.exs`
  already cover the scheduler-side arm/claim/fire/retry machinery generically
  (including one already-armed-TIMER-node fixture) and REQ-186's own AC9
  route/controller structural scan — this file's own AC8 test below is a
  narrower, REQ-187-specific complement, not a duplicate.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database.
  `async: false`, matching every other tenant-fixture-using file in this
  codebase (real schema creation/teardown against one shared Postgres
  instance). `TIMER_FIRED`/`INSTANCE_STARTED`/`INSTANCE_CANCELLED` are all
  auto-seeded by `TenantFixture.provisioned_tenant!/1`'s own
  `replay_migrations/1` call (confirmed by `scheduler_test.exs`'s and
  `engine_cancel_instance_test.exs`'s own moduledocs — no manual event-type
  registration needed here).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TaskActivation
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req187-timerwiring") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-187 Timer Wiring Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("req187-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp base_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req187-start")
      },
      overrides
    )
  end

  defp cancel_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req187-cancel")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req187-complete")
      },
      overrides
    )
  end

  # START -> TIMER(duration) -> END.
  defp graph_timer_end(duration) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "tmr"},
        %{"id" => "e2", "source" => "tmr", "target" => "end"}
      ]
    }
  end

  # START -> TIMER(a) -> TIMER(b) -> END -- AC3's "edge leads directly into
  # another dispatch-needing node (:TIMER -> :TIMER)" case, resolved fully in
  # one advance_after_timer_fired/3 call once TIMER(a) fires.
  defp graph_timer_timer_end(duration_a, duration_b) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr_a",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration_a}
        },
        %{
          "id" => "tmr_b",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration_b}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "tmr_a"},
        %{"id" => "e2", "source" => "tmr_a", "target" => "tmr_b"},
        %{"id" => "e3", "source" => "tmr_b", "target" => "end"}
      ]
    }
  end

  # START -> TIMER -> HUMAN_TASK -> END -- firing leaves a real live token
  # parked at a HUMAN_TASK (instance stays :active), used by the
  # reconstruction-parity test and the "fired timer untouched by a later
  # cancellation" test.
  defp graph_timer_human_task_end(duration) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration}
        },
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "tmr"},
        %{"id" => "e2", "source" => "tmr", "target" => "task"},
        %{"id" => "e3", "source" => "task", "target" => "end"}
      ]
    }
  end

  # START -> PARALLEL_GATEWAY(split) -> TIMER(a) / TIMER(b) -> PARALLEL_GATEWAY(join) -> END.
  # Both TIMER branches structurally agree on the same join (walk_to_gateway/3
  # only needs each branch's own first edge target chain to reach it, not for
  # a token to actually traverse there) -- the split resolves entirely within
  # `create/2`'s own initial hop-chain, landing 2 separate live tokens on 2
  # distinct TIMER nodes in the SAME create/2 call, which is exactly
  # prepare_timer_arms/4's own >1-timer-armed guard scenario.
  defp graph_multi_timer_parallel do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "tmr_a",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{
          "id" => "tmr_b",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "tmr_a"},
        %{"id" => "e3", "source" => "split", "target" => "tmr_b"},
        %{"id" => "e4", "source" => "tmr_a", "target" => "join"},
        %{"id" => "e5", "source" => "tmr_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "end"}
      ]
    }
  end

  # START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / TIMER(b) -> PARALLEL_GATEWAY(join) -> END.
  # ISS-0397 timer-fire parity fixture (design doc §5.3): unlike
  # graph_multi_timer_parallel/0 above, only ONE branch is a :TIMER node, so
  # create/2's own single hop-chain arms exactly one pending timer (no
  # prepare_timer_arms/4 multi-timer guard involved) and leaves task_a
  # genuinely PENDING -- letting a real complete_task/3 call open the join
  # cohort and a real, separate advance_after_timer_fired/3 call (via
  # Scheduler.poll_and_fire/1) close it, exercising reconcile_projection/5's
  # shared write path and build_instance_state/3's shared read path from the
  # timer-fire side.
  defp graph_parallel_split_task_and_timer(duration) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_a"}
        },
        %{
          "id" => "tmr_b",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "tmr_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "tmr_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "end"}
      ]
    }
  end

  # ISS-0784 site 3 fixture -- START -> TIMER(duration) -> HUMAN_TASK(malformed
  # form_schema) -> END. Firing the timer (a system-driven cascade, no HTTP
  # request in scope) advances the hop chain straight into
  # `TaskActivation.append_multi_from_existing_records/7` for the HUMAN_TASK
  # node, which rejects the malformed `form_schema` -- surfacing at
  # `persist_timer_fired_advance/7`'s own inline
  # `{:error, _failed_step, reason, _changes} -> ...` clause (design §2 row 3),
  # the one call site that sources `actor_id` from
  # `EventStore.platform_actor_id()` rather than any real user's `actor_id`.
  defp graph_timer_then_malformed_form_schema_task_end(duration, form_schema) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration}
        },
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver", "form_schema" => form_schema}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "tmr"},
        %{"id" => "e2", "source" => "tmr", "target" => "task"},
        %{"id" => "e3", "source" => "task", "target" => "end"}
      ]
    }
  end

  # ISS-0981 site 5 fixture -- START -> orig-task (HUMAN_TASK, escalation
  # timer armed via escalation_timer_duration) -> escalated-task (HUMAN_TASK,
  # well-formed -- no form_schema attribute) -> END. No escalation-timer
  # graph helper already existed in this file (searched -- confirmed absent),
  # so this one is added locally, mirroring
  # `test/letflow/engine/human_task_escalation_test.exs`'s own
  # `escalation_graph/0` fixture, per this project's established
  # per-test-file self-sufficiency convention.
  defp graph_escalation_timer_human_task_end(duration) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "orig-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => "approver",
            "escalation_timer_duration" => duration,
            "escalation_role" => "role-escalation"
          }
        },
        %{
          "id" => "escalated-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "role-escalation"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "orig-task"},
        %{"id" => "e2", "source" => "orig-task", "target" => "escalated-task"},
        %{"id" => "e3", "source" => "escalated-task", "target" => "end"}
      ]
    }
  end

  defp timers_for(schema_name, instance_id) do
    Timer
    |> where([t], t.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp timer_count(schema_name) do
    Repo.aggregate(Timer, :count, prefix: schema_name)
  end

  defp fired_events_for(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "TIMER_FIRED")
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1/AC7 -- arming on arrival: exactly one pending timers row,
  # fire_at = arrival + parsed duration.
  # ---------------------------------------------------------------------------------

  describe "AC1: a token reaching a valid :TIMER node arms exactly one pending timers row" do
    test "a date-part duration (P1D) arms fire_at = arrival + 86400s" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))

      before_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      after_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert [timer] = timers_for(schema_name, result.instance_id)
      assert timer.status == "pending"
      assert timer.node_id == "tmr"
      assert timer.timer_type == "deadline"

      assert DateTime.compare(timer.fire_at, DateTime.add(before_create, 86_400, :second)) != :lt
      assert DateTime.compare(timer.fire_at, DateTime.add(after_create, 86_400, :second)) != :gt
    end

    test "a time-part duration (PT1H) arms fire_at = arrival + 3600s" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("PT1H"))

      before_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      after_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert [timer] = timers_for(schema_name, result.instance_id)
      assert timer.status == "pending"

      assert DateTime.compare(timer.fire_at, DateTime.add(before_create, 3_600, :second)) != :lt
      assert DateTime.compare(timer.fire_at, DateTime.add(after_create, 3_600, :second)) != :gt
    end

    test "the P0D edge case arms fire_at == arrival (zero-second offset)" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P0D"))

      before_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      after_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert [timer] = timers_for(schema_name, result.instance_id)
      assert timer.status == "pending"

      assert DateTime.compare(timer.fire_at, before_create) != :lt
      assert DateTime.compare(timer.fire_at, after_create) != :gt
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- the timer row and the state-transition event are written in ONE
  # transaction: forcing the event append to fail leaves NO timers row
  # behind. Reuses the exact "missing :actor_id fails EventStore.append/2's
  # own event-append step" forced-failure technique
  # `test/letflow/engine_test.exs`'s own REQ-047 AC2 test already established.
  # ---------------------------------------------------------------------------------

  describe "AC2: timer arm + state-transition event are in one transaction" do
    test "missing :actor_id fails the event append and leaves zero timers rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))

      attrs = base_attrs(definition) |> Map.delete(:actor_id)

      assert {:error, {:event_append_failed, :missing_actor_id}} =
               Engine.create(attrs, prefix: schema_name)

      assert timer_count(schema_name) == 0
      assert Repo.aggregate(InstanceProjection, :count, prefix: schema_name) == 0
      assert Repo.aggregate(TokenRecord, :count, prefix: schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- firing advances the token off the TIMER node along its outgoing
  # edge, including a chain into another dispatch-needing :TIMER node,
  # resolved fully in one advance_after_timer_fired/3 call.
  # ---------------------------------------------------------------------------------

  describe "AC3: firing a due timer via Scheduler.poll_and_fire/1 advances the token" do
    test "TIMER -> END: the instance completes and the token is no longer at the TIMER node" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P0D"))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"}] = timers_for(schema_name, instance_id)

      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      assert [%Timer{status: "fired"}] = timers_for(schema_name, instance_id)
      assert [event] = fired_events_for(schema_name, instance_id)
      assert event.payload["node_id"] == "tmr"

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :completed

      [token_record] = Repo.all(TokenRecord, prefix: schema_name)
      assert token_record.status == :completed
    end

    test "TIMER -> TIMER -> END: firing the first arms a NEW pending timer for the second, in the same call" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_timer_end("P0D", "PT1H"))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{node_id: "tmr_a", status: "pending"}] = timers_for(schema_name, instance_id)

      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      timers = timers_for(schema_name, instance_id) |> Enum.sort_by(& &1.node_id)

      assert [
               %Timer{node_id: "tmr_a", status: "fired"} = fired_a,
               %Timer{node_id: "tmr_b", status: "pending"} = pending_b
             ] =
               timers

      # AC1's own fire_at = arrival + duration contract holds for the
      # second, re-armed timer too -- arrival here is fired_a's own
      # fired_at (advance_after_timer_fired/3's "now", design doc §8.4).
      assert DateTime.compare(pending_b.fire_at, DateTime.add(fired_a.fired_at, 3_600, :second)) !=
               :lt

      # Instance stays :active -- the live token is parked at tmr_b, not
      # completed, and NOT at tmr_a any more.
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active

      [token_record] = Repo.all(TokenRecord, prefix: schema_name)
      assert token_record.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- completing an instance cancels every PENDING timer via the
  # unmoved cancel_pending_timers/5 call site (finalize_instance_projection/5's
  # :completed clause). Per the design doc's own §5.2 scope note, a
  # :TIMER-parked token structurally prevents create/2's own single hop-chain
  # from EVER reaching :completed while a sibling timer is still pending --
  # this call site is real, unmoved production code that is, by the design's
  # own admission, unreachable via ordinary flow. So this test exercises the
  # exact mechanism that call site depends on (cancel_pending_timers/5 with
  # its "instance_completed" reason, real DB, real prod function) directly,
  # plus a source-text check that the call site itself still invokes it,
  # unmoved, immediately after the instance_projections row flips to
  # :completed -- matching engine_cancel_instance_test.exs's own precedent
  # for a "force the state directly, this scenario isn't reachable via a
  # public Engine call" fixture (its AC2 third test).
  # ---------------------------------------------------------------------------------

  describe "AC4: completing an instance cancels its pending timers via cancel_pending_timers/5" do
    test "cancel_pending_timers/5 with reason instance_completed cancels a real pending timer" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"} = timer] = timers_for(schema_name, instance_id)

      completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, 1} =
               TaskActivation.cancel_pending_timers(
                 Repo,
                 instance_id,
                 completed_at,
                 "instance_completed",
                 schema_name
               )

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "cancelled"
      assert reloaded.cancelled_at == completed_at
      assert reloaded.cancel_reason == "instance_completed"
    end

    test "finalize_instance_projection/5's :completed clause still calls it, unmoved, right after the projection update" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/engine.ex"))

      # Isolate the :completed clause's own body (the 2nd defp
      # finalize_instance_projection/5 clause, up to the next defp) so this
      # check can't accidentally match some unrelated call elsewhere in the
      # file.
      [_before, clause_and_rest] =
        String.split(source, "defp finalize_instance_projection(\n         repo,", parts: 2)

      [clause_body, _rest] = String.split(clause_and_rest, "\n  defp unique_violation?", parts: 2)

      assert clause_body =~ ~r/repo\.update\(prefix: prefix\)/
      assert clause_body =~ "TaskActivation.cancel_pending_timers("
      assert clause_body =~ ~s("instance_completed")

      # Ordering: the update call textually precedes the cancellation call
      # (call site "unmoved" -- immediately after the projection flips).
      update_index = :binary.match(clause_body, "repo.update(prefix: prefix)") |> elem(0)

      cancel_index =
        :binary.match(clause_body, "TaskActivation.cancel_pending_timers(") |> elem(0)

      assert update_index < cancel_index
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- cancel_instance/3 cancels PENDING timers in the same transaction;
  # forcing that transaction to roll back leaves timers still pending.
  # ---------------------------------------------------------------------------------

  describe "AC5: cancel_instance/3 cancels pending timers in the same transaction" do
    test "an ordinary cancel_instance/3 call cancels the instance's pending timer with reason instance_cancelled" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"} = timer] = timers_for(schema_name, instance_id)

      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "cancelled"
      assert reloaded.cancel_reason == "instance_cancelled"
      assert reloaded.cancelled_at != nil
    end

    test "forcing the :event step to fail (idempotency_key too long) rolls back :timer_cancellations too" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"} = timer] = timers_for(schema_name, instance_id)

      # EventStore.append/2's own fetch_idempotency_key/1 pre-transaction
      # check rejects a key over 255 chars with :idempotency_key_too_long --
      # cancel_instance/3's own pre-transaction phase (fetch_actor_and_idempotency_key/1)
      # only checks for nil/presence, not length, so this reaches
      # append_instance_cancelled_event/5's own EventStore.append/2 call
      # (the :event Multi step) and fails it there, inside the already-open
      # Multi -- exactly the same class of forced-:event-failure this
      # codebase's own REQ-047 AC2 test (engine_test.exs) established,
      # adapted for a validation cancel_instance/3's own pre-check doesn't
      # already catch.
      too_long_key = String.duplicate("x", 256)

      assert {:error, {:event_append_failed, :idempotency_key_too_long}} =
               Engine.cancel_instance(
                 instance_id,
                 cancel_attrs(%{idempotency_key: too_long_key}),
                 prefix: schema_name
               )

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "pending"
      assert reloaded.cancelled_at == nil
      assert reloaded.cancel_reason == nil

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end

    test "cancel_multi/5's own Multi places :timer_cancellations after :open_tasks_recheck and before :task_cancellations" do
      # GH #2707 (decision 0061, "Amended (GH #2707, PR-1)"): timer rows are P-protected, so the
      # cancel's timer UPDATE runs AFTER the instance projection, the ancestor group and the open
      # tasks re-read, immediately before :task_cancellations -- the order
      # Scheduler.fire_timer/2 has (P_x before the timer row). Flipped from REQ-187 design doc
      # §6.1-§6.2 (which put it before :instance_projection). A single-process test cannot
      # observe a deadlock, so this is a structural/source-position check; the forced-overlap
      # behaviour is in test/letflow/scheduler_fire_lock_order_test.exs (F4, F8).
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/engine.ex"))

      [_before, body] = String.split(source, "defp cancel_multi(", parts: 2)

      [multi_body, _rest] =
        String.split(body, "\n  # REQ-195 -- cancel_instance/3's own", parts: 2)

      index = fn needle -> :binary.match(multi_body, needle) |> elem(0) end

      open_tasks_index = index.("Multi.run(:open_tasks,")
      instance_projection_index = index.("Multi.run(:instance_projection,")
      lock_ancestors_index = index.("Multi.run(:lock_ancestors,")
      recheck_index = index.("Multi.run(:open_tasks_recheck,")
      timer_cancellations_index = index.("Multi.run(:timer_cancellations,")
      task_cancellations_index = index.("Multi.run(:task_cancellations,")

      assert open_tasks_index < instance_projection_index
      assert instance_projection_index < timer_cancellations_index
      assert lock_ancestors_index < timer_cancellations_index
      assert recheck_index < timer_cancellations_index
      assert timer_cancellations_index < task_cancellations_index

      # adjacent: nothing else sits between the re-read and the timer step, or between the timer
      # step and the task cancellations
      steps =
        Regex.scan(~r/Multi\.run\(:([a-z_]+),/, multi_body, capture: :all_but_first)
        |> List.flatten()

      assert Enum.chunk_every(steps, 3, 1, :discard)
             |> Enum.any?(
               &(&1 == ["open_tasks_recheck", "timer_cancellations", "task_cancellations"])
             )
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 (SCH-03) -- a 'fired' timer is never mutated by a later cancellation;
  # no 'pending' timer of a terminal instance is later fired.
  # ---------------------------------------------------------------------------------

  describe "AC6 (SCH-03): a fired timer is never touched by a later cancellation" do
    test "TIMER -> HUMAN_TASK -> END: firing the timer then cancelling the instance leaves the fired row untouched" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_human_task_end("P0D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      [fired_timer] = timers_for(schema_name, instance_id)
      assert fired_timer.status == "fired"

      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      reloaded = Repo.get!(Timer, fired_timer.id, prefix: schema_name)
      assert reloaded.status == "fired"
      assert reloaded.cancelled_at == nil
      assert reloaded.cancel_reason == nil
    end
  end

  describe "AC6 (SCH-03): no pending timer of a terminal instance is ever fired by a later poll" do
    test "cancelling the instance first, then attempting to fire its (now-cancelled) timer directly, is a no-op" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P0D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"} = timer] = timers_for(schema_name, instance_id)

      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      cancelled_timer = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert cancelled_timer.status == "cancelled"

      # A deterministic stand-in for the concurrency race (design doc §10):
      # by the time ANY poll could reach this timer_id, cancel_instance/3's
      # own transaction has already committed the "cancelled" status --
      # fire_timer/2's own status-guard (`status != "pending" -> :already_final`)
      # is what actually prevents it from ever firing.
      assert {:ok, :already_final} = Scheduler.fire_timer(timer.id, schema_name)

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "cancelled"
      assert fired_events_for(schema_name, instance_id) == []

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :cancelled
    end
  end

  # ---------------------------------------------------------------------------------
  # Multi-timer-in-one-hop-chain guard (REVIEWER's own new item) -- a
  # PARALLEL_GATEWAY split landing two branches on distinct TIMER nodes in
  # one hop-chain surfaces prepare_timer_arms/4's typed error, not a crash
  # (Ecto.Multi would otherwise raise on the duplicate :scheduler_timer step
  # name).
  # ---------------------------------------------------------------------------------

  describe "multi-timer-in-one-hop-chain guard" do
    test "a PARALLEL_GATEWAY split arming two TIMER nodes at once returns a typed error, never raises" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_multi_timer_parallel())

      result =
        try do
          Engine.create(base_attrs(definition), prefix: schema_name)
        rescue
          exception -> {:raised, exception}
        end

      assert {:error, {:multiple_timers_in_one_hop_chain_not_supported, node_ids}} = result
      assert Enum.sort(node_ids) == ["tmr_a", "tmr_b"]

      # Nothing committed -- the whole create/2 attempt aborted before any
      # Multi ever opened (prepare_timer_arms/4 runs in start_instance/5's
      # own pre-Multi `with` chain).
      assert timer_count(schema_name) == 0
      assert Repo.aggregate(InstanceProjection, :count, prefix: schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # transition.ex purity (AC7) -- re-exercises the module's own documented
  # grep command as a standing ExUnit check, since neither
  # transition_test.exs nor any other file in this tree currently wires it
  # into a runnable test (test/specs/REQ-044.md treats it as code-inspection
  # evidence only).
  # ---------------------------------------------------------------------------------

  describe "AC7: transition.ex (+ its 2 pure siblings) gain no Repo/clock call" do
    test "the moduledoc's own grep command returns zero matches" do
      paths =
        ~w(lib/letflow/engine/instance_state.ex lib/letflow/engine/token.ex lib/letflow/engine/transition.ex)

      pattern =
        ~r/Repo\.|Logger\.|DateTime\.|System\.os_time|System\.system_time|HTTPoison|Req\.|File\.|:rand\.|:crypto\./

      # Strips each file's own leading @moduledoc heredoc before scanning --
      # transition.ex's own moduledoc quotes this exact grep command
      # (including the literal string "Logger.") as documentation, which
      # would otherwise self-trigger this check on the doc text rather than
      # on real code.
      strip_moduledoc = fn source ->
        Regex.replace(~r/@moduledoc\s+""".*?"""/s, source, "", global: false)
      end

      offending =
        for path <- paths,
            source = File.read!(Path.join(File.cwd!(), path)) |> strip_moduledoc.(),
            String.match?(source, pattern),
            do: {path, Regex.run(pattern, source)}

      assert offending == [],
             "expected zero Repo/Logger/DateTime/clock/HTTP/File/rand/crypto references in " <>
               "the pure transition kernel, found: #{inspect(offending)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- no route/controller/migration/web/ file needed to add this
  # coverage. scheduler_test.exs's own AC9 already runs the broader
  # lib/letflow/api/**, lib/letflow/routers/**, web/src/** wildcard scan for
  # "Letflow.Scheduler"/"timers" references (REQ-186's own scope) -- this is
  # the narrower, REQ-187-specific complement: none of the 6 files this
  # requirement actually touched are themselves route/controller-shaped, and
  # no route file references this requirement's own new engine-level names.
  # ---------------------------------------------------------------------------------

  describe "AC8: no route/controller construct added or touched by REQ-187" do
    @req187_files ~w(
      lib/letflow/engine/transition.ex
      lib/letflow/definitions/graph.ex
      lib/letflow/engine.ex
      lib/letflow/engine/task_activation.ex
      lib/letflow/scheduler.ex
      lib/letflow/engine/reconstruction.ex
    )

    test "none of the 6 files REQ-187 touched are Plug.Router/controller-shaped" do
      for path <- @req187_files do
        source = File.read!(Path.join(File.cwd!(), path))
        refute source =~ ~r/use\s+Plug\.Router/, "#{path} unexpectedly uses Plug.Router"
        refute source =~ ~r/use\s+\w*Web,\s*:controller/, "#{path} unexpectedly is a controller"
        refute source =~ ~r/\bget\s+"\//, "#{path} unexpectedly defines a route"
      end
    end

    test "no file under lib/letflow/api/ or lib/letflow/routers/ references advance_after_timer_fired or TIMER_FIRED" do
      root = File.cwd!()

      candidate_paths =
        ["lib/letflow/api/**/*.ex", "lib/letflow/routers/**/*.ex"]
        |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))

      offending =
        for path <- candidate_paths,
            source = File.read!(path),
            source =~ ~r/advance_after_timer_fired|TIMER_FIRED|timer_armed|timer_fired/,
            do: path

      assert offending == [],
             "expected no route/controller file to reference REQ-187's new engine-level " <>
               "names, found: #{inspect(offending)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Reconstruction -- replaying a persisted TIMER_FIRED event reproduces the
  # same post-fire InstanceState the live advance_after_timer_fired/3 path
  # produces, independently (the two never call each other -- design doc §9).
  # ---------------------------------------------------------------------------------

  describe "Reconstruction.reconstruct_instance/2 replays TIMER_FIRED to the same post-fire state" do
    test "the live token's post-fire node_id/status matches a pure replay from the event log" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_human_task_end("P0D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      [live_token] = Repo.all(TokenRecord, prefix: schema_name)
      assert live_token.node_id == "task"
      assert live_token.status == :active

      assert {:ok, %{instance_state: replayed}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert replayed.status == :active
      assert [replayed_token] = replayed.tokens
      assert replayed_token.node_id == "task"
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0397 -- join_counters persistence parity between complete_task/3 and
  # advance_after_timer_fired/3 (design doc
  # lib/letflow/design/iss0397-join-counters-fix.md §5.3). Both call
  # reconcile_projection/5 (M10) and build_instance_state/3 (M3), so a cohort
  # opened by a real, separate complete_task/3 call must be durably readable
  # (and closeable) by a real, separate advance_after_timer_fired/3 call --
  # the exact cross-call shape the pre-fix hardcoded `join_counters: %{}`
  # broke.
  # ---------------------------------------------------------------------------------

  describe "ISS-0397: a join cohort opened by complete_task/3 is durably closed by advance_after_timer_fired/3" do
    test "task branch completes first (separate call), timer branch fires (separate call), join fires exactly once" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_parallel_split_task_and_timer("P0D"))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      [task_a] = Repo.all(EngineTask, prefix: schema_name)
      assert task_a.node_id == "task_a"
      assert task_a.status == :pending

      assert [%Timer{node_id: "tmr_b", status: "pending"}] =
               timers_for(schema_name, instance_id)

      # First, separate call: completes the HUMAN_TASK branch. The join has
      # not fired yet (one branch still outstanding on the TIMER side) --
      # the instance stays :active, and the cohort's `received_from_branches`
      # entry for this branch must be durably persisted on
      # instance_projections.join_counters (ISS-0397 fix), not merely held
      # in this call's own in-memory InstanceState.
      assert {:ok, complete_result} =
               Engine.complete_task(task_a.id, complete_attrs(), prefix: schema_name)

      assert complete_result.instance_status == :active

      projection_after_task = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection_after_task.status == :active
      assert map_size(projection_after_task.join_counters) == 1
      [{_join_node_id, cohort_after_task}] = Map.to_list(projection_after_task.join_counters)
      assert cohort_after_task["received_from_branches"] != []

      # Second, separate call: the TIMER branch fires via Scheduler's real
      # poll-and-fire path, re-entering advance_after_timer_fired/3. Before
      # the ISS-0397 fix, build_instance_state/3 hardcoded `join_counters:
      # %{}` here, so this call's own dispatch would never find the cohort
      # the first call opened -- `dispatch_parallel_join/4`'s
      # `{:error, {:unknown_branch_id, _}}` guard. With the fix, this call
      # reads the same durably-persisted cohort and the join fires.
      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      final_projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert final_projection.status == :completed
      assert final_projection.join_counters == %{}

      final_tasks = Repo.all(EngineTask, prefix: schema_name)
      assert [%EngineTask{status: :completed}] = final_tasks

      [final_timer] = timers_for(schema_name, instance_id)
      assert final_timer.status == "fired"
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0784 site 3 -- persist_timer_fired_advance/7's inline
  # `{:error, _failed_step, reason, _changes}` clause (design §2 row 3). This
  # is the gap REVIEWER explicitly flagged: neither shipped test (both live
  # in engine_test.exs's "create/2 (ISS-0784)" describe block) exercises the
  # `EventStore.platform_actor_id()` sourcing for `actor_id` -- both shipped
  # tests only cover create/2's real-user-actor_id path (design §2 row 1).
  # This describe block closes that gap directly: a timer fire is a
  # system-driven cascade with no real requesting actor in scope, so
  # asserting the resulting audit entry's actor_id equals
  # `EventStore.platform_actor_id()` verbatim is the whole point.
  # ---------------------------------------------------------------------------------

  describe "ISS-0784 site 3: a timer-fired cascade's task-activation rejection is audited with the platform actor_id" do
    test "TIMER fires into a HUMAN_TASK with a malformed form_schema; the audit entry's actor_id is EventStore.platform_actor_id()" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_timer_then_malformed_form_schema_task_end(
            "P0D",
            %{"properties" => "not-an-object"}
          )
        )

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"}] = timers_for(schema_name, instance_id)

      # Scheduler.poll_and_fire/1 re-enters advance_after_timer_fired/3 ->
      # persist_timer_fired_advance/7, entirely inside the scheduler's own
      # process -- no real user actor_id is ever in scope on this path,
      # which is exactly why this call site (design §2 row 3) sources
      # actor_id from EventStore.platform_actor_id() instead.
      #
      # This is NOT a "fired" outcome: persist_timer_fired_advance/7 returns
      # {:error, {:invalid_form_schema, ...}}, which attempt_fire/2 (scheduler.ex,
      # ISS-303/ISS-0618 failure accounting) routes through the generic
      # `{:error, _reason} -> safe_record_fire_failure/2` clause (not an
      # `:already_final` outcome: since GH #2707 fire_timer/2 returns
      # `{:ok, :already_final}` for a timer of a dead instance, settling its timers,
      # and the former `{:instance_not_active, _}` special case is only a defensive
      # clause for a status change after the lock prelude -- impossible while it holds `P_x`),
      # incrementing the timer's own fire_error_count in a SEPARATE, later
      # transaction and reporting :errored back to poll_and_fire/1's tally --
      # confirmed by first running this assertion as `%{fired: 1}` (this
      # session's own mutation-style check, not asserted from documentation).
      assert %{errored: 1, fired: 0} = Scheduler.poll_and_fire(schema_name)

      # INV-ISS0784-2 -- the rolled-back attempt's own rows never reappear:
      # no HUMAN_TASK "task" row was ever committed, and the timer itself
      # (armed before the rejection, in a separate already-committed
      # transaction) stays "pending", not "fired" -- persist_timer_fired_advance/7's
      # own transaction (which would have flipped it) rolled back whole.
      refute Enum.any?(Repo.all(EngineTask, prefix: schema_name), &(&1.node_id == "task"))
      assert [%Timer{status: "pending"}] = timers_for(schema_name, instance_id)

      assert [entry] =
               Enum.filter(
                 Repo.all(Audit.Entry, prefix: schema_name),
                 &(&1.action == "task_activation.rejected")
               )

      assert entry.resource_type == "instance"
      assert entry.resource_id == instance_id
      # The genuinely distinct assertion this test exists for (REVIEWER's
      # flagged gap): a system-driven cascade's actor_id is the platform
      # actor, not any real user's actor_id -- no user-supplied actor_id was
      # ever passed into this call at all.
      assert entry.actor_id == EventStore.platform_actor_id()
      assert entry.before_state == nil
      assert entry.after_state["node_id"] == "task"

      assert entry.after_state["reason"] == %{
               "code" => "not_well_formed",
               "path" => ["properties"]
             }
    end
  end

  describe "ISS-0969: poll_and_fire/1 does not raise when the task-activation-rejection audit write itself fails" do
    test "a timer-fired cascade whose form_schema rejection AND audit write both fail still returns a well-formed poll_result" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_timer_then_malformed_form_schema_task_end(
            "P0D",
            %{"properties" => "not-an-object"}
          )
        )

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"}] = timers_for(schema_name, instance_id)

      # Make the task-activation-rejection audit write itself raise (a
      # genuine Postgres-level failure, not just a changeset-validation
      # {:error, _}), so this test exercises the actual bug ISS-0969 traced:
      # without the rescue clause, this raise would propagate out of
      # attempt_fire/2 and abort poll_and_fire/1's entire Enum.reduce/3
      # loop, not just this one timer.
      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Does NOT raise out of the test process -- poll_and_fire/1's own
          # "Never raises" @doc contract (scheduler.ex:203-207) now holds for
          # this path too.
          assert %{errored: 1, fired: 0} = Scheduler.poll_and_fire(schema_name)
        end)

      assert log =~ "task_activation.rejected"
    end
  end

  describe "ISS-0981: persist_timer_fired_advance/7's task-activation audit raise is rescue-hardened" do
    test "a timer-fired cascade whose task-activation audit write itself fails returns a well-formed poll_result, not a raise" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = active_definition!(schema_name, graph_timer_human_task_end("P0D"))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"}] = timers_for(schema_name, instance_id)

      # Deliberately well-formed form_schema (none at all here) -- unlike
      # "ISS-0784 site 3"/"ISS-0969" above, this test needs the timer-fire
      # cascade to reach TaskActivation.append_multi_from_existing_records/6's
      # own SUCCESSFUL insert path (record_task_create_audit/3's
      # same-transaction Audit.insert_entry/3 call), not the
      # {:invalid_form_schema, _} rejection branch those sibling tests
      # exercise.
      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      # persist_timer_fired_advance/7 is now rescue-hardened (ISS-0981) --
      # the raise from the dropped audit_entries table converts to
      # {:error, {:transaction_failed, exception}}, which Scheduler's own
      # generic-error accounting tallies the same as any other typed error
      # (same %{errored: _, fired: _} idiom the "ISS-0969"/"ISS-0784 site 3"
      # describe blocks above already assert).
      assert %{errored: 1, fired: 0} = Scheduler.poll_and_fire(schema_name)

      # The whole nested transaction rolled back: no HUMAN_TASK "task" row
      # ever committed, and the timer itself is still "pending", not "fired".
      refute Enum.any?(Repo.all(EngineTask, prefix: schema_name), &(&1.node_id == "task"))
      assert [%Timer{status: "pending"}] = timers_for(schema_name, instance_id)
    end
  end

  describe "ISS-0981: persist_escalation_timer_fired_advance/7's task-activation audit raise is rescue-hardened" do
    test "an escalation-timer-fired cascade whose task-activation audit write itself fails returns a well-formed poll_result, not a raise" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = active_definition!(schema_name, graph_escalation_timer_human_task_end("P0D"))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending", timer_type: "escalation"}] =
               timers_for(schema_name, instance_id)

      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      assert %{errored: 1, fired: 0} = Scheduler.poll_and_fire(schema_name)

      # The whole nested transaction rolled back: the original task is still
      # pending (never cancelled), no new escalated-task row ever committed,
      # and the escalation timer itself is still "pending", not "fired".
      refute Enum.any?(
               Repo.all(EngineTask, prefix: schema_name),
               &(&1.node_id == "escalated-task")
             )

      assert [%EngineTask{node_id: "orig-task", status: :pending}] =
               Repo.all(EngineTask, prefix: schema_name)

      assert [%Timer{status: "pending"}] = timers_for(schema_name, instance_id)
    end
  end
end
