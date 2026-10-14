defmodule Letflow.Engine.Gh2359GatewayReentryTaskRowTest do
  @moduledoc """
  GH #2359 / ISS-1035 regression suite: a token that completes (or is escalated off)
  a HUMAN_TASK at node A and is routed `A -> EXCLUSIVE_GATEWAY -default-> A` within the
  same hop chain must get exactly ONE new `:pending` `tasks` row, and exactly one live
  escalation timer belonging to it. Before the fix the diff in
  `TaskActivation.newly_pending_tokens/2` masked the re-entry (the stale
  `{token, node}` pair was still in `previous`), so the instance stalled `:active`
  with zero pending tasks.

  Design and test matrix: `lib/letflow/design/gh2359-gateway-reentry-task-row.md`
  section 8 (T-1..T-14; T-3 withdrawn; the pure helper cases T-13 live in
  `test/letflow/engine/task_activation_test.exs`).

  Real Postgres, `async: false` (tenant provisioning), no wall-clock dependence: timers
  are fired directly via `Scheduler.fire_timer/2`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.SodSupport, as: S
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Graph fixtures
  # ---------------------------------------------------------------------------------

  defp ht(id), do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r"}}

  defp ht_escalating(id, duration) do
    %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => %{
        "role" => "r",
        "escalation_timer_duration" => duration,
        "escalation_role" => "r-escalated"
      }
    }
  end

  defp gw(id), do: %{"id" => id, "node_type" => "EXCLUSIVE_GATEWAY"}
  defp start_node, do: %{"id" => "start", "node_type" => "START"}
  defp end_node, do: %{"id" => "end", "node_type" => "END"}

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp cond_edge(id, source, target, condition),
    do: %{"id" => id, "source" => source, "target" => target, "condition" => condition}

  defp default_edge(id, source, target),
    do: %{"id" => id, "source" => source, "target" => target, "is_default" => true}

  # start -> a -> gw ; gw -[approved==true]-> end ; gw -[default]-> a
  defp direct_graph(a_node) do
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

  # start -> a -> b -> gw ; gw -[approved==true]-> end ; gw -[default]-> a
  defp via_b_graph do
    %{
      "nodes" => [start_node(), ht("a"), ht("b"), gw("gw"), end_node()],
      "edges" => [
        edge("e1", "start", "a"),
        edge("e2", "a", "b"),
        edge("e5", "b", "gw"),
        cond_edge("e3", "gw", "end", "variables.approved == true"),
        default_edge("e4", "gw", "a")
      ]
    }
  end

  # start -> split ; split -> gw1 -> a ; split -> gw2 -> a ; a -> gwr ;
  # gwr -[approved==true]-> end ; gwr -[default]-> a
  defp parallel_graph do
    %{
      "nodes" => [
        start_node(),
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        gw("gw1"),
        gw("gw2"),
        ht("a"),
        gw("gwr"),
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        end_node()
      ],
      "edges" => [
        edge("e1", "start", "split"),
        edge("e2", "split", "gw1"),
        edge("e3", "split", "gw2"),
        default_edge("e4", "gw1", "a"),
        default_edge("e5", "gw2", "a"),
        edge("e6", "a", "gwr"),
        cond_edge("e7", "gwr", "join", "variables.approved == true"),
        cond_edge("e9", "gwr", "join", "variables.skip == true"),
        default_edge("e8", "gwr", "a"),
        edge("e10", "join", "end")
      ]
    }
  end

  # ---------------------------------------------------------------------------------
  # Case / row helpers (no optional arguments, anti-patterns ISS-0069)
  # ---------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp tenant_schema! do
    %{schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "gh2359", display_name: "GH2359 Test Tenant")

    schema
  end

  defp activate!(schema, graph, name_prefix) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: unique(name_prefix),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema)
    activated
  end

  defp start_instance!(schema, definition, initial_variables) do
    {:ok, created} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: initial_variables,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("gh2359-start")
        },
        prefix: schema
      )

    %{schema_name: schema, instance_id: created.instance_id}
  end

  defp new_case!(graph, initial_variables) do
    schema = tenant_schema!()
    definition = activate!(schema, graph, "gh2359-def")
    start_instance!(schema, definition, initial_variables)
  end

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

  defp pending(tasks), do: Enum.filter(tasks, &(&1.status == :pending))

  defp statuses(rows), do: Enum.map(rows, & &1.status)

  defp reload_task!(ctx, task), do: Repo.get!(EngineTask, task.id, prefix: ctx.schema_name)

  defp complete(ctx, task, output) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: output,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique("gh2359-complete")
      },
      prefix: ctx.schema_name
    )
  end

  defp projection!(ctx),
    do: Repo.get!(InstanceProjection, ctx.instance_id, prefix: ctx.schema_name)

  defp escalation_timers(ctx) do
    Timer
    |> where([t], t.instance_id == ^ctx.instance_id and t.timer_type == "escalation")
    |> order_by([t], asc: t.created_at, asc: t.id)
    |> Repo.all(prefix: ctx.schema_name)
  end

  defp event_count(ctx) do
    Repo.aggregate(from(e in Event, where: e.instance_id == ^ctx.instance_id), :count,
      prefix: ctx.schema_name
    )
  end

  # INV-3: at most one :pending row per {token_id, node_id}.
  defp assert_no_duplicate_pending!(ctx) do
    keys = ctx |> all_tasks() |> pending() |> Enum.map(&{&1.token_id, &1.node_id})

    assert keys == Enum.uniq(keys),
           "two :pending task rows share (token_id, node_id): #{inspect(keys)}"
  end

  # ---------------------------------------------------------------------------------
  # T-1, T-2, T-4 .. T-11, T-14
  # ---------------------------------------------------------------------------------

  describe "gateway re-entry" do
    test "direct loop A -> gw -> A creates a new pending task for A" do
      ctx = new_case!(direct_graph(ht("a")), %{})
      assert [r1] = tasks_at(ctx, "a")

      assert {:ok, _} = complete(ctx, r1, %{"approved" => false})

      rows = tasks_at(ctx, "a")
      assert length(rows) == 2, "expected exactly one new row, got #{inspect(statuses(rows))}"
      assert [new_row] = pending(rows)
      assert new_row.id != r1.id
      assert new_row.token_id == r1.token_id
      assert reload_task!(ctx, r1).status == :completed
      assert_no_duplicate_pending!(ctx)

      assert projection!(ctx).status == :active

      assert [%TokenRecord{node_id: "a", status: :active}] =
               Repo.all(from(t in TokenRecord, where: t.instance_id == ^ctx.instance_id),
                 prefix: ctx.schema_name
               )

      # the new row is actually completable and finishes the instance
      assert {:ok, %{instance_status: :completed}} = complete(ctx, new_row, %{"approved" => true})
      assert pending(all_tasks(ctx)) == []
    end

    test "control A -> B -> gw -> A still creates a new A row" do
      ctx = new_case!(via_b_graph(), %{})
      assert [a1] = tasks_at(ctx, "a")
      assert {:ok, _} = complete(ctx, a1, %{"approved" => false})
      assert [b1] = tasks_at(ctx, "b")
      assert {:ok, _} = complete(ctx, b1, %{"approved" => false})

      assert [:completed, :pending] = statuses(tasks_at(ctx, "a"))
      assert [:completed] = statuses(tasks_at(ctx, "b"))
      assert_no_duplicate_pending!(ctx)
    end

    test "create/2 still materializes exactly one row per initial HUMAN_TASK" do
      direct = new_case!(direct_graph(ht("a")), %{})
      assert [%{status: :pending}] = all_tasks(direct)

      via_gw =
        new_case!(
          %{
            "nodes" => [start_node(), gw("gw"), ht("a"), end_node()],
            "edges" => [
              edge("e1", "start", "gw"),
              default_edge("e2", "gw", "a"),
              edge("e3", "a", "end")
            ]
          },
          %{}
        )

      assert [%{node_id: "a", status: :pending}] = all_tasks(via_gw)
    end

    test "parallel sibling pending at same node is not re-inserted" do
      ctx = new_case!(parallel_graph(), %{})
      assert [s1, s2] = initial = tasks_at(ctx, "a")
      assert length(pending(initial)) == 2
      assert s1.token_id != s2.token_id

      assert {:ok, _} = complete(ctx, s1, %{"approved" => false})

      rows = tasks_at(ctx, "a")
      assert length(rows) == 3, "expected 3 rows at a, got #{inspect(statuses(rows))}"

      assert reload_task!(ctx, s1).status == :completed
      assert reload_task!(ctx, s2).status == :pending

      assert [new_row] = Enum.reject(pending(rows), &(&1.id == s2.id))
      assert new_row.token_id == s1.token_id
      assert_no_duplicate_pending!(ctx)
    end

    test "replaying complete_task on the old row creates no duplicate" do
      ctx = new_case!(direct_graph(ht("a")), %{})
      assert [r1] = tasks_at(ctx, "a")
      assert {:ok, _} = complete(ctx, r1, %{"approved" => false})

      events_before = event_count(ctx)

      assert {:error, {:task_not_pending, :completed}} = complete(ctx, r1, %{"approved" => false})

      assert length(tasks_at(ctx, "a")) == 2
      assert length(pending(tasks_at(ctx, "a"))) == 1
      assert event_count(ctx) == events_before
    end

    test "escalation fire with default edge back to A creates a new A task" do
      ctx = new_case!(direct_graph(ht_escalating("a", "P0D")), %{"approved" => false})

      assert [r1] = tasks_at(ctx, "a")
      assert [e1] = escalation_timers(ctx)
      assert e1.status == "pending"

      assert {:ok, :fired} = Scheduler.fire_timer(e1.id, ctx.schema_name)

      assert reload_task!(ctx, r1).status == :cancelled
      rows = tasks_at(ctx, "a")
      assert length(rows) == 2
      assert [new_row] = pending(rows)
      assert new_row.id != r1.id
      assert_no_duplicate_pending!(ctx)

      # fresh timer for the new row; the fired one stays fired
      timers = escalation_timers(ctx)
      assert Enum.find(timers, &(&1.id == e1.id)).status == "fired"
      assert [e2] = Enum.filter(timers, &(&1.status == "pending"))
      assert e2.id != e1.id
      assert e2.token_id == r1.token_id
      assert e2.node_id == "a"
    end

    test "re-entry arms a fresh escalation timer" do
      ctx = new_case!(direct_graph(ht_escalating("a", "PT1H")), %{})
      assert [r1] = tasks_at(ctx, "a")
      assert [e1] = escalation_timers(ctx)

      assert {:ok, _} = complete(ctx, r1, %{"approved" => false})

      assert [new_row] = pending(tasks_at(ctx, "a"))
      assert new_row.id != r1.id
      assert_no_duplicate_pending!(ctx)

      assert [e2] = Enum.reject(escalation_timers(ctx), &(&1.id == e1.id))
      assert e2.timer_type == "escalation"
      assert e2.status == "pending"
      assert e2.token_id == e1.token_id
      assert e2.node_id == "a"
      assert DateTime.compare(e2.fire_at, e1.created_at) == :gt
    end

    test "cancel_pending_escalation_timers does not cancel the new timer" do
      ctx = new_case!(direct_graph(ht_escalating("a", "PT1H")), %{})
      assert [r1] = tasks_at(ctx, "a")
      assert [e1] = escalation_timers(ctx)

      assert {:ok, _} = complete(ctx, r1, %{"approved" => false})

      timers = escalation_timers(ctx)
      old = Enum.find(timers, &(&1.id == e1.id))
      assert old.status == "cancelled"
      assert old.cancel_reason == "task_completed"

      assert [e2] = Enum.filter(timers, &(&1.status == "pending"))
      assert e2.id != e1.id
      assert [r2] = pending(tasks_at(ctx, "a"))

      # the surviving timer escalates the NEW task, not a stale consume
      assert {:ok, :fired} = Scheduler.fire_timer(e2.id, ctx.schema_name)
      assert reload_task!(ctx, r2).status == :cancelled
      assert [r3] = pending(tasks_at(ctx, "a"))
      assert r3.id not in [r1.id, r2.id]
      assert_no_duplicate_pending!(ctx)
    end

    test "a plain A -> B completion still cancels A's escalation timer (ISS-0925 guard)" do
      ctx =
        new_case!(
          %{
            "nodes" => [start_node(), ht_escalating("a", "PT1H"), ht("b"), end_node()],
            "edges" => [edge("e1", "start", "a"), edge("e2", "a", "b"), edge("e3", "b", "end")]
          },
          %{}
        )

      assert [r1] = tasks_at(ctx, "a")
      assert [e1] = escalation_timers(ctx)
      assert {:ok, _} = complete(ctx, r1, %{})

      assert [%{status: "cancelled", cancel_reason: "task_completed"} = after_timer] =
               escalation_timers(ctx)

      assert after_timer.id == e1.id
    end

    test "timer completion TIMER -> gw -> A still creates the A row" do
      ctx =
        new_case!(
          %{
            "nodes" => [
              start_node(),
              ht("a"),
              %{
                "id" => "tmr",
                "node_type" => "TIMER",
                "attributes" => %{"duration_iso8601" => "PT1H"}
              },
              gw("gw"),
              end_node()
            ],
            "edges" => [
              edge("e1", "start", "a"),
              edge("e2", "a", "tmr"),
              edge("e3", "tmr", "gw"),
              cond_edge("e4", "gw", "end", "variables.approved == true"),
              default_edge("e5", "gw", "a")
            ]
          },
          %{}
        )

      assert [r1] = tasks_at(ctx, "a")
      assert {:ok, _} = complete(ctx, r1, %{"approved" => false})
      assert pending(tasks_at(ctx, "a")) == []

      [timer] =
        Repo.all(
          from(t in Timer,
            where:
              t.instance_id == ^ctx.instance_id and t.node_id == "tmr" and t.status == "pending"
          ),
          prefix: ctx.schema_name
        )

      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema_name)

      rows = tasks_at(ctx, "a")
      assert length(rows) == 2
      assert [%{id: new_id}] = pending(rows)
      assert new_id != r1.id
      assert_no_duplicate_pending!(ctx)
    end

    test "A -> SUB_PROCESS(sync child) -> gw -> A creates a new A row" do
      schema = tenant_schema!()

      child =
        activate!(
          schema,
          %{"nodes" => [start_node(), end_node()], "edges" => [edge("e1", "start", "end")]},
          "gh2359-child"
        )

      parent =
        activate!(
          schema,
          %{
            "nodes" => [
              start_node(),
              ht("a"),
              %{
                "id" => "sp",
                "node_type" => "SUB_PROCESS",
                "attributes" => %{"definition_name" => child.name}
              },
              gw("gw"),
              end_node()
            ],
            "edges" => [
              edge("e1", "start", "a"),
              edge("e2", "a", "sp"),
              edge("e3", "sp", "gw"),
              cond_edge("e4", "gw", "end", "variables.approved == true"),
              default_edge("e5", "gw", "a")
            ]
          },
          "gh2359-parent"
        )

      ctx = start_instance!(schema, parent, %{})
      assert [r1] = tasks_at(ctx, "a")
      assert {:ok, _} = complete(ctx, r1, %{"approved" => false})

      rows = tasks_at(ctx, "a")
      assert length(rows) == 2, "expected one new row, got #{inspect(statuses(rows))}"
      assert [new_row] = pending(rows)
      assert new_row.id != r1.id
      assert_no_duplicate_pending!(ctx)
    end

    test "execution_error leaves the task pending and untouched" do
      # CHK-24 rejects a gateway with no default edge at create time; a definition
      # activated before that check keeps running (REQ-455 OQ-1), so simulate it by
      # overwriting the stored graph of a trivially valid activated definition
      # (same technique as test/letflow/engine_execution_error_test.exs).
      schema = tenant_schema!()

      trivial =
        activate!(
          schema,
          %{"nodes" => [start_node(), end_node()], "edges" => [edge("e1", "start", "end")]},
          "gh2359-legacy"
        )

      legacy_graph = %{
        "nodes" => [start_node(), ht("a"), gw("gw"), end_node()],
        "edges" => [
          edge("e1", "start", "a"),
          edge("e2", "a", "gw"),
          cond_edge("e3", "gw", "end", "variables.ok == true")
        ]
      }

      {1, _} =
        from(d in Definitions.ProcessDefinition, where: d.id == ^trivial.id)
        |> Repo.update_all([set: [graph: legacy_graph]], prefix: schema)

      ctx = start_instance!(schema, trivial, %{})

      assert [r1] = tasks_at(ctx, "a")

      assert {:error, {:instance_execution_error, :no_matching_gateway_edge, {:node, "gw"}}} =
               complete(ctx, r1, %{"ok" => false})

      assert reload_task!(ctx, r1).status == :pending
      assert [_only] = all_tasks(ctx)

      projection = projection!(ctx)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "no_matching_gateway_edge"
      assert projection.current_nodes == ["a"]

      assert {:error, {:instance_not_active, :error}} = complete(ctx, r1, %{"ok" => true})
      assert reload_task!(ctx, r1).status == :pending
    end
  end

  # ---------------------------------------------------------------------------------
  # T-12 -- distinct_from compares against the re-entered (newest) completion
  # ---------------------------------------------------------------------------------

  describe "gateway re-entry with distinct_from (REQ-463 interaction)" do
    test "distinct_from compares against the re-entered (newest) completion" do
      graph = %{
        "nodes" => [
          start_node(),
          S.human("first-review", "role-a", %{}),
          gw("gw1"),
          S.human("second-review", "role-b", %{"distinct_from" => ["first-review"]}),
          end_node()
        ],
        "edges" => [
          edge("e1", "start", "first-review"),
          edge("e2", "first-review", "gw1"),
          cond_edge("e3", "gw1", "first-review", "variables.again == \"yes\""),
          default_edge("e4", "gw1", "second-review"),
          edge("e5", "second-review", "end")
        ]
      }

      ctx = S.new_case!(graph, %{}, %{})
      u1 = S.insert_user!(ctx.schema_name, "u1")
      u2 = S.insert_user!(ctx.schema_name, "u2")
      S.grant_role!(ctx.schema_name, "role-a", [u1.id, u2.id])
      S.grant_role!(ctx.schema_name, "role-b", [u1.id, u2.id])

      # (1) U1 completes R1 with again=yes -> a NEW first-review row exists (the fix)
      r1 = S.pending_task!(ctx, "first-review")
      assert {:ok, _} = S.complete(ctx, r1, u1.id, %{"again" => "yes"})
      r2 = S.pending_task!(ctx, "first-review")
      assert r2.id != r1.id

      # (2) U2 completes R2 with again=no -> second-review row pending
      assert {:ok, _} = S.complete(ctx, r2, u2.id, %{"again" => "no"})
      s1 = S.pending_task!(ctx, "second-review")

      # (3) newest first-review completer is U2 -> U2 refused, row untouched
      assert {:error, :separation_of_duties} = S.complete(ctx, s1, u2.id, %{})
      assert S.reload_task!(ctx, s1).status == :pending

      # (4) U1 (the OLDEST completer) is allowed and finishes the instance
      assert {:ok, %{instance_status: :completed}} = S.complete(ctx, s1, u1.id, %{})
    end
  end
end
