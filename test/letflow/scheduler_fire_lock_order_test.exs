defmodule Letflow.SchedulerFireLockOrderTest do
  @moduledoc """
  GH #2707 / PR-1 (design `lib/letflow/design/gh2707-timer-fire-and-cold-appenders-lock-order.md`
  sections 2, 3, 4, 5, 8.1; decision 0061, "Amended (GH #2707, PR-1)"): `Scheduler.fire_timer/2`
  takes the instance's row locks in the order `tasks` (escalation only), `P_x`, the parent group
  (`FOR KEY SHARE`, child only), THEN the timer row, then the existing TIMER_FIRED append and
  advance; `cancel_instance/3` moves its timer UPDATE after `P_x`.

    * F0: statement order of one uncontended fire, per timer type and for a child;
    * F1 (C1): fire against a non-timer writer (`set_instance_error/2`), barrier on `S_x`;
    * F2 (C2): HUMAN completion against the reminder fire of the completed task;
    * F3 (C3): completion against the escalation fire of the same task (barrier on the task row);
    * F4 (C4): `cancel_instance/3` against an escalation fire;
    * F5 (C5): escalation fire against the reminder fire of the same task;
    * F6 / F6b (C6): a CHILD timer fire against `cancel_instance(parent)`, both foreign-key orders;
    * F7: the group statements of a child fire are `FOR KEY SHARE` and do not wait for a sibling's
      key share;
    * F8: a timer armed while cancel waits for `P_x` is cancelled by it;
    * F9: the claim/cancel race of SCH-03 (sequential and overlapped) is not a failure.

  Forced-overlap method: `Letflow.LockOrderHelpers`. Sandbox `:auto` mode, hence `async: false`.
  The green cases assert the 2 s lock-timeout yardstick margin (>= 500 ms), measured from the
  waiting side's wait start.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)
    :ok
  end

  defp tenant(_context) do
    base = Fx.committed_tenant_case!("gh2707-fire")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  defp token_first(_context) do
    %{base: base} = tenant(%{})
    H.set_fk_order!(base.schema, "tokens")
    %{base: base}
  end

  defp projection_first(_context) do
    %{base: base} = tenant(%{})
    H.set_fk_order!(base.schema, "instance_projections")
    %{base: base}
  end

  # ---- graphs -----------------------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  # START -> tmr (TIMER) -> h1 (HUMAN) -> END
  defp timer_human_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "PT1H"}
        },
        %{"id" => "h1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "tmr"), edge("e2", "tmr", "h1"), edge("e3", "h1", "end")]
    }
  end

  # START -> h0 (HUMAN) -> tmr (TIMER) -> h1 (HUMAN) -> END: the timer is armed when h0 completes
  # (a child created by a SUB_PROCESS node does not arm a TIMER that follows its START)
  defp child_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "h0", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "PT1H"}
        },
        %{"id" => "h1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        edge("e1", "start", "h0"),
        edge("e2", "h0", "tmr"),
        edge("e3", "tmr", "h1"),
        edge("e4", "h1", "end")
      ]
    }
  end

  # START -> orig (HUMAN with the given timer attributes) -> esc-task (HUMAN) -> END
  defp orig_graph(extra_attributes) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "orig",
          "node_type" => "HUMAN_TASK",
          "attributes" => Map.merge(%{"role" => "approver"}, extra_attributes)
        },
        %{
          "id" => "esc-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "r-esc"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        edge("e1", "start", "orig"),
        edge("e2", "orig", "esc-task"),
        edge("e3", "esc-task", "end")
      ]
    }
  end

  defp escalation_attrs,
    do: %{"escalation_timer_duration" => "PT4H", "escalation_role" => "r-esc"}

  defp reminder_attrs,
    do: %{"reminder_timer_duration" => "PT1H", "reminder_role" => "r-remind"}

  defp parent_graph(child_def) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_def.name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("p1", "start", "sp"), edge("p2", "sp", "end")]
    }
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp activate!(base, graph), do: Fx.legacy_activate!(base.schema, base.user, graph, [])

  defp create!(base, definition) do
    {:ok, %{instance_id: id}} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("fire-start")
        },
        prefix: base.schema
      )

    id
  end

  defp instance!(base, graph), do: create!(base, activate!(base, graph))

  defp timers_of(base, instance_id) do
    Repo.all(from(t in Timer, where: t.instance_id == ^instance_id, order_by: t.created_at),
      prefix: base.schema
    )
  end

  defp timer!(base, instance_id, type) do
    [timer] = Enum.filter(timers_of(base, instance_id), &(&1.timer_type == type))
    timer
  end

  defp reload_timer(base, timer), do: Repo.get!(Timer, timer.id, prefix: base.schema)

  defp tasks_of(base, instance_id) do
    Repo.all(
      from(t in EngineTask, where: t.instance_id == ^instance_id, order_by: [asc: t.inserted_at]),
      prefix: base.schema
    )
  end

  defp pending_task!(base, instance_id, node_id) do
    [task] =
      Enum.filter(tasks_of(base, instance_id), &(&1.node_id == node_id and &1.status == :pending))

    task
  end

  # the child of a parent whose sub-process node starts `child_graph`
  defp pair!(base, child_graph) do
    c_def = activate!(base, child_graph)
    parent = activate!(base, parent_graph(c_def))
    parent_id = create!(base, parent)

    child_id =
      Repo.one!(
        from(p in InstanceProjection,
          where: p.parent_instance_id == ^parent_id and p.definition_id == ^c_def.id,
          select: p.instance_id
        ),
        prefix: base.schema
      )

    {parent_id, child_id}
  end

  # a parent waiting on a child that sits at its TIMER node: `{parent_id, child_id, timer}`
  defp child_timer_pair!(base) do
    {parent_id, child_id} = pair!(base, child_graph())
    task = pending_task!(base, child_id, "h0")
    assert {:ok, _} = complete_fn(base, task.id).()
    [timer] = timers_of(base, child_id)
    assert Fx.projection!(base.schema, child_id).status == :active
    {parent_id, child_id, timer}
  end

  # ---- workers ----------------------------------------------------------------------------------

  defp fire_fn(base, timer), do: fn -> Scheduler.fire_timer(timer.id, base.schema) end

  defp complete_fn(base, task_id) do
    fn ->
      Engine.complete_task(
        task_id,
        %{
          output_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("fire-complete")
        },
        prefix: base.schema
      )
    end
  end

  defp cancel_fn(base, instance_id) do
    fn ->
      Engine.cancel_instance(
        instance_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("fire-cancel")},
        prefix: base.schema
      )
    end
  end

  defp set_error_fn(base, instance_id) do
    fn ->
      Engine.set_instance_error(
        %{
          instance_id: instance_id,
          error_type: :variable_schema_rejected,
          affected: {:field, "approved"},
          reason: "rejected",
          variables: %{},
          details: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("fire-set")
        },
        prefix: base.schema
      )
    end
  end

  # The margin (2 s lock-timeout yardstick minus the worst wait-start-to-return time, measured from
  # the waiting side as in the sibling lock-order files, hard floor 500 ms like them) is reported in
  # the assertion message, not on stdout.
  defp assert_margin!(overlap, label) do
    margin = H.margin_ms(overlap.timing)

    assert margin >= 500,
           "#{label}: lock_timeout margin #{margin} ms is under 500 ms (#{inspect(overlap.timing)})"

    margin
  end

  defp params(q), do: q |> Map.get(:params, []) |> Enum.map(&H.normalize/1)

  # ---- F0: statement order ----------------------------------------------------------------------

  describe "F0: statement order of one uncontended fire" do
    setup :tenant

    defp first_index(queries, pred), do: Enum.find_index(queries, pred)

    defp assert_fire_order!(queries, x) do
      peek =
        first_index(queries, fn q ->
          q.query =~ ~r/FROM "[^"]+"\."timers"/ and not (q.query =~ "FOR UPDATE")
        end)

      projection_lock =
        first_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR UPDATE" and x in params(q)
        end)

      timer_lock =
        first_index(queries, fn q ->
          q.query =~ ~r/FROM "[^"]+"\."timers"/ and q.query =~ "FOR UPDATE"
        end)

      timer_update = first_index(queries, &(&1.query =~ ~r/UPDATE "[^"]+"\."timers"/))
      sequence_lock = first_index(queries, &(&1.query =~ "instance_sequence"))

      positions = [peek, projection_lock, timer_lock, timer_update, sequence_lock]

      assert Enum.all?(positions, &is_integer/1),
             inspect(Enum.map(queries, & &1.query), limit: :infinity)

      assert peek < projection_lock, "the timer is peeked (unlocked) before P_x"
      assert projection_lock < timer_lock, "P_x is locked BEFORE the timer row"
      assert timer_lock < timer_update
      assert projection_lock < sequence_lock, "P_x is locked before S_x"

      %{projection_lock: projection_lock, timer_lock: timer_lock}
    end

    test "deadline timer: P_x, then the timer row, then S_x", %{base: base} do
      x = instance!(base, timer_human_graph())
      timer = hd(timers_of(base, x))

      {result, queries} = PlatformTenantFixture.capture_repo_queries(fire_fn(base, timer))
      assert {:ok, :fired} = result
      assert_fire_order!(queries, x)
    end

    test "reminder timer: P_x, then the timer row, then S_x", %{base: base} do
      x = instance!(base, orig_graph(reminder_attrs()))
      timer = timer!(base, x, "reminder")

      {result, queries} = PlatformTenantFixture.capture_repo_queries(fire_fn(base, timer))
      assert {:ok, :fired} = result
      assert_fire_order!(queries, x)
    end

    test "escalation timer: the pending task, P_x, then the timer row", %{base: base} do
      x = instance!(base, orig_graph(escalation_attrs()))
      timer = timer!(base, x, "escalation")

      {result, queries} = PlatformTenantFixture.capture_repo_queries(fire_fn(base, timer))
      assert {:ok, :fired} = result
      %{projection_lock: projection_lock} = assert_fire_order!(queries, x)

      task_lock =
        first_index(queries, fn q ->
          q.query =~ ~r/FROM "[^"]+"\."tasks"/ and q.query =~ "FOR UPDATE"
        end)

      assert is_integer(task_lock) and task_lock < projection_lock,
             "the pending tasks row is locked before P_x"
    end

    test "child timer: the parent group is taken after P_c and before the timer row", %{
      base: base
    } do
      {parent_id, child_id, timer} = child_timer_pair!(base)

      {result, queries} = PlatformTenantFixture.capture_repo_queries(fire_fn(base, timer))
      assert {:ok, :fired} = result
      %{projection_lock: own, timer_lock: timer_lock} = assert_fire_order!(queries, child_id)

      parent_share =
        first_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR KEY SHARE" and
            parent_id in params(q)
        end)

      token_share =
        first_index(queries, fn q ->
          q.query =~ "tokens" and q.query =~ "FOR KEY SHARE" and q.query =~ "waiting_child"
        end)

      assert is_integer(parent_share) and is_integer(token_share)
      assert own < parent_share and parent_share < token_share and token_share < timer_lock
    end
  end

  # ---- F1 (C1) ----------------------------------------------------------------------------------

  describe "F1: fire against a non-timer writer (cold TIMER_FIRED append: S_x then P_x)" do
    setup :tenant

    test "no deadlock; the fire lands first, then the error", %{base: base} do
      x = instance!(base, timer_human_graph())
      timer = hd(timers_of(base, x))

      overlap =
        H.forced_overlap(
          base.schema,
          {:sequence, x},
          fire_fn(base, timer),
          set_error_fn(base, x)
        )

      assert {:ok, :fired} = overlap.first
      assert {:ok, %{status: :error}} = overlap.second, inspect(overlap.second)
      assert reload_timer(base, timer).status == "fired"
      assert Fx.projection!(base.schema, x).status == :error
      assert_margin!(overlap, "F1")
    end
  end

  # ---- F2 (C2) ----------------------------------------------------------------------------------

  describe "F2: HUMAN completion against the reminder fire of the completed task" do
    setup :tenant

    test "no deadlock; the fire fires, then the completion completes", %{base: base} do
      x = instance!(base, orig_graph(reminder_attrs()))
      reminder = timer!(base, x, "reminder")
      task = pending_task!(base, x, "orig")

      overlap =
        H.forced_overlap(
          base.schema,
          {:sequence, x},
          fire_fn(base, reminder),
          complete_fn(base, task.id)
        )

      assert {:ok, :fired} = overlap.first
      assert {:ok, _} = overlap.second, inspect(overlap.second)
      assert reload_timer(base, reminder).status == "fired"
      assert [_one] = Fx.audit_rows(base.schema, "task.remind")
      assert Fx.task!(base.schema, task.id).status == :completed
      assert_margin!(overlap, "F2")
    end
  end

  # ---- F3 (C3) ----------------------------------------------------------------------------------

  describe "F3: completion against the escalation fire of the same task" do
    setup :tenant

    test "the fire queues behind the completion and finds its timer cancelled", %{base: base} do
      x = instance!(base, orig_graph(escalation_attrs()))
      escalation = timer!(base, x, "escalation")
      task = pending_task!(base, x, "orig")

      overlap =
        H.forced_overlap(
          base.schema,
          {:task, task.id},
          complete_fn(base, task.id),
          fire_fn(base, escalation)
        )

      assert {:ok, _} = overlap.first, inspect(overlap.first)
      assert {:ok, :already_final} = overlap.second

      reloaded = reload_timer(base, escalation)
      assert reloaded.status == "cancelled"
      assert reloaded.cancel_reason == "task_completed"

      # the completion created the next task; the fire created none
      assert Enum.map(tasks_of(base, x), &{&1.node_id, &1.status}) ==
               [{"orig", :completed}, {"esc-task", :pending}]

      assert_margin!(overlap, "F3")
    end
  end

  # ---- F4 (C4) ----------------------------------------------------------------------------------

  describe "F4: cancel against an escalation fire" do
    setup :tenant

    test "the fire takes the task first; cancel then cancels the escalated task", %{base: base} do
      x = instance!(base, orig_graph(escalation_attrs()))
      escalation = timer!(base, x, "escalation")

      overlap =
        H.forced_overlap(
          base.schema,
          {:sequence, x},
          fire_fn(base, escalation),
          cancel_fn(base, x)
        )

      assert {:ok, :fired} = overlap.first
      assert {:ok, _} = overlap.second, inspect(overlap.second)

      assert Enum.map(tasks_of(base, x), &{&1.node_id, &1.status}) ==
               [{"orig", :cancelled}, {"esc-task", :cancelled}]

      assert reload_timer(base, escalation).status == "fired"
      assert Fx.projection!(base.schema, x).status == :cancelled
      assert Enum.filter(timers_of(base, x), &(&1.status == "pending")) == []
      assert_margin!(overlap, "F4")
    end
  end

  # ---- F5 (C5) ----------------------------------------------------------------------------------

  describe "F5: escalation fire against the reminder fire of the same task" do
    setup :tenant

    test "serialised on P_x; the escalation cancels the reminder", %{base: base} do
      x = instance!(base, orig_graph(Map.merge(escalation_attrs(), reminder_attrs())))
      escalation = timer!(base, x, "escalation")
      reminder = timer!(base, x, "reminder")

      overlap =
        H.forced_overlap(
          base.schema,
          {:sequence, x},
          fire_fn(base, escalation),
          fire_fn(base, reminder)
        )

      assert {:ok, :fired} = overlap.first
      assert {:ok, :already_final} = overlap.second

      reloaded = reload_timer(base, reminder)
      assert reloaded.status == "cancelled"
      assert reloaded.cancel_reason == "task_escalated"
      assert Fx.audit_rows(base.schema, "task.remind") == []
      assert_margin!(overlap, "F5")
    end
  end

  # ---- F6 / F6b (C6) ----------------------------------------------------------------------------

  defp child_overlap!(base) do
    {parent_id, child_id, timer} = child_timer_pair!(base)

    overlap =
      H.forced_overlap(
        base.schema,
        {:projection, parent_id},
        cancel_fn(base, parent_id),
        fire_fn(base, timer)
      )

    assert {:ok, _} = overlap.first, inspect(overlap.first)
    assert {:ok, :fired} = overlap.second, inspect(overlap.second)

    assert Fx.projection!(base.schema, parent_id).status == :cancelled
    assert Fx.projection!(base.schema, child_id).status == :active
    assert reload_timer(base, timer).status == "fired"
    assert [%{status: :completed}, %{node_id: "h1", status: :pending}] = tasks_of(base, child_id)
    assert_margin!(overlap, "F6/F6b")
  end

  describe "F6: child timer fire against cancel(parent), FK order token first" do
    setup :token_first

    test "no deadlock", %{base: base} do
      child_overlap!(base)
    end
  end

  describe "F6b: child timer fire against cancel(parent), FK order projection first" do
    setup :projection_first

    test "no deadlock (the cycle is unreachable)", %{base: base} do
      child_overlap!(base)
    end
  end

  # ---- F7: lock mode ----------------------------------------------------------------------------

  describe "F7: the group of a child fire is FOR KEY SHARE" do
    setup :tenant

    test "no FOR UPDATE on the parent rows", %{base: base} do
      {parent_id, _child_id, timer} = child_timer_pair!(base)

      {result, queries} = PlatformTenantFixture.capture_repo_queries(fire_fn(base, timer))
      assert {:ok, :fired} = result

      refute Enum.any?(queries, fn q ->
               q.query =~ "FOR UPDATE" and parent_id in params(q)
             end)

      refute Enum.any?(queries, fn q ->
               q.query =~ "tokens" and q.query =~ "waiting_child" and q.query =~ "FOR UPDATE"
             end)
    end

    test "a sibling's key share on the parent group does not block the fire", %{base: base} do
      {parent_id, _child_id, timer} = child_timer_pair!(base)
      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s(SELECT 1 FROM "#{base.schema}"."instance_projections" WHERE instance_id = $1 FOR KEY SHARE),
              [Ecto.UUID.dump!(parent_id)]
            )

            send(test_pid, :sibling_holds)

            receive do
              :release -> :ok
            after
              H.await_ms() -> :ok
            end
          end)
        end)

      on_exit(fn -> send(holder.pid, :release) end)
      assert_receive :sibling_holds, 10_000

      # the fire runs in its own task and must COMPLETE while the sibling still holds its key share
      fire = Task.async(fn -> Scheduler.fire_timer(timer.id, base.schema) end)
      yielded = Task.yield(fire, 3_000) || Task.shutdown(fire, :brutal_kill)
      assert {:ok, {:ok, :fired}} = yielded, "the fire waited for a sibling's key share"

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())
    end
  end

  # ---- F8: the cancel's timer step moved --------------------------------------------------------

  describe "F8: a timer armed while cancel waits for P_x" do
    setup :tenant

    test "is cancelled by the cancel", %{base: base} do
      x = instance!(base, timer_human_graph())
      original = hd(timers_of(base, x))

      {holder, _barrier_pid} = H.hold_row(base.schema, {:projection, x})
      {cancel, cancel_pid} = H.start_worker(cancel_fn(base, x))
      H.wait_for_blocked([cancel_pid], 1)

      # armed after cancel's class-1 statements ran, while it waits for P_x
      assert {:ok, late} =
               Scheduler.create(
                 Repo,
                 %{
                   instance_id: x,
                   timer_type: "deadline",
                   node_id: "late",
                   fire_at: DateTime.add(DateTime.utc_now(), 3600, :second)
                 },
                 prefix: base.schema
               )

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())
      assert {{:ok, _}, _done_at} = Task.await(cancel, H.await_ms())

      for t <- [original, late] do
        reloaded = reload_timer(base, t)
        assert reloaded.status == "cancelled"
        assert reloaded.cancel_reason == "instance_cancelled"
      end
    end
  end

  # ---- F9: SCH-03 race --------------------------------------------------------------------------

  describe "F9: claim, cancel, then fire (SCH-03; GH #2822 acceptance criterion 2)" do
    setup :tenant

    defp assert_not_a_failure!(base, x, timer, outcome) do
      assert outcome == :already_final
      reloaded = reload_timer(base, timer)
      assert reloaded.status == "cancelled"
      assert reloaded.fire_error_count == 0
      assert Fx.dlq_entries(base.schema) == []
      assert Fx.instance_events(base.schema, x, "TIMER_FIRED") == []
    end

    test "(a) sequential: the claimed timer, committed cancel, then the fire", %{base: base} do
      x = instance!(base, timer_human_graph())
      timer = hd(timers_of(base, x))

      # the poll claims in the past: make the timer due
      Repo.update_all(
        from(t in Timer, where: t.id == ^timer.id),
        [set: [fire_at: DateTime.add(DateTime.utc_now(), -60, :second)]],
        prefix: base.schema
      )

      assert timer.id in Scheduler.claim_due_timer_ids(base.schema, 64)
      assert {:ok, _} = cancel_fn(base, x).()

      assert_not_a_failure!(base, x, timer, Scheduler.attempt_fire(timer.id, base.schema))
    end

    test "(b) overlapped: both queue behind the projection", %{base: base} do
      x = instance!(base, timer_human_graph())
      timer = hd(timers_of(base, x))

      overlap =
        H.forced_overlap(
          base.schema,
          {:projection, x},
          cancel_fn(base, x),
          fn -> Scheduler.attempt_fire(timer.id, base.schema) end
        )

      assert {:ok, _} = overlap.first
      assert_not_a_failure!(base, x, timer, overlap.second)
      assert_margin!(overlap, "F9b")
    end
  end
end
