defmodule Letflow.Engine.Req494HumanTaskReminderTimerTest do
  @moduledoc """
  REQ-494 / GH #2325: opt-in, non-cancelling HUMAN_TASK reminder timer.

  Design and test matrix: `lib/letflow/design/req494-human-task-reminder-timer.md`
  section 9 (T-01..T-08b here; CHK-28 in
  `test/letflow/definitions/reminder_validation_test.exs`; advance-timer in
  `test/letflow/routers/instances_req494_advance_timer_test.exs`; RoleBinding in
  `test/letflow/definitions/role_binding_test.exs`). Spec: `test/specs/REQ-494.md`.

  Every assertion is on caller-visible return values and on DB rows (`timers`,
  `tasks`, `tokens`, `instance_projections`, `events`, `audit_entries`,
  `dlq_entries`), never on internal outcome tags. Timers are fired directly via
  `Scheduler.fire_timer/2` (or the public `Scheduler.attempt_fire/2` where the DLQ
  path matters), so nothing depends on wall-clock `fire_at`.

  Real Postgres, `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Node fixtures (separate helpers, no optional arguments -- ISS-0069)
  # ---------------------------------------------------------------------------------

  defp ht(id), do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r"}}

  defp ht_with(id, extra),
    do: %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => Map.merge(%{"role" => "r"}, extra)
    }

  defp rem_attrs(dur), do: %{"reminder_timer_duration" => dur, "reminder_role" => "r-remind"}

  defp esc_attrs(dur),
    do: %{"escalation_timer_duration" => dur, "escalation_role" => "r-escalated"}

  defp ht_rem(id, dur), do: ht_with(id, rem_attrs(dur))

  defp ht_esc(id, edur), do: ht_with(id, esc_attrs(edur))

  defp ht_rem_rep(id, dur, interval, count) do
    ht_with(
      id,
      Map.merge(rem_attrs(dur), %{
        "reminder_repeat_interval" => interval,
        "reminder_repeat_count" => count
      })
    )
  end

  defp ht_rem_rep_no_count(id, dur, interval),
    do: ht_with(id, Map.put(rem_attrs(dur), "reminder_repeat_interval", interval))

  defp ht_rem_esc(id, rdur, edur), do: ht_with(id, Map.merge(rem_attrs(rdur), esc_attrs(edur)))

  defp ht_rem_rep_no_count_esc(id, rdur, interval, edur) do
    ht_with(
      id,
      rem_attrs(rdur)
      |> Map.put("reminder_repeat_interval", interval)
      |> Map.merge(esc_attrs(edur))
    )
  end

  defp gw(id), do: %{"id" => id, "node_type" => "EXCLUSIVE_GATEWAY"}
  defp par(id), do: %{"id" => id, "node_type" => "PARALLEL_GATEWAY"}

  defp timer_node(id),
    do: %{"id" => id, "node_type" => "TIMER", "attributes" => %{"duration_iso8601" => "PT1H"}}

  defp start_node, do: %{"id" => "start", "node_type" => "START"}
  defp end_node, do: %{"id" => "end", "node_type" => "END"}
  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp cond_edge(id, source, target, condition),
    do: %{"id" => id, "source" => source, "target" => target, "condition" => condition}

  defp default_edge(id, source, target),
    do: %{"id" => id, "source" => source, "target" => target, "is_default" => true}

  # ---------------------------------------------------------------------------------
  # Graph fixtures
  # ---------------------------------------------------------------------------------

  # start -> a -> b -> end (the instance stays active after a completes)
  defp g_ab(a_node, b_node) do
    %{
      "nodes" => [start_node(), a_node, b_node, end_node()],
      "edges" => [edge("e1", "start", "a"), edge("e2", "a", "b"), edge("e3", "b", "end")]
    }
  end

  # gh2359 direct_graph/1: start -> a -> gw ; gw -[approved==true]-> end ; gw -[default]-> a
  defp g_loop(a_node) do
    %{
      "nodes" => [start_node(), a_node, gw("gw"), end_node()],
      "edges" => [
        edge("e1", "start", "a"),
        edge("e2", "a", "gw"),
        cond_edge("e3", "gw", "end", "variables.approved == true"),
        default_edge("e4", "gw", "a")
      ]
    }
  end

  # start -> t (TIMER PT1H) -> a -> end
  defp g_timer(a_node) do
    %{
      "nodes" => [start_node(), timer_node("t"), a_node, end_node()],
      "edges" => [edge("e1", "start", "t"), edge("e2", "t", "a"), edge("e3", "a", "end")]
    }
  end

  # start -> split ; split -> a ; split -> c ; a -> join ; c -> join ; join -> end
  defp g_parallel(a_node, c_node) do
    %{
      "nodes" => [start_node(), par("split"), a_node, c_node, par("join"), end_node()],
      "edges" => [
        edge("e1", "start", "split"),
        edge("e2", "split", "a"),
        edge("e3", "split", "c"),
        edge("e4", "a", "join"),
        edge("e5", "c", "join"),
        edge("e6", "join", "end")
      ]
    }
  end

  # ---------------------------------------------------------------------------------
  # Case / row helpers (copied from gh2359_gateway_reentry_task_row_test.exs)
  # ---------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp tenant_schema! do
    %{schema_name: schema} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req494",
        display_name: "REQ-494 Test Tenant"
      )

    schema
  end

  defp activate!(schema, graph) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: unique("req494-def"),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema)
    activated
  end

  defp start_in!(schema, graph, initial_variables) do
    definition = activate!(schema, graph)

    {:ok, created} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: initial_variables,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("req494-start")
        },
        prefix: schema
      )

    %{schema_name: schema, instance_id: created.instance_id}
  end

  defp new_case!(graph, initial_variables),
    do: start_in!(tenant_schema!(), graph, initial_variables)

  defp tasks_at(ctx, node_id) do
    EngineTask
    |> where([t], t.instance_id == ^ctx.instance_id and t.node_id == ^node_id)
    |> order_by([t], asc: t.inserted_at, asc: t.id)
    |> Repo.all(prefix: ctx.schema_name)
  end

  defp all_tasks(ctx) do
    EngineTask
    |> where([t], t.instance_id == ^ctx.instance_id)
    |> Repo.all(prefix: ctx.schema_name)
  end

  defp pending(rows), do: Enum.filter(rows, &(&1.status == :pending))

  defp reload_task!(ctx, task), do: Repo.get!(EngineTask, task.id, prefix: ctx.schema_name)

  defp reload_timer!(ctx, timer), do: Repo.get!(Timer, timer.id, prefix: ctx.schema_name)

  defp complete(ctx, task, output) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: output,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique("req494-complete")
      },
      prefix: ctx.schema_name
    )
  end

  defp projection!(ctx),
    do: Repo.get!(InstanceProjection, ctx.instance_id, prefix: ctx.schema_name)

  defp tokens(ctx) do
    from(t in TokenRecord, where: t.instance_id == ^ctx.instance_id)
    |> Repo.all(prefix: ctx.schema_name)
    |> Enum.map(&{&1.id, &1.node_id, &1.status})
    |> Enum.sort()
  end

  defp event_count(ctx) do
    Repo.aggregate(from(e in Event, where: e.instance_id == ^ctx.instance_id), :count,
      prefix: ctx.schema_name
    )
  end

  defp timers_of_type(ctx, timer_type) do
    Timer
    |> where([t], t.instance_id == ^ctx.instance_id and t.timer_type == ^timer_type)
    |> order_by([t], asc: t.created_at, asc: t.id)
    |> Repo.all(prefix: ctx.schema_name)
  end

  defp reminders(ctx), do: timers_of_type(ctx, "reminder")
  defp escalations(ctx), do: timers_of_type(ctx, "escalation")
  defp pending_timers(rows), do: Enum.filter(rows, &(&1.status == "pending"))

  defp remind_entries(ctx, task) do
    Entry
    |> where(
      [e],
      e.resource_type == "task" and e.resource_id == ^task.id and e.action == "task.remind"
    )
    |> order_by([e], asc: e.timestamp, asc: e.id)
    |> Repo.all(prefix: ctx.schema_name)
  end

  defp timer_fired_events(ctx, timer) do
    Event
    |> where([e], e.instance_id == ^ctx.instance_id and e.event_type == "TIMER_FIRED")
    |> Repo.all(prefix: ctx.schema_name)
    |> Enum.filter(&(&1.payload["timer_id"] == timer.id))
  end

  defp dlq_entries(ctx, timer) do
    Dlq.Entry
    |> where([d], d.reference_id == ^timer.id)
    |> Repo.all(prefix: ctx.schema_name)
  end

  defp fire!(ctx, timer),
    do: assert({:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema_name))

  # Simulates the completion/escalation race orphan (design section 7 H-g/H-h): the
  # reminder row is pending again although its task is no longer pending.
  defp resurrect!(ctx, timer) do
    {1, _} =
      Repo.update_all(
        from(t in Timer, where: t.id == ^timer.id),
        [set: [status: "pending", cancelled_at: nil, cancel_reason: nil]],
        prefix: ctx.schema_name
      )

    :ok
  end

  defp assert_fire_at_near!(timer, task, seconds) do
    expected = DateTime.add(task.inserted_at, seconds, :second)
    diff = abs(DateTime.diff(timer.fire_at, expected, :millisecond))
    assert diff <= 1000, "fire_at #{timer.fire_at} is #{diff}ms from #{expected}"
  end

  defp assert_no_recurrence!(timer) do
    assert {timer.repeat_expression, timer.repeat_interval_us, timer.repeat_total,
            timer.fired_count} == {nil, nil, nil, nil}
  end

  defp assert_no_duplicate_pending!(ctx) do
    keys = ctx |> all_tasks() |> pending() |> Enum.map(&{&1.token_id, &1.node_id})
    assert keys == Enum.uniq(keys), "two :pending task rows share (token_id, node_id)"
  end

  # Shared AC5 assertions: a stale fire through the public attempt_fire/2 is :fired,
  # writes exactly one TIMER_FIRED, no task.remind, no new pending row, no DLQ.
  defp assert_stale_fire!(ctx, r1, task) do
    reminder_rows_before = length(reminders(ctx))
    assert timer_fired_events(ctx, r1) == []

    assert Scheduler.attempt_fire(r1.id, ctx.schema_name) == :fired

    assert [event] = timer_fired_events(ctx, r1)
    assert event.payload["timer_type"] == "reminder"
    assert remind_entries(ctx, task) == []
    assert length(reminders(ctx)) == reminder_rows_before
    assert pending_timers(reminders(ctx)) == []
    assert dlq_entries(ctx, r1) == []

    reloaded = reload_timer!(ctx, r1)
    assert reloaded.status == "fired"
    assert reloaded.fire_error_count == 0
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- backward compatibility (T-01)
  # ---------------------------------------------------------------------------------

  describe "AC1 backward compatibility" do
    test "no reminder_* keys arms no reminder timer on create, complete, timer fire, escalation fire" do
      schema = tenant_schema!()

      # (i) create + complete-task
      c1 = start_in!(schema, g_ab(ht("a"), ht("b")), %{})
      assert reminders(c1) == []
      assert [a1] = tasks_at(c1, "a")
      assert {:ok, _} = complete(c1, a1, %{})
      assert [_b1] = pending(tasks_at(c1, "b"))
      assert reminders(c1) == []

      # (ii) TIMER-node fire
      c2 = start_in!(schema, g_timer(ht("a")), %{})
      assert [deadline] = pending_timers(timers_of_type(c2, "deadline"))
      fire!(c2, deadline)
      assert [_a] = pending(tasks_at(c2, "a"))
      assert reminders(c2) == []

      # (iii) escalation fire behaves as today
      c3 = start_in!(schema, g_ab(ht_esc("a", "PT1H"), ht("b")), %{})
      assert [a3] = tasks_at(c3, "a")
      assert [e3] = escalations(c3)
      fire!(c3, e3)
      assert reload_task!(c3, a3).status == :cancelled
      assert [_b3] = pending(tasks_at(c3, "b"))
      assert reminders(c3) == []
    end

    test "no definition under test/fixtures carries a reminder_* key" do
      offenders =
        Path.wildcard(Path.join(File.cwd!(), "test/fixtures/**/*"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.filter(&(File.read!(&1) =~ "reminder_"))

      assert offenders == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- arming (T-02a..d), AC4 no-interval shape (T-04c)
  # ---------------------------------------------------------------------------------

  describe "AC2 arming" do
    test "a reminder-only node arms exactly one pending reminder on task creation" do
      ctx = new_case!(g_ab(ht_rem("a", "PT1H"), ht("b")), %{})
      assert [task] = tasks_at(ctx, "a")

      assert [r] = reminders(ctx)
      assert r.status == "pending"
      assert r.node_id == "a"
      assert r.token_id == task.token_id
      assert_no_recurrence!(r)
      assert_fire_at_near!(r, task, 3600)
      assert escalations(ctx) == []
    end

    test "a node with reminder and escalation arms one of each, escalation unchanged" do
      ctx = new_case!(g_ab(ht_rem_esc("a", "PT1H", "PT4H"), ht("b")), %{})
      assert [task] = tasks_at(ctx, "a")

      assert [r] = pending_timers(reminders(ctx))
      assert [e] = pending_timers(escalations(ctx))
      assert_fire_at_near!(r, task, 3600)
      assert_fire_at_near!(e, task, 14_400)
      assert {r.token_id, r.node_id} == {task.token_id, "a"}
      assert {e.token_id, e.node_id} == {task.token_id, "a"}

      assert length(
               Repo.all(
                 from(t in Timer,
                   where: t.instance_id == ^ctx.instance_id and t.status == "pending"
                 ),
                 prefix: ctx.schema_name
               )
             ) == 2
    end

    test "reminders are armed on complete-task, timer-fire and escalation-fire paths" do
      schema = tenant_schema!()

      # (i) complete-task
      c1 = start_in!(schema, g_ab(ht("a"), ht_rem("b", "PT1H")), %{})
      assert reminders(c1) == []
      assert [a1] = tasks_at(c1, "a")
      assert {:ok, _} = complete(c1, a1, %{})
      assert [b1] = tasks_at(c1, "b")
      assert [r1] = pending_timers(reminders(c1))
      assert {r1.token_id, r1.node_id} == {b1.token_id, "b"}
      assert_fire_at_near!(r1, b1, 3600)

      # (ii) TIMER-node fire
      c2 = start_in!(schema, g_timer(ht_rem("a", "PT1H")), %{})
      assert reminders(c2) == []
      assert [deadline] = pending_timers(timers_of_type(c2, "deadline"))
      fire!(c2, deadline)
      assert [a2] = tasks_at(c2, "a")
      assert [r2] = pending_timers(reminders(c2))
      assert {r2.token_id, r2.node_id} == {a2.token_id, "a"}
      assert_fire_at_near!(r2, a2, 3600)

      # (iii) escalation fire
      c3 = start_in!(schema, g_ab(ht_esc("a", "PT1H"), ht_rem("b", "PT1H")), %{})
      assert reminders(c3) == []
      assert [e3] = escalations(c3)
      fire!(c3, e3)
      assert [b3] = tasks_at(c3, "b")
      assert [r3] = pending_timers(reminders(c3))
      assert {r3.token_id, r3.node_id} == {b3.token_id, "b"}
      assert_fire_at_near!(r3, b3, 3600)
    end

    test "a reminder and a deadline TIMER armed in one hop chain do not collide" do
      graph = %{
        "nodes" => [
          start_node(),
          par("split"),
          ht_rem("a", "PT1H"),
          timer_node("t"),
          par("join"),
          end_node()
        ],
        "edges" => [
          edge("e1", "start", "split"),
          edge("e2", "split", "a"),
          edge("e3", "split", "t"),
          edge("e4", "a", "join"),
          edge("e5", "t", "join"),
          edge("e6", "join", "end")
        ]
      }

      ctx = new_case!(graph, %{})

      assert [%Timer{node_id: "a", status: "pending"}] = reminders(ctx)
      assert [%Timer{node_id: "t", status: "pending"}] = timers_of_type(ctx, "deadline")
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- non-recurring fire (T-03)
  # ---------------------------------------------------------------------------------

  describe "AC3 fire" do
    test "firing a non-recurring reminder records it and changes nothing else" do
      ctx = new_case!(g_ab(ht_rem("a", "PT1H"), ht("b")), %{"k" => "v"})
      assert [task] = tasks_at(ctx, "a")
      assert [r] = reminders(ctx)

      task_before = reload_task!(ctx, task)
      tokens_before = tokens(ctx)
      proj_before = projection!(ctx)
      task_count_before = length(all_tasks(ctx))
      events_before = event_count(ctx)

      fire!(ctx, r)

      assert reload_task!(ctx, task) == task_before
      assert task_before.status == :pending
      assert tokens(ctx) == tokens_before
      assert [{_id, "a", _status}] = tokens(ctx)

      proj_after = projection!(ctx)
      assert proj_after.status == proj_before.status
      assert proj_after.variables == proj_before.variables
      assert proj_after.current_nodes == proj_before.current_nodes
      assert length(all_tasks(ctx)) == task_count_before

      assert event_count(ctx) == events_before + 1
      assert [event] = timer_fired_events(ctx, r)
      assert event.payload["timer_type"] == "reminder"

      assert [entry] = remind_entries(ctx, task)
      assert entry.actor_id == EventStore.platform_actor_id()
      assert entry.before_state == nil

      assert entry.after_state == %{
               "task_id" => task.id,
               "node_id" => "a",
               "reminder_role" => "r-remind",
               "fire_count" => 1
             }

      assert reload_timer!(ctx, r).status == "fired"
      assert pending_timers(reminders(ctx)) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- recurrence (T-04a, T-04b)
  # ---------------------------------------------------------------------------------

  describe "AC4 repeat" do
    test "an interval PT1H count 2 series fires 3 times then completes" do
      ctx = new_case!(g_ab(ht_rem_rep("a", "PT2H", "PT1H", 2), ht("b")), %{})
      assert [task] = tasks_at(ctx, "a")
      assert [row1] = reminders(ctx)

      assert {row1.repeat_expression, row1.repeat_interval_us, row1.fired_count,
              row1.repeat_total} == {"PT1H", 3_600_000_000, 0, 3}

      fire!(ctx, row1)
      assert [row2] = pending_timers(reminders(ctx))
      assert row2.fired_count == 1
      assert row2.fire_at == DateTime.add(row1.fire_at, 3600, :second)
      assert {row2.token_id, row2.node_id} == {row1.token_id, "a"}

      fire!(ctx, row2)
      assert [row3] = pending_timers(reminders(ctx))
      assert row3.fired_count == 2
      assert row3.fire_at == DateTime.add(row2.fire_at, 3600, :second)

      fire!(ctx, row3)
      assert pending_timers(reminders(ctx)) == []
      assert length(reminders(ctx)) == 3

      assert Enum.map(remind_entries(ctx, task), & &1.after_state["fire_count"]) == [1, 2, 3]
      assert reload_task!(ctx, task).status == :pending
    end

    test "interval without count arms repeat_total 51" do
      ctx = new_case!(g_ab(ht_rem_rep_no_count("a", "PT1H", "P1W"), ht("b")), %{})
      assert [row] = reminders(ctx)

      assert {row.repeat_expression, row.repeat_interval_us, row.fired_count, row.repeat_total} ==
               {"P1W", 604_800_000_000, 0, 51}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- stale fire (T-05a, T-05b)
  # ---------------------------------------------------------------------------------

  describe "AC5 stale" do
    test "a reminder fired after its task completed is stale: no audit, no re-arm, no DLQ" do
      ctx = new_case!(g_ab(ht_rem_rep("a", "PT1H", "PT1H", 2), ht("b")), %{})
      assert [task] = tasks_at(ctx, "a")
      assert [r1] = reminders(ctx)
      assert {:ok, _} = complete(ctx, task, %{})
      assert reload_timer!(ctx, r1).status == "cancelled"

      resurrect!(ctx, r1)
      assert_stale_fire!(ctx, r1, task)
    end

    test "a reminder fired after its task was cancelled by escalation is stale" do
      ctx = new_case!(g_ab(ht_rem_esc("a", "PT1H", "PT4H"), ht("b")), %{})
      assert [task] = tasks_at(ctx, "a")
      assert [r1] = reminders(ctx)
      assert [e1] = escalations(ctx)
      fire!(ctx, e1)
      assert reload_task!(ctx, task).status == :cancelled

      resurrect!(ctx, r1)
      assert_stale_fire!(ctx, r1, task)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- cancel on completion (T-06, T-06b)
  # ---------------------------------------------------------------------------------

  describe "AC6 cancel on completion" do
    test "completing the task cancels its reminder with reason task_completed" do
      ctx = new_case!(g_ab(ht_rem("a", "PT1H"), ht("b")), %{})
      assert [task] = tasks_at(ctx, "a")
      assert [r1] = reminders(ctx)

      assert {:ok, _} = complete(ctx, task, %{})

      reloaded = reload_timer!(ctx, r1)
      assert reloaded.status == "cancelled"
      assert reloaded.cancel_reason == "task_completed"
      assert reloaded.cancelled_at != nil
      assert pending_timers(reminders(ctx)) == []
    end

    test "completing one task does not cancel a sibling token's reminder" do
      ctx = new_case!(g_parallel(ht_rem("a", "PT1H"), ht_rem("c", "PT1H")), %{})
      assert [a] = tasks_at(ctx, "a")
      assert [c] = tasks_at(ctx, "c")
      ra = Enum.find(reminders(ctx), &(&1.node_id == "a"))
      rc = Enum.find(reminders(ctx), &(&1.node_id == "c"))
      assert rc.token_id == c.token_id

      assert {:ok, _} = complete(ctx, a, %{})

      assert reload_timer!(ctx, ra).status == "cancelled"
      assert reload_timer!(ctx, rc).status == "pending"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- re-entry (T-07)
  # ---------------------------------------------------------------------------------

  describe "AC7 re-entry" do
    test "re-entry after completion arms a fresh reminder and cancels the old" do
      ctx = new_case!(g_loop(ht_rem("a", "PT1H")), %{})
      assert [t1] = tasks_at(ctx, "a")
      assert [r1] = reminders(ctx)

      assert {:ok, _} = complete(ctx, t1, %{"approved" => false})

      assert [t2] = pending(tasks_at(ctx, "a"))
      assert t2.id != t1.id
      assert_no_duplicate_pending!(ctx)

      old = reload_timer!(ctx, r1)
      assert {old.status, old.cancel_reason} == {"cancelled", "task_completed"}

      assert [r2] = pending_timers(reminders(ctx))
      assert r2.id != r1.id
      assert {r2.token_id, r2.node_id} == {t2.token_id, "a"}
      assert length(reminders(ctx)) == 2
    end

    test "re-entry with reminder and escalation leaves exactly one pending of each" do
      ctx = new_case!(g_loop(ht_rem_esc("a", "PT1H", "PT4H")), %{})
      assert [t1] = tasks_at(ctx, "a")
      assert [r1] = reminders(ctx)

      assert {:ok, _} = complete(ctx, t1, %{"approved" => false})

      assert [t2] = pending(tasks_at(ctx, "a"))

      assert {reload_timer!(ctx, r1).status, reload_timer!(ctx, r1).cancel_reason} ==
               {"cancelled", "task_completed"}

      assert [r2] = pending_timers(reminders(ctx))
      assert [e2] = pending_timers(escalations(ctx))
      assert r2.id != r1.id
      assert r2.token_id == t2.token_id
      assert e2.token_id == t2.token_id

      assert length(
               Repo.all(
                 from(t in Timer,
                   where: t.instance_id == ^ctx.instance_id and t.status == "pending"
                 ),
                 prefix: ctx.schema_name
               )
             ) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- coexistence with escalation (T-08a, T-08b)
  # ---------------------------------------------------------------------------------

  describe "AC8 coexistence" do
    test "reminder and escalation coexist; escalation cancels the reminder in the same transaction" do
      ctx = new_case!(g_ab(ht_rem_rep_no_count_esc("a", "PT1H", "PT1H", "PT4H"), ht("b")), %{})
      assert [task_a] = tasks_at(ctx, "a")
      assert [r1] = reminders(ctx)
      assert [e1] = escalations(ctx)

      fire!(ctx, r1)
      assert reload_task!(ctx, task_a).status == :pending
      assert [_entry] = remind_entries(ctx, task_a)
      assert [r2] = pending_timers(reminders(ctx))
      assert r2.id != r1.id

      fire!(ctx, e1)

      cancelled_task = reload_task!(ctx, task_a)
      assert cancelled_task.status == :cancelled

      r2_after = reload_timer!(ctx, r2)
      assert r2_after.status == "cancelled"
      assert r2_after.cancel_reason == "task_escalated"
      assert r2_after.cancelled_at == cancelled_task.cancelled_at

      assert pending_timers(reminders(ctx)) == []
      assert [_b] = pending(tasks_at(ctx, "b"))
    end

    test "escalation re-entry keeps a fresh reminder" do
      ctx = new_case!(g_loop(ht_rem_esc("a", "PT1H", "P0D")), %{"approved" => false})
      assert [t1] = tasks_at(ctx, "a")
      assert [r1] = reminders(ctx)
      assert [e1] = escalations(ctx)

      fire!(ctx, e1)

      assert reload_task!(ctx, t1).status == :cancelled
      assert [t2] = pending(tasks_at(ctx, "a"))
      assert t2.id != t1.id
      assert_no_duplicate_pending!(ctx)

      old = reload_timer!(ctx, r1)
      assert {old.status, old.cancel_reason} == {"cancelled", "task_escalated"}

      assert [r2] = pending_timers(reminders(ctx))
      assert [e2] = pending_timers(escalations(ctx))
      assert r2.id != r1.id
      assert e2.id != e1.id
      assert {r2.token_id, r2.node_id} == {t2.token_id, "a"}
      assert e2.token_id == t2.token_id
    end
  end
end
