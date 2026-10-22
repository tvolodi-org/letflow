defmodule Letflow.Engine.ReplayPathsNoEntityWriteTest do
  @moduledoc """
  GH #2646 (test gaps of the #2587 / REQ-499 PR B series, extended by the S10 comment of
  2026-10-16 to the SERVICE_TASK path): no replay or follow-on path ever re-runs a process-step
  entity write.

  Over an instance stream that already holds `TASK_ENTITY_WRITES_APPLIED` (a HUMAN_TASK
  completion, and a SERVICE_TASK apply), each path below runs with the spy port
  (`Letflow.Support.ChaosEntityPort.record!/0`, which reports every `prepare`, `validate_lines`,
  `multi` and `interpret_failure` call) installed, and asserts zero port calls, unchanged
  instance variables, the same two records and no second APPLIED or SYS event:

    * `Letflow.Entities.Record.Projector.rebuild_projection/2`;
    * a TIMER node's timer fired through `Letflow.Scheduler.fire_timer/2`;
    * an escalation timer fired through `Letflow.Scheduler.fire_timer/2`;
    * `Letflow.Engine.cancel_instance/3`.

  C-13 (service apply): the reconstruct and timeline surfaces carry no engine-only value.

  Real Postgres. `async: false`: the port double is application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Response
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Entities.Record.Projector
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Instances
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Support.ChaosEntityPort

  setup do
    on_exit(&ChaosEntityPort.disarm!/0)
    :ok
  end

  defp two_lines do
    [
      Map.put(
        Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
        "output_record_id_var",
        "_sys.move"
      ),
      Fx.line("stock_note", %{
        "label" => %{"const" => "fixed"},
        "note" => %{"var" => "note"}
      })
    ]
  end

  # The node after the writing node, per follow-on path.
  defp tail(:timer) do
    {[
       %{
         "id" => "tail",
         "node_type" => "TIMER",
         "attributes" => %{"duration_iso8601" => "PT1H"}
       },
       %{"id" => "after", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}}
     ], "after"}
  end

  defp tail(:escalation) do
    {[
       %{
         "id" => "tail",
         "node_type" => "HUMAN_TASK",
         "attributes" => %{
           "role" => "REVIEWER",
           "escalation_timer_duration" => "PT1H",
           "escalation_role" => "role-escalation"
         }
       },
       %{
         "id" => "after",
         "node_type" => "HUMAN_TASK",
         "attributes" => %{"role" => "role-escalation"}
       }
     ], "after"}
  end

  defp tail(:plain) do
    {[
       %{"id" => "tail", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}}
     ], "tail"}
  end

  # Splices the `tail/1` nodes between the writing node and END.
  defp with_tail(graph, writer_id, kind) do
    {nodes, last} = tail(kind)
    ids = Enum.map(nodes, & &1["id"])

    chain =
      [writer_id | ids]
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(2)
      |> Enum.map(fn {[source, target], i} ->
        %{"id" => "t#{i}", "source" => source, "target" => target}
      end)

    %{
      "nodes" =>
        Enum.reject(graph["nodes"], &(&1["id"] == "end")) ++
          nodes ++ [%{"id" => "end", "node_type" => "END"}],
      "edges" =>
        Enum.reject(graph["edges"], &(&1["source"] == writer_id)) ++
          chain ++ [%{"id" => "tend", "source" => last, "target" => "end"}]
    }
  end

  # An instance whose stream holds one TASK_ENTITY_WRITES_APPLIED and that is now parked on the
  # tail node (a timer or a human task).
  defp stream_case!(:human, kind) do
    base = Fx.tenant_case!("gh2646-h")
    Fx.define_type!(base.schema, "stock_move", %{})
    Fx.define_type!(base.schema, "stock_note", %{})

    definition =
      Fx.activate!(base.schema, base.user, with_tail(Fx.graph(two_lines()), "ht", kind))

    {instance_id, task} = Fx.start!(base.schema, definition)
    ctx = Map.merge(base, %{definition: definition, instance_id: instance_id, task: task})
    Fx.complete_with_lines!(ctx, %{"label" => "L1", "note" => "N1"})
    ctx
  end

  defp stream_case!(:service, kind) do
    graph = with_tail(Fx.service_graph(two_lines()), "svc", kind)
    ctx = Fx.service_case!("gh2646-s", graph)
    assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})
    ctx
  end

  defp snapshot(ctx) do
    %{
      variables: Fx.projection!(ctx.schema, ctx.instance_id).variables,
      record_ids: ctx.schema |> Fx.all_records() |> Enum.map(& &1.record_id) |> Enum.sort()
    }
  end

  defp drain_port_calls do
    receive do
      {:port_call, _, _} -> drain_port_calls()
    after
      0 -> :ok
    end
  end

  defp assert_replay_wrote_nothing(ctx, before) do
    refute_received {:port_call, _name, _arg}
    after_state = snapshot(ctx)
    assert after_state.variables == before.variables
    assert Map.has_key?(after_state.variables, "_sys.move")
    assert after_state.record_ids == before.record_ids
    assert length(after_state.record_ids) == 2
    assert [_] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")
    assert [_] = Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET")
  end

  defp pending_timer!(ctx, node_id) do
    Timer
    |> where(
      [t],
      t.instance_id == ^ctx.instance_id and t.node_id == ^node_id and t.status == "pending"
    )
    |> Repo.one!(prefix: ctx.schema)
  end

  defp cancel(ctx) do
    actor_id = ctx.user.id

    Engine.cancel_instance(
      ctx.instance_id,
      %{actor_id: actor_id, idempotency_key: Fx.unique("gh2646-cancel")},
      prefix: ctx.schema
    )
  end

  for origin <- [:human, :service] do
    describe "#{origin} apply in the stream" do
      test "rebuild_projection makes no port call and changes nothing (#{origin})" do
        ctx = stream_case!(unquote(origin), :plain)
        before = snapshot(ctx)
        ChaosEntityPort.record!()
        drain_port_calls()

        assert {:ok, _result} = Projector.rebuild_projection(ctx.schema, [])

        assert_replay_wrote_nothing(ctx, before)
      end

      test "a timer fire makes no port call and changes nothing (#{origin})" do
        ctx = stream_case!(unquote(origin), :timer)
        timer = pending_timer!(ctx, "tail")
        before = snapshot(ctx)
        ChaosEntityPort.record!()
        drain_port_calls()

        assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema)

        assert_replay_wrote_nothing(ctx, before)
      end

      test "an escalation fire makes no port call and changes nothing (#{origin})" do
        ctx = stream_case!(unquote(origin), :escalation)

        timer =
          Timer
          |> where(
            [t],
            t.instance_id == ^ctx.instance_id and t.timer_type == "escalation" and
              t.status == "pending"
          )
          |> Repo.one!(prefix: ctx.schema)

        before = snapshot(ctx)
        ChaosEntityPort.record!()
        drain_port_calls()

        assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema)

        assert_replay_wrote_nothing(ctx, before)
      end

      test "a cancellation makes no port call and changes nothing (#{origin})" do
        ctx = stream_case!(unquote(origin), :plain)
        before = snapshot(ctx)
        ChaosEntityPort.record!()
        drain_port_calls()

        assert {:ok, _} = cancel(ctx)

        assert_replay_wrote_nothing(ctx, before)
      end
    end
  end

  describe "C-13: a service apply reaches no operator surface with an engine-only value" do
    test "reconstruct and timeline carry no `_sys` key, record id or SYS event" do
      ctx = stream_case!(:service, :plain)
      [move] = Fx.records(ctx.schema, "stock_move")
      [note] = Fx.records(ctx.schema, "stock_note")

      assert {:ok, %{instance_state: state}} =
               Reconstruction.reconstruct_instance(ctx.instance_id, prefix: ctx.schema)

      # the replayed state keeps the engine-only keys; the client-visible form never shows them
      assert Map.has_key?(state.variables, "_sys.move")
      shown = Response.public_variables(state.variables, %{}, MapSet.new())
      refute Enum.any?(Map.keys(shown), &String.starts_with?(&1, "_sys"))
      refute inspect(shown) =~ move.record_id
      refute inspect(shown) =~ note.record_id

      assert {:ok, %{items: items}} =
               Instances.timeline(ctx.instance_id, %{cursor: nil, page_size: 100},
                 prefix: ctx.schema
               )

      types = Enum.map(items, & &1.event_type)
      assert "TASK_ENTITY_WRITES_APPLIED" in types
      refute "INSTANCE_SYS_VARIABLES_SET" in types

      rendered = inspect(items)
      refute rendered =~ move.record_id
      refute rendered =~ note.record_id
      refute rendered =~ "_sys."
      refute rendered =~ "stock_move"
      refute rendered =~ "stock_note"
    end
  end
end
