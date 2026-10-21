defmodule Letflow.EngineDistinctFromTest do
  @moduledoc """
  REQ-463 -- rule A of the REQ-459 design (`distinct_from` on a HUMAN_TASK: the user who most
  recently completed a named node of the SAME instance may not complete, or claim, this one),
  driven through the real `Letflow.Engine.complete_task/3`, `Letflow.Tasks.claim_task/3`,
  `assign_task/3`, `reassign_task/3` and `Letflow.Engine.SeparationOfDuties` against real
  Postgres (`test_developer_guide.md` T-1). Covers design section 12.2 cases A-1, A-3, A-3a,
  A-6, A-7, A-9, A-10, A-11, A-12, A-13, A-14, A-15 and the 4b-before-4c order.

  The HTTP half (403 wire body, API token, TENANT_ADMIN, claim over HTTP, replay 409) lives in
  `test/letflow/routers/tasks_distinct_from_test.exs`; the concurrency case (A-8) lives in
  `test/letflow/engine_distinct_from_concurrency_test.exs`.

  Every test builds its own tenant, users and definition (`Letflow.SodSupport`); "unchanged"
  assertions compare the instance projection (including `updated_at`), every token, every task
  row, the event count and every timer row, read before and after the refused call.

  See `test/specs/REQ-463.md` for the criterion -> case map and why each case exists.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Letflow.Definitions
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Engine
  alias Letflow.Engine.SeparationOfDuties
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Scheduler
  alias Letflow.SodSupport, as: S
  alias Letflow.Tasks

  @n1 S.n1()
  @n2 S.n2()
  @qa Path.expand("../fixtures/qa", __DIR__)

  # ---------------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------------

  # U holds role-a, role-b, role-c and role-p; V holds role-b, role-c and role-p; W holds
  # role-a, role-c and role-p (never role-b).
  defp with_people!(ctx) do
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    w = S.insert_user!(ctx.schema_name, "w")
    S.grant_role!(ctx.schema_name, "role-a", [u.id, w.id])
    S.grant_role!(ctx.schema_name, "role-b", [u.id, v.id])
    S.grant_role!(ctx.schema_name, "role-c", [u.id, v.id, w.id])
    S.grant_role!(ctx.schema_name, "role-p", [u.id, v.id, w.id])
    Map.merge(ctx, %{u: u, v: v, w: w})
  end

  defp case!(graph, schemas, initial) do
    graph |> S.new_case!(schemas, initial) |> with_people!()
  end

  defp seq_case!(n2_attrs), do: case!(S.seq_graph(n2_attrs), %{}, %{"seed" => "value"})

  defp seq_case!, do: seq_case!(%{"distinct_from" => [@n1]})

  # A second instance of the SAME definition in the SAME tenant.
  defp another_instance(ctx),
    do: %{
      ctx
      | instance_id: S.start_instance!(ctx.schema_name, ctx.definition, %{"seed" => "v2"})
    }

  defp snapshot_graph!(ctx) do
    {:ok, snapshot} = SnapshotStore.get_by_instance_id(ctx.instance_id, prefix: ctx.schema_name)
    {:ok, graph} = Engine.build_graph(snapshot.graph)
    graph
  end

  defp assert_refused_untouched!(ctx, before, result) do
    assert result == {:error, :separation_of_duties}
    assert S.rows(ctx) == before
  end

  # Counts the Ecto queries (including begin/commit) issued by the calling process inside
  # `fun`, returning `{result, count}`.
  defp count_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = "req463-count-" <> inspect(ref)

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end

  # ---------------------------------------------------------------------------------
  # A-1 -- two roles, one user
  # ---------------------------------------------------------------------------------

  describe "A-1 -- one user holding two roles" do
    test "U completes N1, U attempting N2 is refused: detail-free error, nothing written but ONE audit row, task still claimable; V then completes N2" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)
      before = S.rows(ctx)
      audit_before = S.audit_count(ctx.schema_name)

      result = S.complete(ctx, n2_task, ctx.u.id, %{"note" => "SOD-NOTE-VALUE"})

      assert_refused_untouched!(ctx, before, result)
      assert S.reload_task!(ctx, n2_task).status == :pending

      # the public error carries no node id, user id, name or value
      for forbidden <- [@n1, @n2, ctx.u.id, ctx.u.email, "SOD-NOTE-VALUE"] do
        refute inspect(result) =~ forbidden
      end

      assert S.audit_count(ctx.schema_name) == audit_before + 1
      assert [entry] = S.refusal_rows(ctx.schema_name)
      assert entry.action == "task.completion_refused"
      assert entry.resource_type == "task"
      assert entry.resource_id == n2_task.id
      assert entry.actor_id == ctx.u.id
      assert entry.before_state == nil

      assert entry.after_state == %{
               "rule" => "separation_of_duties",
               "instance_id" => ctx.instance_id,
               "node_id" => @n2,
               "blocking_node_ids" => [@n1]
             }

      dump = inspect(entry, limit: :infinity)

      for pii <- [
            ctx.u.email,
            ctx.u.display_name,
            ctx.u.username,
            ctx.v.email,
            "SOD-NOTE-VALUE"
          ] do
        refute dump =~ pii
      end

      # still open and claimable by an eligible user, and completable by a second user
      assert {:ok, claimed} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.v.id}, prefix: ctx.schema_name)

      assert claimed.assignee_type == "USER"
      assert claimed.assignee_ref == ctx.v.id

      assert {:ok, done} = S.complete(ctx, n2_task, ctx.v.id, %{})
      assert done.instance_status == :completed
      assert length(S.refusal_rows(ctx.schema_name)) == 1
    end

    test "every refused attempt writes its own audit row (two refusals, two rows)" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)

      for _ <- 1..2 do
        assert {:error, :separation_of_duties} = S.complete(ctx, n2_task, ctx.u.id, %{})
      end

      assert length(S.refusal_rows(ctx.schema_name)) == 2
    end

    test "a user who did NOT complete the named node is accepted (the rule is not a blanket refusal)" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.w.id, %{})

      assert {:ok, %{instance_status: :completed}} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})

      assert S.refusal_rows(ctx.schema_name) == []
    end

    test "the comparison is per instance: U's completion of N1 in instance A does not block U in instance B" do
      ctx = seq_case!()
      other = another_instance(ctx)

      # B's N1 is completed by W FIRST, A's N1 by U AFTERWARDS: U's row is the most recent N1
      # row of the whole tenant, so a query that ignored instance_id would refuse U in B.
      S.complete_node!(other, @n1, ctx.w.id, %{})
      S.complete_node!(ctx, @n1, ctx.u.id, %{})

      assert {:ok, %{instance_status: :completed}} =
               S.complete(other, S.pending_task!(other, @n2), ctx.u.id, %{})

      # and in A itself U is still refused
      assert {:error, :separation_of_duties} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})
    end
  end

  describe "A-1b -- several named nodes: only the ones whose MOST RECENT completer is the actor block" do
    test "blocking_node_ids is sorted ascending, declared order is irrelevant, other completers do not appear" do
      # third-review names [second-review, first-review] (unsorted on purpose)
      ctx = case!(S.chain_graph([@n2, @n1]), %{}, %{"seed" => 1})
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      S.complete_node!(ctx, @n2, ctx.u.id, %{})
      before = S.rows(ctx)

      result = S.complete(ctx, S.pending_task!(ctx, "third-review"), ctx.u.id, %{})
      assert_refused_untouched!(ctx, before, result)

      assert [entry] = S.refusal_rows(ctx.schema_name)
      assert entry.after_state["blocking_node_ids"] == [@n1, @n2]
    end

    test "only the node U really completed blocks: V completed the other one" do
      ctx = case!(S.chain_graph([@n2, @n1]), %{}, %{"seed" => 1})
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      S.complete_node!(ctx, @n2, ctx.v.id, %{})

      assert {:error, :separation_of_duties} =
               S.complete(ctx, S.pending_task!(ctx, "third-review"), ctx.u.id, %{})

      assert [entry] = S.refusal_rows(ctx.schema_name)
      assert entry.after_state["blocking_node_ids"] == [@n1]
    end

    test "a completion of a node that is NOT named never blocks (U completed second-review, third-review names only first-review)" do
      ctx = case!(S.chain_graph([@n1]), %{}, %{"seed" => 1})
      S.complete_node!(ctx, @n1, ctx.v.id, %{})
      S.complete_node!(ctx, @n2, ctx.u.id, %{})

      assert {:ok, %{instance_status: :completed}} =
               S.complete(ctx, S.pending_task!(ctx, "third-review"), ctx.u.id, %{})
    end
  end

  # ---------------------------------------------------------------------------------
  # A-6 -- rework loop: the MOST RECENT completion of a named node wins
  # ---------------------------------------------------------------------------------

  describe "A-6 -- rework loop" do
    defp rework_case!, do: case!(S.rework_graph(), %{}, %{"seed" => 1})

    # One pass through N1: `n1_actor` completes N1, W completes the triage step with `again`.
    defp pass!(ctx, n1_actor, again) do
      S.complete_node!(ctx, @n1, n1_actor.id, %{})
      S.complete_node!(ctx, "triage-review", ctx.w.id, %{"again" => again})
    end

    test "U then V complete N1 (second pass): U is accepted at N2 because the most recent N1 completer is V; V is refused" do
      ctx = rework_case!()
      pass!(ctx, ctx.u, "yes")
      assert [@n1] == pending_nodes(ctx)
      pass!(ctx, ctx.v, "no")
      assert [@n2] == pending_nodes(ctx)

      # two COMPLETED N1 rows exist (U's, then V's); V is the most recent: refused. Nothing was
      # committed, so U can still go.
      assert 2 == completed_count(ctx, @n1)

      assert {:error, :separation_of_duties} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.v.id, %{})

      assert {:ok, %{instance_status: :completed}} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})
    end

    test "reversed order, V then U on the second pass: U is refused, V is accepted" do
      ctx = rework_case!()
      pass!(ctx, ctx.v, "yes")
      pass!(ctx, ctx.u, "no")

      before = S.rows(ctx)
      result = S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})
      assert_refused_untouched!(ctx, before, result)

      assert {:ok, %{instance_status: :completed}} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.v.id, %{})
    end

    test "three passes U, V, U: the latest N1 row is U's -> U refused, V accepted" do
      ctx = rework_case!()
      pass!(ctx, ctx.u, "yes")
      pass!(ctx, ctx.v, "yes")
      pass!(ctx, ctx.u, "no")

      assert {:error, :separation_of_duties} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})

      assert {:ok, _} = S.complete(ctx, S.pending_task!(ctx, @n2), ctx.v.id, %{})
    end

    test "a CANCELLED row of the named node (escalated past) is never a completion, even with completed_by forged onto it" do
      ctx = case!(esc_graph([@n1]), %{}, %{"go" => "no"})
      n1_row = S.pending_task!(ctx, @n1)
      fire_escalation!(ctx)
      assert S.reload_task!(ctx, n1_row).status == :cancelled

      # forge the shape a mutant that drops the status filter would trip on
      from(t in EngineTask, where: t.id == ^n1_row.id)
      |> Repo.update_all(
        [set: [completed_by: ctx.u.id, completed_at: DateTime.utc_now()]],
        prefix: ctx.schema_name
      )

      assert S.reload_task!(ctx, n1_row).completed_by == ctx.u.id
      S.complete_node!(ctx, "escalated-review", ctx.w.id, %{})

      assert {:ok, %{instance_status: :completed}} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})
    end
  end

  defp completed_count(ctx, node_id) do
    Repo.aggregate(
      from(t in EngineTask,
        where:
          t.instance_id == ^ctx.instance_id and t.node_id == ^node_id and t.status == :completed
      ),
      :count,
      prefix: ctx.schema_name
    )
  end

  defp pending_nodes(ctx) do
    EngineTask
    |> where([t], t.instance_id == ^ctx.instance_id and t.status == :pending)
    |> select([t], t.node_id)
    |> Repo.all(prefix: ctx.schema_name)
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------------
  # A-7 -- parallel branches
  # ---------------------------------------------------------------------------------

  describe "A-7 -- parallel branches P1, P2, P3 each naming the other two" do
    @p ["branch-one", "branch-two", "branch-three"]

    defp parallel_case!, do: case!(S.parallel_graph(), %{}, %{"seed" => 1})

    test "U completes P1, then U attempting P2 and P3 is refused; V and W complete them; the join fires" do
      ctx = parallel_case!()
      S.complete_node!(ctx, "branch-one", ctx.u.id, %{})
      before = S.rows(ctx)

      for node <- ["branch-two", "branch-three"] do
        assert {:error, :separation_of_duties} =
                 S.complete(ctx, S.pending_task!(ctx, node), ctx.u.id, %{})
      end

      assert S.rows(ctx) == before
      refusals = Enum.sort_by(S.refusal_rows(ctx.schema_name), & &1.after_state["node_id"])
      assert Enum.map(refusals, & &1.after_state["node_id"]) == ["branch-three", "branch-two"]
      assert Enum.all?(refusals, &(&1.after_state["blocking_node_ids"] == ["branch-one"]))

      S.complete_node!(ctx, "branch-two", ctx.v.id, %{})
      # V completed P2 so V may not do P3, W (who completed nothing) may
      assert {:error, :separation_of_duties} =
               S.complete(ctx, S.pending_task!(ctx, "branch-three"), ctx.v.id, %{})

      assert {:ok, %{instance_status: :completed}} =
               S.complete(ctx, S.pending_task!(ctx, "branch-three"), ctx.w.id, %{})
    end

    test "the order does not matter: U completing ANY branch first is refused on every other branch" do
      ctx = parallel_case!()

      for first <- @p, second <- @p -- [first] do
        inst = another_instance(ctx)
        S.complete_node!(inst, first, ctx.u.id, %{})

        assert {:error, :separation_of_duties} =
                 S.complete(inst, S.pending_task!(inst, second), ctx.u.id, %{}),
               "U completed #{first}, so completing #{second} must be refused"
      end
    end

    test "three distinct users complete P1, P2 and P3 in every order and all are accepted" do
      ctx = parallel_case!()
      users = [ctx.u.id, ctx.v.id, ctx.w.id]

      for order <- permutations(@p) do
        inst = another_instance(ctx)

        for {node, user_id} <- Enum.zip(order, users) do
          assert {:ok, _} = S.complete(inst, S.pending_task!(inst, node), user_id, %{}),
                 "order #{inspect(order)}: #{node} by a user who completed no other branch"
        end

        assert Repo.get!(Letflow.EventStore.InstanceProjection, inst.instance_id,
                 prefix: inst.schema_name
               ).status == :completed
      end

      assert S.refusal_rows(ctx.schema_name) == []
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(list),
    do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  # ---------------------------------------------------------------------------------
  # A-9 -- a named node that never completed
  # ---------------------------------------------------------------------------------

  describe "A-9 -- named node never completed (path skipped it)" do
    defp skip_graph do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
          S.human(@n1, "role-a", %{}),
          S.human(@n2, "role-b", %{"distinct_from" => [@n1]}),
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "gw"},
          %{
            "id" => "e2",
            "source" => "gw",
            "target" => @n1,
            "condition" => "variables.path == \"a\""
          },
          %{"id" => "e3", "source" => "gw", "target" => @n2, "is_default" => true},
          %{"id" => "e4", "source" => @n1, "target" => @n2},
          %{"id" => "e5", "source" => @n2, "target" => "end"}
        ]
      }
    end

    test "the path skipped N1: U completes N2 with no refusal and no audit row" do
      ctx = case!(skip_graph(), %{}, %{"path" => "b"})
      assert [@n2] == pending_nodes(ctx)

      assert {:ok, %{instance_status: :completed}} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})

      assert S.refusal_rows(ctx.schema_name) == []
    end

    test "control: the SAME definition on the path through N1 does refuse U at N2" do
      ctx = case!(skip_graph(), %{}, %{"path" => "a"})
      S.complete_node!(ctx, @n1, ctx.u.id, %{})

      assert {:error, :separation_of_duties} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})
    end
  end

  # ---------------------------------------------------------------------------------
  # A-10 / A-14 -- escalation (D-ESC)
  # ---------------------------------------------------------------------------------

  # START -> first-review (role-a, escalation timer P2D -> role-esc) --go=="yes"--> second-review
  #                                  \--fallback-first-review--> escalated-review (role-esc) --> second-review
  # second-review (role-b, distinct_from = n2_names) -> END
  defp esc_graph(n2_names) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        S.human(@n1, "role-a", %{
          "escalation_timer_duration" => "P2D",
          "escalation_role" => "role-esc"
        }),
        S.human("escalated-review", "role-esc", %{}),
        S.human(@n2, "role-b", %{"distinct_from" => n2_names}),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => @n1},
        %{
          "id" => "e2",
          "source" => @n1,
          "target" => @n2,
          "condition" => "variables.go == \"yes\""
        },
        %{"id" => "fallback-first-review", "source" => @n1, "target" => "escalated-review"},
        %{"id" => "e4", "source" => "escalated-review", "target" => @n2},
        %{"id" => "e5", "source" => @n2, "target" => "end"}
      ]
    }
  end

  defp fire_escalation!(ctx) do
    {:ok, timer} = Scheduler.resolve_advance_target(ctx.instance_id, nil, ctx.schema_name)
    assert timer.timer_type == "escalation"
    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema_name)
    timer
  end

  describe "A-10 -- named node escalated past" do
    test "N2 names only N1, N1 timed out into escalated-review: U (who completed the escalation node) is NOT constrained" do
      ctx = case!(esc_graph([@n1]), %{}, %{"go" => "no"})
      timer = fire_escalation!(ctx)
      assert timer.node_id == @n1
      S.complete_node!(ctx, "escalated-review", ctx.u.id, %{})

      assert {:ok, %{instance_status: :completed}} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})

      assert S.refusal_rows(ctx.schema_name) == []
    end

    test "N2 naming the escalation node too: the escalation completer IS refused (no inheritance, an explicit name constrains)" do
      ctx = case!(esc_graph([@n1, "escalated-review"]), %{}, %{"go" => "no"})
      fire_escalation!(ctx)
      S.complete_node!(ctx, "escalated-review", ctx.u.id, %{})

      assert {:error, :separation_of_duties} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{})

      assert [entry] = S.refusal_rows(ctx.schema_name)
      assert entry.after_state["blocking_node_ids"] == ["escalated-review"]
    end
  end

  describe "A-14 -- a refusal leaves the armed escalation timer alone" do
    defp timer_graph do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          S.human(@n1, "role-a", %{}),
          S.human(@n2, "role-b", %{
            "distinct_from" => [@n1],
            "escalation_timer_duration" => "P2D",
            "escalation_role" => "role-esc"
          }),
          S.human("escalated-second", "role-esc", %{}),
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => @n1},
          %{"id" => "e2", "source" => @n1, "target" => @n2},
          %{
            "id" => "e3",
            "source" => @n2,
            "target" => "end",
            "condition" => "variables.ok == \"yes\""
          },
          %{"id" => "fallback-second-review", "source" => @n2, "target" => "escalated-second"},
          %{"id" => "e5", "source" => "escalated-second", "target" => "end"}
        ]
      }
    end

    test "the pending timer of N2 keeps its status and fire_at after a refusal (the timer rows are part of the unchanged snapshot)" do
      ctx = case!(timer_graph(), %{}, %{"seed" => 1})
      S.complete_node!(ctx, @n1, ctx.u.id, %{})

      before = S.rows(ctx)
      assert [armed] = Enum.filter(before.timers, &(&1.node_id == @n2 and &1.status == "pending"))

      assert {:error, :separation_of_duties} =
               S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{"ok" => "yes"})

      assert S.rows(ctx) == before
      after_refusal = Enum.find(S.rows(ctx).timers, &(&1.id == armed.id))
      assert after_refusal.fire_at == armed.fire_at
      assert after_refusal.status == "pending"

      # control: an accepted completion DOES settle the timer, so the snapshot is not blind to it
      assert {:ok, _} = S.complete(ctx, S.pending_task!(ctx, @n2), ctx.v.id, %{"ok" => "yes"})
      settled = Enum.find(S.rows(ctx).timers, &(&1.id == armed.id))
      refute settled.status == "pending"
    end
  end

  # ---------------------------------------------------------------------------------
  # A-11 -- assign / reassign: no check there, the completion check still refuses
  # ---------------------------------------------------------------------------------

  describe "A-11 -- assign_task and reassign_task" do
    test "reassign_task to U (who completed N1) succeeds; U's completion is then refused" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)

      assert {:ok, reassigned} =
               Tasks.reassign_task(n2_task.id, %{user_id: ctx.u.id}, prefix: ctx.schema_name)

      assert {reassigned.assignee_type, reassigned.assignee_ref} == {"USER", ctx.u.id}
      assert :ok == Tasks.authorize_completion(n2_task.id, ctx.u.id, prefix: ctx.schema_name)

      before = S.rows(ctx)
      assert_refused_untouched!(ctx, before, S.complete(ctx, n2_task, ctx.u.id, %{}))
    end

    test "assign_task of an unassigned N2 to U succeeds; U's completion is then refused; V completes" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)
      unassign!(ctx, n2_task)

      assert {:ok, assigned} =
               Tasks.assign_task(n2_task.id, %{user_id: ctx.u.id}, prefix: ctx.schema_name)

      assert {assigned.assignee_type, assigned.assignee_ref} == {"USER", ctx.u.id}

      assert {:error, :separation_of_duties} = S.complete(ctx, n2_task, ctx.u.id, %{})
      assert {:ok, _} = S.complete(ctx, n2_task, ctx.v.id, %{})
    end
  end

  # Fixture write: no authoring path leaves a role-bearing HUMAN_TASK unassigned.
  defp unassign!(ctx, task) do
    from(t in EngineTask, where: t.id == ^task.id)
    |> Repo.update_all([set: [assignee_type: nil, assignee_ref: nil]], prefix: ctx.schema_name)
  end

  defp assign_fixture!(ctx, task, type, ref) do
    from(t in EngineTask, where: t.id == ^task.id)
    |> Repo.update_all([set: [assignee_type: type, assignee_ref: ref]], prefix: ctx.schema_name)
  end

  # ---------------------------------------------------------------------------------
  # A-3 -- the claim path
  # ---------------------------------------------------------------------------------

  describe "A-3 -- claim_task/3" do
    test "U's claim of the ROLE-assigned N2 is refused; nothing is written and NO audit row; V claims" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)
      before = S.rows(ctx)
      audit_before = S.audit_count(ctx.schema_name)

      assert {:error, :separation_of_duties} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)

      assert S.rows(ctx) == before
      assert S.audit_count(ctx.schema_name) == audit_before
      assert S.refusal_rows(ctx.schema_name) == []

      assert {S.reload_task!(ctx, n2_task).assignee_type,
              S.reload_task!(ctx, n2_task).assignee_ref} ==
               {"ROLE", "role-b"}

      assert {:ok, claimed} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.v.id}, prefix: ctx.schema_name)

      assert {claimed.assignee_type, claimed.assignee_ref} == {"USER", ctx.v.id}
    end

    test "the unassigned clause is guarded: U refused, V claims" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)
      unassign!(ctx, n2_task)

      assert {:error, :separation_of_duties} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)

      assert S.reload_task!(ctx, n2_task).assignee_ref == nil

      assert {:ok, _} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.v.id}, prefix: ctx.schema_name)
    end

    test "the GROUP-assigned clause is guarded: a member who completed N1 is refused, another member claims" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)
      %{group_id: group_id} = group_of_role!(ctx, "role-b")
      assign_fixture!(ctx, n2_task, "GROUP", group_id)

      assert {:error, :separation_of_duties} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)

      assert {:ok, _} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.v.id}, prefix: ctx.schema_name)
    end

    test "the idempotent re-claim clause is guarded: N2 already assigned to U (reassign does not check), U's re-claim is refused" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)
      {:ok, _} = Tasks.reassign_task(n2_task.id, %{user_id: ctx.u.id}, prefix: ctx.schema_name)

      assert {:error, :separation_of_duties} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)

      assert S.refusal_rows(ctx.schema_name) == []

      # control: the re-claim of the user the rule does not block is still an idempotent success
      {:ok, _} = Tasks.reassign_task(n2_task.id, %{user_id: ctx.v.id}, prefix: ctx.schema_name)

      assert {:ok, again} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.v.id}, prefix: ctx.schema_name)

      assert again.assignee_ref == ctx.v.id
    end

    test "eligibility refusals come FIRST: a caller who completed N1 but holds the wrong role gets the existing refusal, not the separation one" do
      ctx = seq_case!()
      # W holds role-a and role-c but not role-b, and is the N1 completer
      S.complete_node!(ctx, @n1, ctx.w.id, %{})
      n2_task = S.pending_task!(ctx, @n2)

      assert {:error, :assignee_role_not_held} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.w.id}, prefix: ctx.schema_name)
    end

    test "eligibility refusals come FIRST: N2 assigned to another user, U (N1 completer) gets :assigned_to_other_user" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)
      {:ok, _} = Tasks.reassign_task(n2_task.id, %{user_id: ctx.v.id}, prefix: ctx.schema_name)

      assert {:error, :assigned_to_other_user} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)
    end

    test "default-off: a definition without distinct_from gains no claim failure (U completed N1 and still claims N2)" do
      ctx = seq_case!(%{})
      S.complete_node!(ctx, @n1, ctx.u.id, %{})

      assert {:ok, claimed} =
               Tasks.claim_task(S.pending_task!(ctx, @n2).id, %{actor_id: ctx.u.id},
                 prefix: ctx.schema_name
               )

      assert claimed.assignee_ref == ctx.u.id
    end
  end

  defp group_of_role!(ctx, role_name) do
    Letflow.Identity.TenantRole
    |> where([r], r.name == ^role_name)
    |> select([r], %{group_id: r.group_id})
    |> Repo.one!(prefix: ctx.schema_name)
  end

  describe "A-3a -- check_for_claim/3 is total and fails open" do
    test "snapshot row missing: :ok, exactly ONE warning naming only the task id and a tag, and the eligible claim succeeds" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)

      # control: with the snapshot present the same actor IS refused (so the :ok below is the fail-open)
      assert {:error, :separation_of_duties} =
               check_for_claim_in_txn(n2_task, ctx.u.id, ctx.schema_name)

      from(s in InstanceDefinitionSnapshot, where: s.instance_id == ^ctx.instance_id)
      |> Repo.delete_all(prefix: ctx.schema_name)

      {result, log} =
        with_log([level: :warning], fn ->
          SeparationOfDuties.check_for_claim(n2_task, ctx.u.id, ctx.schema_name)
        end)

      assert result == :ok
      assert_one_fail_open_warning!(ctx, n2_task, log, ":snapshot_not_found")

      {claim, claim_log} =
        with_log([level: :warning], fn ->
          Tasks.claim_task(n2_task.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)
        end)

      assert {:ok, claimed} = claim
      assert claimed.assignee_ref == ctx.u.id
      assert_one_fail_open_warning!(ctx, n2_task, claim_log, ":snapshot_not_found")
    end

    test "a snapshot graph that build_graph/1 rejects: :ok, one warning tagged :graph_structure_invalid, the claim succeeds" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)

      from(s in InstanceDefinitionSnapshot, where: s.instance_id == ^ctx.instance_id)
      |> Repo.update_all([set: [graph: %{"nodes" => "not-a-list"}]], prefix: ctx.schema_name)

      {result, log} =
        with_log([level: :warning], fn ->
          SeparationOfDuties.check_for_claim(n2_task, ctx.u.id, ctx.schema_name)
        end)

      assert result == :ok
      assert_one_fail_open_warning!(ctx, n2_task, log, ":graph_structure_invalid")

      assert {:ok, _} =
               Tasks.claim_task(n2_task.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)
    end

    test "a database error while loading the snapshot (unknown tenant schema): :ok, one warning tagged :raised, never raises" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)

      {result, log} =
        with_log([level: :warning], fn ->
          SeparationOfDuties.check_for_claim(n2_task, ctx.u.id, "req463_no_such_schema")
        end)

      assert result == :ok
      assert_one_fail_open_warning!(ctx, n2_task, log, ":raised")
    end

    test "a DB error of the snapshot read INSIDE claim_task/3's transaction is confined by a savepoint: the eligible claim succeeds, one warning, the claim row is written (F-1)" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)

      # DDL is transactional in Postgres: the rename is undone by the sandbox rollback.
      Repo.query!(
        ~s(ALTER TABLE "#{ctx.schema_name}".instance_definition_snapshots RENAME TO req463_snapshots_gone)
      )

      {claim, log} =
        with_log([level: :warning], fn ->
          Tasks.claim_task(n2_task.id, %{actor_id: ctx.u.id}, prefix: ctx.schema_name)
        end)

      assert {:ok, claimed} = claim
      assert {claimed.assignee_type, claimed.assignee_ref} == {"USER", ctx.u.id}
      assert_one_fail_open_warning!(ctx, n2_task, log, ":raised")

      reloaded = S.reload_task!(ctx, n2_task)
      assert {reloaded.assignee_type, reloaded.assignee_ref} == {"USER", ctx.u.id}
    end

    test "a non-task first argument is :ok too (total, the catch-all clause)" do
      assert :ok == SeparationOfDuties.check_for_claim(nil, Ecto.UUID.generate(), "any_prefix")
    end
  end

  # check_for_claim/3 runs inside claim_task/3's transaction (its query uses `mode: :savepoint`,
  # which needs one); a direct call that expects a REFUSAL therefore wraps it in a transaction.
  defp check_for_claim_in_txn(task, actor_id, prefix) do
    {:ok, result} =
      Repo.transaction(fn -> SeparationOfDuties.check_for_claim(task, actor_id, prefix) end)

    result
  end

  defp assert_one_fail_open_warning!(ctx, task, log, tag) do
    assert length(Regex.scan(~r/claim check failed open/, log)) == 1
    assert log =~ task.id
    assert log =~ tag

    # names only the task id and the failure tag: no user, node, instance, email or name
    for forbidden <- [
          ctx.u.id,
          ctx.v.id,
          ctx.u.email,
          ctx.u.display_name,
          ctx.u.username,
          @n1,
          @n2,
          ctx.instance_id
        ] do
      refute log =~ forbidden, "the fail-open warning leaked #{inspect(forbidden)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # A-12 -- default off
  # ---------------------------------------------------------------------------------

  describe "A-12 -- default off" do
    test "a node with no distinct_from, a null one and an empty one: the same user completes both steps as today" do
      for attrs <- [%{}, %{"distinct_from" => nil}, %{"distinct_from" => []}] do
        ctx = seq_case!(attrs)
        S.complete_node!(ctx, @n1, ctx.u.id, %{})

        assert {:ok, %{instance_status: :completed}} =
                 S.complete(ctx, S.pending_task!(ctx, @n2), ctx.u.id, %{}),
               "distinct_from #{inspect(attrs)} must be off"

        assert S.refusal_rows(ctx.schema_name) == []
      end
    end

    test "regression on a SHIPPED definition (Meridian loan origination): one user completes credit-memo-review and risk-assessment" do
      doc =
        @qa
        |> Path.join("meridian_loan_origination_process_definition.json")
        |> File.read!()
        |> Jason.decode!()

      for node_id <- ["credit-memo-review", "risk-assessment"] do
        node = Enum.find(doc["graph"]["nodes"], &(&1["id"] == node_id))

        refute Map.has_key?(node["attributes"] || %{}, "distinct_from"),
               "#{node_id} now carries distinct_from (REQ-465 adopted it?): retarget this regression to a node the rule does not guard"
      end

      tenant = S.tenant!()

      entries =
        Enum.map(doc["variable_schemas"], fn e ->
          %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
        end)

      {:ok, definition} =
        Definitions.create_with_variable_schemas(
          %{
            name: S.unique("req463-meridian"),
            version: doc["version"],
            graph: doc["graph"],
            created_by: Ecto.UUID.generate()
          },
          entries,
          prefix: tenant.schema_name
        )

      {:ok, %{definition: active}} =
        Definitions.activate(definition.id, prefix: tenant.schema_name)

      instance_id =
        S.start_instance!(tenant.schema_name, active, %{
          "application_id" => "app-463",
          "requested_amount_eur" => 100_000
        })

      ctx = Map.put(tenant, :instance_id, instance_id)
      user = S.insert_user!(tenant.schema_name, "shipped")
      advance_kyc_clear!(ctx)

      assert {:ok, _} =
               S.complete(
                 ctx,
                 S.pending_task!(ctx, "credit-memo-review"),
                 user.id,
                 %{"credit_decision" => "pass"}
               )

      assert {:ok, _} =
               S.complete(
                 ctx,
                 S.pending_task!(ctx, "risk-assessment"),
                 user.id,
                 %{"risk_rating" => "low"}
               )

      assert S.refusal_rows(tenant.schema_name) == []
    end

    test "query count: a completion of a node with distinct_from absent, null or [] costs the same queries; a guarded node costs exactly one more" do
      counts =
        for attrs <- [%{}, %{"distinct_from" => nil}, %{"distinct_from" => []}] do
          ctx = seq_case!(attrs)
          S.complete_node!(ctx, @n1, ctx.u.id, %{})
          task = S.pending_task!(ctx, @n2)
          {{:ok, _}, count} = count_queries(fn -> S.complete(ctx, task, ctx.v.id, %{}) end)
          count
        end

      [absent, null, empty] = counts
      assert absent > 0
      assert null == absent
      assert empty == absent

      guarded = seq_case!(%{"distinct_from" => [@n1]})
      S.complete_node!(guarded, @n1, guarded.u.id, %{})
      guarded_task = S.pending_task!(guarded, @n2)

      {{:ok, _}, guarded_count} =
        count_queries(fn -> S.complete(guarded, guarded_task, guarded.v.id, %{}) end)

      assert guarded_count == absent + 1
    end

    test "SeparationOfDuties.check/5 itself: zero queries when the rule is off or the actor is not a binary uuid; exactly one when guarded" do
      # attribute absent / null / empty: the SAME actor who completed N1 is accepted, with no query
      for attrs <- [%{}, %{"distinct_from" => nil}, %{"distinct_from" => []}] do
        off = seq_case!(attrs)
        S.complete_node!(off, @n1, off.u.id, %{})
        off_task = S.pending_task!(off, @n2)
        assert {:ok, 0} == zero_or_more(snapshot_graph!(off), off_task, off.u.id, off)
      end

      guarded = seq_case!()
      S.complete_node!(guarded, @n1, guarded.u.id, %{})
      guarded_task = S.pending_task!(guarded, @n2)
      graph = snapshot_graph!(guarded)

      for actor <- [nil, 123, "not-a-uuid"] do
        assert {:ok, 0} == zero_or_more(graph, guarded_task, actor, guarded)
      end

      assert {{:error, {:separation_of_duties, [@n1]}}, 1} ==
               count_queries(fn ->
                 SeparationOfDuties.check(
                   Repo,
                   graph,
                   guarded_task,
                   guarded.u.id,
                   guarded.schema_name
                 )
               end)

      assert {:ok, 1} == zero_or_more(graph, guarded_task, guarded.v.id, guarded)
    end
  end

  defp zero_or_more(graph, task, actor, ctx) do
    {result, count} =
      count_queries(fn -> SeparationOfDuties.check(Repo, graph, task, actor, ctx.schema_name) end)

    {result, count}
  end

  defp advance_kyc_clear!(ctx) do
    [row] =
      ServiceTaskDispatch
      |> where([d], d.instance_id == ^ctx.instance_id and d.node_id == "kyc-aml-check")
      |> Repo.all(prefix: ctx.schema_name)

    row =
      row |> Ecto.Changeset.change(%{status: :advanced}) |> Repo.update!(prefix: ctx.schema_name)

    {:ok, :advanced} =
      Engine.advance_after_service_task_outcome(
        row.id,
        {:advance, %{"kyc_status" => "clear"}},
        Repo,
        ctx.schema_name
      )
  end

  # ---------------------------------------------------------------------------------
  # A-13 -- replay of an accepted completion
  # ---------------------------------------------------------------------------------

  describe "A-13 -- re-completing an already-accepted completion ends at step 1" do
    test "a user who would be refused by the rule if the guards ran still gets {:task_not_pending, :completed} and no refusal record" do
      ctx = case!(S.rework_graph(), %{}, %{"seed" => 1})
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      S.complete_node!(ctx, "triage-review", ctx.w.id, %{"again" => "no"})
      first_n2 = S.pending_task!(ctx, @n2)
      assert {:ok, _} = S.complete(ctx, first_n2, ctx.v.id, %{"redo" => "yes"})

      # redo loop: V now completes the second pass of N1, so V is the MOST RECENT N1 completer
      S.complete_node!(ctx, @n1, ctx.v.id, %{})
      S.complete_node!(ctx, "triage-review", ctx.w.id, %{"again" => "no"})
      second_n2 = S.pending_task!(ctx, @n2)
      assert second_n2.id != first_n2.id

      # control: V is refused on the live N2 row (so the rule WOULD refuse V)
      assert {:error, :separation_of_duties} = S.complete(ctx, second_n2, ctx.v.id, %{})
      refusals_before = length(S.refusal_rows(ctx.schema_name))
      assert refusals_before == 1

      # replay of V's accepted first-pass completion: step 1, not the guards
      assert {:error, {:task_not_pending, :completed}} = S.complete(ctx, first_n2, ctx.v.id, %{})
      assert length(S.refusal_rows(ctx.schema_name)) == refusals_before
    end
  end

  # ---------------------------------------------------------------------------------
  # Order -- 4b (separation) before 4c (required outputs)
  # ---------------------------------------------------------------------------------

  describe "design 2.2 -- step 4b precedes step 4c" do
    test "a completion violating BOTH rules is refused as separation of duties, not output_refused; once V supplies the key, rule C is live" do
      ctx =
        case!(
          S.seq_graph(%{"distinct_from" => [@n1], "required_outputs" => ["decision"]}),
          %{"decision" => %{"type" => "string"}},
          %{"seed" => 1}
        )

      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)

      assert {:error, :separation_of_duties} = S.complete(ctx, n2_task, ctx.u.id, %{})
      assert [entry] = S.refusal_rows(ctx.schema_name)
      assert entry.after_state["rule"] == "separation_of_duties"

      # V (not blocked) with the key missing: rule C answers, so the order test is not vacuous
      assert {:error, {:output_refused, %{missing_keys: ["decision"], rejected_keys: []}}} =
               S.complete(ctx, n2_task, ctx.v.id, %{})

      assert {:ok, _} = S.complete(ctx, n2_task, ctx.v.id, %{"decision" => "approved"})
    end
  end

  # ---------------------------------------------------------------------------------
  # A-15 -- audit-write robustness (DROP-TABLE regression)
  # ---------------------------------------------------------------------------------

  describe "A-15 -- the audit store is unavailable" do
    test "the refusal is the same {:error, :separation_of_duties}, does not raise, logs exactly one warning; state untouched" do
      ctx = seq_case!()
      S.complete_node!(ctx, @n1, ctx.u.id, %{})
      n2_task = S.pending_task!(ctx, @n2)
      before = S.rows(ctx)

      Repo.query!(~s(DROP TABLE "#{ctx.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{ctx.schema_name}".audit_entries (
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

      {result, log} = with_log(fn -> S.complete(ctx, n2_task, ctx.u.id, %{}) end)

      assert result == {:error, :separation_of_duties}
      assert S.rows(ctx) == before

      assert length(Regex.scan(~r/recording task\.completion_refused/, log)) == 1
      assert log =~ n2_task.id
      refute log =~ ctx.u.email
      refute log =~ ctx.u.display_name
    end
  end
end
