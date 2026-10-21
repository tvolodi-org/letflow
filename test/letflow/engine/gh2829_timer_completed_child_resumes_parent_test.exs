defmodule Letflow.Engine.Gh2829TimerCompletedChildResumesParentTest do
  @moduledoc """
  GH #2829 (follow-up F-1 of #2707; decision 0061, "Amended (GH #2829)"): a sub-process child
  that reaches `:completed` because a timer fired resumes its waiting parent, exactly as a child
  completed through a HUMAN_TASK, a service task or a script does.

    * T1: child `START -> h0 -> TIMER -> END`; the timer fire completes the child AND the parent;
    * T2: the parent continues into a HUMAN_TASK after the sub-process node;
    * T3: grandparent chain (child of a child);
    * T4: the escalation twin: the fallback edge of an escalated HUMAN_TASK leads to END;
    * T5: lock order: the completing fire takes the parent group `FOR UPDATE` after `P_x` and
      before the timer row (the global order of decision 0061 is unchanged); a concurrent
      `cancel_instance(parent)` against the fire is not a failure; two sibling children
      completing by timer both succeed;
    * T6: a top-level `TIMER -> END` (no parent) still completes.

  The child graph is `START -> h0 (HUMAN_TASK) -> tmr (TIMER) -> END`: a child created by a
  SUB_PROCESS node does not arm a TIMER that directly follows its START (the pending events of
  the child's first hop chain are discarded, see `scheduler_fire_lock_order_test.exs`).

  Sandbox `:auto` mode (the fire runs in its own transaction), hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
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

    base = Fx.committed_tenant_case!("gh2829")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  # ---- graphs -----------------------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp human(id, extra \\ %{}),
    do: %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => Map.merge(%{"role" => "REVIEWER"}, extra)
    }

  # START -> h0 (HUMAN) -> tmr (TIMER) -> END
  defp child_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        human("h0"),
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "PT1H"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "h0"), edge("e2", "h0", "tmr"), edge("e3", "tmr", "end")]
    }
  end

  # START -> h0 (HUMAN) -> h1 (HUMAN, escalation to END) -> END
  defp escalating_child_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        human("h0"),
        human("h1", %{"escalation_timer_duration" => "PT4H", "escalation_role" => "r-esc"}),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "h0"), edge("e2", "h0", "h1"), edge("e3", "h1", "end")]
    }
  end

  # START -> sp (SUB_PROCESS child_def) [-> after (HUMAN)] -> END
  defp parent_graph(child_def, opts \\ []) do
    sp = %{
      "id" => "sp",
      "node_type" => "SUB_PROCESS",
      "attributes" => %{"definition_name" => child_def.name}
    }

    if Keyword.get(opts, :after_human, false) do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          sp,
          human("after"),
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          edge("p1", "start", "sp"),
          edge("p2", "sp", "after"),
          edge("p3", "after", "end")
        ]
      }
    else
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          sp,
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [edge("p1", "start", "sp"), edge("p2", "sp", "end")]
      }
    end
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
          idempotency_key: Fx.unique("gh2829-start")
        },
        prefix: base.schema
      )

    id
  end

  defp timers_of(base, instance_id) do
    Repo.all(from(t in Timer, where: t.instance_id == ^instance_id, order_by: t.created_at),
      prefix: base.schema
    )
  end

  defp pending_timers(base, instance_id),
    do: Enum.filter(timers_of(base, instance_id), &(&1.status == "pending"))

  defp pending_task!(base, instance_id, node_id) do
    [task] =
      Repo.all(
        from(t in EngineTask,
          where: t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == :pending
        ),
        prefix: base.schema
      )

    task
  end

  defp child_of!(base, parent_id, definition_id) do
    Repo.one!(
      from(p in InstanceProjection,
        where: p.parent_instance_id == ^parent_id and p.definition_id == ^definition_id,
        select: p.instance_id
      ),
      prefix: base.schema
    )
  end

  defp complete_fn(base, task_id) do
    fn ->
      Engine.complete_task(
        task_id,
        %{
          output_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("gh2829-complete")
        },
        prefix: base.schema
      )
    end
  end

  defp cancel_fn(base, instance_id) do
    fn ->
      Engine.cancel_instance(
        instance_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("gh2829-cancel")},
        prefix: base.schema
      )
    end
  end

  defp fire_fn(base, timer), do: fn -> Scheduler.fire_timer(timer.id, base.schema) end

  # Parent waiting on a child whose h0 is completed: the child is :active with exactly ONE pending
  # timer (precondition of every test, so a red result is about the parent, not about the fixture).
  # `child_graph` is the graph of the child; returns `{parent_id, child_id, timer}`.
  defp timer_pair!(base, child_graph \\ child_graph(), parent_opts \\ []) do
    c_def = activate!(base, child_graph)
    parent_id = create!(base, activate!(base, parent_graph(c_def, parent_opts)))
    child_id = child_of!(base, parent_id, c_def.id)

    assert {:ok, _} = complete_fn(base, pending_task!(base, child_id, "h0").id).()
    assert Fx.projection!(base.schema, child_id).status == :active
    assert [timer] = pending_timers(base, child_id)
    {parent_id, child_id, timer}
  end

  defp waiting_tokens(base, instance_id) do
    Repo.all(
      from(t in TokenRecord, where: t.instance_id == ^instance_id and t.status == :waiting),
      prefix: base.schema
    )
  end

  defp assert_resumed!(base, parent_id, child_id) do
    assert Fx.projection!(base.schema, child_id).status == :completed
    assert Fx.projection!(base.schema, parent_id).status == :completed
    assert waiting_tokens(base, parent_id) == []
    assert [_one] = Fx.instance_events(base.schema, parent_id, "SUB_PROCESS_COMPLETED")
  end

  # ---- T1: the red test -------------------------------------------------------------------------

  describe "T1: child ... -> TIMER -> END" do
    test "the timer fire completes the child and resumes the parent", %{base: base} do
      {parent_id, child_id, timer} = timer_pair!(base)

      assert {:ok, :fired} = fire_fn(base, timer).()
      assert_resumed!(base, parent_id, child_id)
    end
  end

  # ---- T2: the parent continues -----------------------------------------------------------------

  describe "T2: the parent continues after the sub-process node" do
    test "the parent advances into its next HUMAN_TASK", %{base: base} do
      {parent_id, child_id, timer} = timer_pair!(base, child_graph(), after_human: true)

      assert {:ok, :fired} = fire_fn(base, timer).()

      assert Fx.projection!(base.schema, child_id).status == :completed
      assert Fx.projection!(base.schema, parent_id).status == :active
      assert waiting_tokens(base, parent_id) == []
      assert %{status: :pending} = pending_task!(base, parent_id, "after")
    end
  end

  # ---- T3: grandparent chain --------------------------------------------------------------------

  describe "T3: grandparent chain" do
    test "the fire completes the child, its parent and the grandparent", %{base: base} do
      c_def = activate!(base, child_graph())

      # the middle instance reaches its SUB_PROCESS after a HUMAN_TASK: a child created in a
      # child's first hop chain is not started (same discarded-pending-events defect as the timer)
      mid_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          human("m0"),
          %{
            "id" => "sp",
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"definition_name" => c_def.name}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [edge("m1", "start", "m0"), edge("m2", "m0", "sp"), edge("m3", "sp", "end")]
      }

      mid_def = activate!(base, mid_graph)
      top_id = create!(base, activate!(base, parent_graph(mid_def)))
      mid_id = child_of!(base, top_id, mid_def.id)
      assert {:ok, _} = complete_fn(base, pending_task!(base, mid_id, "m0").id).()
      child_id = child_of!(base, mid_id, c_def.id)

      assert {:ok, _} = complete_fn(base, pending_task!(base, child_id, "h0").id).()
      assert [timer] = pending_timers(base, child_id)

      assert {:ok, :fired} = fire_fn(base, timer).()

      for id <- [child_id, mid_id, top_id],
          do: assert(Fx.projection!(base.schema, id).status == :completed)
    end
  end

  # ---- T4: escalation twin ----------------------------------------------------------------------

  describe "T4: escalation fire whose fallback edge leads to END" do
    test "the escalation completes the child and resumes the parent", %{base: base} do
      c_def = activate!(base, escalating_child_graph())
      parent_id = create!(base, activate!(base, parent_graph(c_def)))
      child_id = child_of!(base, parent_id, c_def.id)

      # the escalation timer of h1 is armed when h0 completes (not in the child's first hop chain)
      assert {:ok, _} = complete_fn(base, pending_task!(base, child_id, "h0").id).()
      assert [timer] = pending_timers(base, child_id)
      assert timer.timer_type == "escalation"
      assert timer.node_id == "h1"

      assert {:ok, :fired} = fire_fn(base, timer).()
      assert_resumed!(base, parent_id, child_id)
    end
  end

  # ---- T5: lock order ---------------------------------------------------------------------------

  describe "T5: lock order (decision 0061 unchanged)" do
    defp params(q), do: q |> Map.get(:params, []) |> Enum.map(&H.normalize/1)

    test "the parent group is FOR UPDATE, after P_c and before the timer row", %{base: base} do
      {parent_id, child_id, timer} = timer_pair!(base)

      {result, queries} = PlatformTenantFixture.capture_repo_queries(fire_fn(base, timer))
      assert {:ok, :fired} = result

      idx = fn pred -> Enum.find_index(queries, pred) end

      own =
        idx.(fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR UPDATE" and child_id in params(q)
        end)

      parent_lock =
        idx.(fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR UPDATE" and
            parent_id in params(q)
        end)

      timer_lock =
        idx.(fn q ->
          q.query =~ ~r/FROM "[^"]+"\."timers"/ and q.query =~ "FOR UPDATE"
        end)

      assert Enum.all?([own, parent_lock, timer_lock], &is_integer/1),
             inspect(Enum.map(queries, & &1.query), limit: :infinity)

      assert own < parent_lock and parent_lock < timer_lock
    end

    test "cancel(parent) against the completing fire: no deadlock, no failure", %{base: base} do
      {parent_id, child_id, timer} = timer_pair!(base)

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
      assert Fx.projection!(base.schema, child_id).status == :completed
    end

    test "two concurrent completing fires of different parents both succeed", %{base: base} do
      c_def = activate!(base, child_graph())

      pairs =
        for _ <- 1..2 do
          parent_id = create!(base, activate!(base, parent_graph(c_def)))
          child_id = child_of!(base, parent_id, c_def.id)
          assert {:ok, _} = complete_fn(base, pending_task!(base, child_id, "h0").id).()
          assert [timer] = pending_timers(base, child_id)
          {parent_id, child_id, timer}
        end

      results =
        pairs
        |> Enum.map(fn {_p, _c, timer} -> Task.async(fire_fn(base, timer)) end)
        |> Task.await_many(30_000)

      assert results == [{:ok, :fired}, {:ok, :fired}]
      for {p, c, _} <- pairs, do: assert_resumed!(base, p, c)
    end
  end

  # ---- T6: no regression ------------------------------------------------------------------------

  describe "T6: a top-level TIMER -> END" do
    test "still completes", %{base: base} do
      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "tmr",
            "node_type" => "TIMER",
            "attributes" => %{"duration_iso8601" => "PT1H"}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [edge("e1", "start", "tmr"), edge("e2", "tmr", "end")]
      }

      x = create!(base, activate!(base, graph))
      assert [timer] = pending_timers(base, x)
      assert {:ok, :fired} = fire_fn(base, timer).()
      assert Fx.projection!(base.schema, x).status == :completed
    end
  end
end
