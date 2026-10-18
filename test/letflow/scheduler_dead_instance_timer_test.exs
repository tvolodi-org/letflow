defmodule Letflow.SchedulerDeadInstanceTimerTest do
  @moduledoc """
  GH #2707 PR-1 / GH #2822 (design `lib/letflow/design/gh2707-timer-fire-and-cold-appenders-lock-order.md`
  sections 6 and 8.2): a pending timer of a DEAD instance (cancelled, completed or errored) is
  settled by `Scheduler.fire_timer/2` -- every pending timer of the instance is cancelled with
  reason `instance_<status>` in one committed transaction, no TIMER_FIRED event, no failure count,
  no DLQ row -- instead of failing three times into the dead-letter queue (cancelled / completed)
  or being re-claimed on every tick forever (errored).

    * P1 / P2 / P3: a timer on a cancelled / completed / errored instance is settled by the first
      tick; the second tick claims nothing;
    * P4: head of line -- three timers of an errored instance older than a live due timer, with
      the claim limit at 3, no longer starve the live timer;
    * P5: settle is instance-wide (one attempt clears every pending timer of the instance);
    * P6: the `advance-timer` route answers 200 `already_final` (formerly 500);
    * the telemetry event, and an ACTIVE instance's timer firing unchanged.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.EventStore.Event
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Instances.init([])

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp past(seconds_ago),
    do:
      DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:microsecond)

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  # START -> h (HUMAN) -> END
  defp human_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "h", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "h"), edge("e2", "h", "end")]
    }
  end

  # START -> tmr (TIMER) -> h (HUMAN) -> END
  defp timer_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "PT1H"}
        },
        %{"id" => "h", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "tmr"), edge("e2", "tmr", "h"), edge("e3", "h", "end")]
    }
  end

  defp setup_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "gh2707-dead",
      display_name: "GH 2707 dead-instance timer tenant"
    )
  end

  defp start_instance!(schema, graph) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: unique("gh2707-def"),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema)

    {:ok, %{instance_id: id}} =
      Engine.create(
        %{
          definition_id: activated.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("gh2707-start")
        },
        prefix: schema
      )

    id
  end

  defp cancel!(schema, instance_id) do
    {:ok, _} =
      Engine.cancel_instance(
        instance_id,
        %{actor_id: Ecto.UUID.generate(), idempotency_key: unique("gh2707-cancel")},
        prefix: schema
      )
  end

  defp complete!(schema, instance_id) do
    task_id =
      Repo.one!(
        from(t in Engine.Task,
          where: t.instance_id == ^instance_id and t.status == :pending,
          select: t.id
        ),
        prefix: schema
      )

    {:ok, _} =
      Engine.complete_task(
        task_id,
        %{output_variables: %{}, actor_id: Ecto.UUID.generate(), idempotency_key: unique("c")},
        prefix: schema
      )
  end

  defp error!(schema, instance_id) do
    {:ok, _} =
      Engine.set_instance_error(
        %{
          instance_id: instance_id,
          error_type: :variable_schema_rejected,
          affected: {:field, "approved"},
          reason: "rejected",
          variables: %{},
          details: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("gh2707-err")
        },
        prefix: schema
      )
  end

  # a DUE pending timer row, armed as the engine arms one (no token: the dead instance has none)
  defp arm!(schema, instance_id, seconds_ago, node_id \\ "ghost") do
    {:ok, timer} =
      Scheduler.create(
        Repo,
        %{
          instance_id: instance_id,
          timer_type: "deadline",
          node_id: node_id,
          fire_at: past(seconds_ago)
        },
        prefix: schema
      )

    timer
  end

  defp reload(schema, timer), do: Repo.get!(Timer, timer.id, prefix: schema)

  defp dlq_timer_rows(schema),
    do: Repo.all(from(d in Dlq.Entry, where: d.entry_type == "timer"), prefix: schema)

  defp timer_fired_events(schema, instance_id) do
    Repo.all(
      from(e in Event, where: e.instance_id == ^instance_id and e.event_type == "TIMER_FIRED"),
      prefix: schema
    )
  end

  defp assert_settled!(schema, timer, reason) do
    reloaded = reload(schema, timer)
    assert reloaded.status == "cancelled"
    assert reloaded.cancel_reason == reason
    assert reloaded.fire_error_count == 0
    assert reloaded.cancelled_at != nil
  end

  defp assert_settled_once!(schema, instance_id, timer, reason) do
    assert %{claimed: 1, errored: 0, exhausted: 0, fired: 0} = Scheduler.poll_and_fire(schema)
    assert_settled!(schema, timer, reason)
    assert dlq_timer_rows(schema) == []
    assert timer_fired_events(schema, instance_id) == []

    # settled once: the next tick has nothing to claim
    assert %{claimed: 0} = Scheduler.poll_and_fire(schema)
  end

  describe "P1: a timer on a cancelled instance" do
    test "is settled by the first tick, never counted, never dead-lettered" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      cancel!(schema, x)
      timer = arm!(schema, x, 60)

      attach_settled_handler()

      assert_settled_once!(schema, x, timer, "instance_cancelled")

      assert_receive {:settled, %{count: 1},
                      %{tenant_schema: ^schema, reason: "instance_cancelled"}}
    end
  end

  describe "P2: a timer on a completed instance" do
    test "is settled with reason instance_completed" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, human_graph())
      complete!(schema, x)
      timer = arm!(schema, x, 60)

      assert_settled_once!(schema, x, timer, "instance_completed")
    end
  end

  describe "P3: a timer on an errored instance (formerly re-claimed on every tick forever)" do
    test "is settled with reason instance_error; every pending timer of the instance goes with it" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      engine_timer = hd(Repo.all(from(t in Timer, where: t.instance_id == ^x), prefix: schema))
      due = arm!(schema, x, 60)
      error!(schema, x)

      assert reload(schema, engine_timer).status == "pending"

      attach_settled_handler()

      assert_settled_once!(schema, x, due, "instance_error")
      assert_settled!(schema, engine_timer, "instance_error")

      # instance-wide: ONE settle announcement counting both timers
      assert_receive {:settled, %{count: 2}, %{reason: "instance_error"}}
      refute_receive {:settled, _, _}, 50
    end
  end

  describe "P4: head of line" do
    test "immortal timers of an errored instance no longer starve a live due timer" do
      %{schema_name: schema} = setup_tenant()

      original = Application.get_env(:letflow, :scheduler)
      Application.put_env(:letflow, :scheduler, max_timers_per_cycle: 3)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:letflow, :scheduler)
          val -> Application.put_env(:letflow, :scheduler, val)
        end
      end)

      dead = start_instance!(schema, human_graph())
      error!(schema, dead)
      old = for n <- 1..3, do: arm!(schema, dead, 600 + n, "old#{n}")

      live = start_instance!(schema, timer_graph())
      live_timer = hd(Repo.all(from(t in Timer, where: t.instance_id == ^live), prefix: schema))

      Repo.update_all(
        from(t in Timer, where: t.id == ^live_timer.id),
        [set: [fire_at: past(60)]],
        prefix: schema
      )

      # tick 1 claims the three oldest (all dead), settles them (instance-wide: one fire is enough)
      assert %{claimed: 3, fired: 0, errored: 0, exhausted: 0} = Scheduler.poll_and_fire(schema)
      for timer <- old, do: assert_settled!(schema, timer, "instance_error")
      assert reload(schema, live_timer).status == "pending"

      # tick 2 reaches the live timer
      assert %{claimed: 1, fired: 1} = Scheduler.poll_and_fire(schema)
      assert reload(schema, live_timer).status == "fired"
    end
  end

  describe "P5: instance-wide settle" do
    test "one fire attempt cancels every pending timer of the dead instance" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      cancel!(schema, x)
      first = arm!(schema, x, 60, "ghost1")
      second = arm!(schema, x, 30, "ghost2")

      assert {:ok, :already_final} = Scheduler.fire_timer(first.id, schema)

      assert_settled!(schema, first, "instance_cancelled")
      assert_settled!(schema, second, "instance_cancelled")
    end
  end

  describe "P6: the advance-timer route" do
    test "answers 200 already_final for a dead instance's timer (formerly 500)" do
      tenant = setup_tenant()
      schema = tenant.schema_name
      x = start_instance!(schema, timer_graph())
      cancel!(schema, x)
      timer = arm!(schema, x, 60)

      conn =
        conn(:post, "/#{x}/advance-timer")
        |> Map.put(:body_params, %{"timer_id" => timer.id})
        |> put_req_header("content-type", "application/json")
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: tenant.tenant_id,
          roles: ["PROCESS_OPERATOR"]
        })
        |> assign(:trace_id, "fixed-test-trace-id")
        |> Letflow.Routers.Instances.call(@opts)

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "instance_id" => x,
               "timer_id" => timer.id,
               "node_id" => "ghost",
               "timer_status" => "already_final"
             }

      assert_settled!(schema, timer, "instance_cancelled")
    end
  end

  describe "unchanged: a timer of an ACTIVE instance" do
    test "fires, appends TIMER_FIRED once and settles nothing" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      timer = hd(Repo.all(from(t in Timer, where: t.instance_id == ^x), prefix: schema))

      attach_settled_handler()

      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)
      assert reload(schema, timer).status == "fired"
      assert [_one] = timer_fired_events(schema, x)
      refute_receive {:settled, _, _}, 50
    end

    test "a second fire of the same timer is already_final" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      timer = hd(Repo.all(from(t in Timer, where: t.instance_id == ^x), prefix: schema))

      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)
      assert {:ok, :already_final} = Scheduler.fire_timer(timer.id, schema)
      assert [_one] = timer_fired_events(schema, x)
    end
  end

  # ---- telemetry ----------------------------------------------------------------------------

  defp attach_settled_handler do
    id = {__MODULE__, make_ref()}
    test_pid = self()

    on_exit(fn -> :telemetry.detach(id) end)

    :telemetry.attach(
      id,
      [:letflow, :scheduler, :timers_settled],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:settled, measurements, metadata})
      end,
      nil
    )

    :ok
  end
end
