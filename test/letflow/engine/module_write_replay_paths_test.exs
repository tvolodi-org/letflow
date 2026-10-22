defmodule Letflow.Engine.ModuleWriteReplayPathsTest do
  @moduledoc """
  GH #2725 gap 1 / REQ-501 design D-R.19 (section 11 row "Replay never re-runs"): no replay or
  follow-on path ever re-runs a MODULE WRITE HANDLER.

  Over an instance stream that already holds the v3 `TASK_ENTITY_WRITES_APPLIED` of a handler
  completion (`fixture_ledger/post_entry`: one `fxl_ledger` and one `fxl_balance` record), each
  path below runs with the call counters of the fixture handlers and the entity-port spy
  (`Letflow.Support.ChaosEntityPort.record!/0`) installed and asserts zero handler calls, zero
  port calls, the same two records, the same step idempotency keys and no second APPLIED event:

    * `Letflow.Entities.Record.Projector.rebuild_projection/2`;
    * a TIMER node's timer fired through `Letflow.Scheduler.fire_timer/2`;
    * an escalation timer fired through `Letflow.Scheduler.fire_timer/2`;
    * `Letflow.Engine.cancel_instance/3`.

  Reconstruction is covered by `module_write_audit_test.exs`, the SERVICE_TASK replay by
  `module_write_service_task_test.exs`. The declarative-line version of these four paths is
  `replay_paths_no_entity_write_test.exs` (GH #2646); this file adds the handler half, with a
  positive control (the completion itself runs the handler once).

  `async: false`: module installs run DDL; handler call counters and the port double are global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Engine
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Projector
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Modules.FixtureLedger
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Support.ChaosEntityPort

  @traced [Letflow.Modules.FixtureLedger.Handlers]

  setup do
    for mod <- @traced do
      {:module, ^mod} = Code.ensure_loaded(mod)
      :erlang.trace_pattern({mod, :_, :_}, true, [:call_count])
    end

    on_exit(fn ->
      ChaosEntityPort.disarm!()
      for mod <- @traced, do: :erlang.trace_pattern({mod, :_, :_}, false, [:call_count])
    end)

    :ok
  end

  # The number of handler calls since the last drain (resets the counters).
  defp drain_handler_calls do
    total =
      for mod <- @traced,
          {fun, arity} <- mod.module_info(:functions),
          fun != :module_info,
          reduce: 0 do
        acc ->
          case :erlang.trace_info({mod, fun, arity}, :call_count) do
            {:call_count, count} when is_integer(count) -> acc + count
            _other -> acc
          end
      end

    for mod <- @traced, do: :erlang.trace_pattern({mod, :_, :_}, true, [:call_count])
    total
  end

  defp flush_port_calls do
    receive do
      {:port_call, _, _} -> flush_port_calls()
    after
      0 -> :ok
    end
  end

  # The node after the handler-writing node, per follow-on path.
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
    {[%{"id" => "tail", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}}],
     "tail"}
  end

  # START -> ht (module_writes) -> tail nodes -> END.
  defp graph_with_tail(kind) do
    {nodes, last} = tail(kind)
    ids = ["ht" | Enum.map(nodes, & &1["id"])]

    chain =
      ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(2)
      |> Enum.map(fn {[source, target], i} ->
        %{"id" => "t#{i}", "source" => source, "target" => target}
      end)

    base = Mw.graph([Mw.line()])

    %{
      "nodes" =>
        Enum.reject(base["nodes"], &(&1["id"] == "end")) ++
          nodes ++ [%{"id" => "end", "node_type" => "END"}],
      "edges" =>
        Enum.reject(base["edges"], &(&1["source"] == "ht")) ++
          chain ++ [%{"id" => "tend", "source" => last, "target" => "end"}]
    }
  end

  # An instance whose stream holds one handler APPLIED event and that is parked on the tail.
  defp stream_case!(kind) do
    base = Mw.tenant!("gh2725-replay-#{kind}")

    {:ok, draft} =
      Definitions.create_owned(
        %{
          name: Fx.unique("gh2725-replay"),
          version: "1",
          graph: graph_with_tail(kind),
          created_by: base.user.id
        },
        [prefix: base.schema],
        ManagedTypes.module_owner(FixtureLedger)
      )

    activator =
      Activator.from_auth_context(%{user_id: base.user.id, roles: ["TENANT_ADMIN"]}, false)

    assert {:ok, %{definition: definition}} =
             Definitions.activate(draft.id, prefix: base.schema, activator: activator)

    {instance_id, task} = Fx.start!(base.schema, definition)
    ctx = Map.merge(base, %{definition: definition, instance_id: instance_id, task: task})

    # positive control: the completion itself runs the handler once
    drain_handler_calls()
    assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
    assert drain_handler_calls() == 1
    ctx
  end

  defp snapshot(ctx) do
    %{
      variables: Fx.projection!(ctx.schema, ctx.instance_id).variables,
      record_ids: ctx.schema |> Fx.all_records() |> Enum.map(& &1.record_id) |> Enum.sort(),
      step_keys: Fx.step_idempotency_count(ctx.schema),
      entity_events: length(Fx.entity_events(ctx.schema))
    }
  end

  defp arm_spies! do
    ChaosEntityPort.record!()
    flush_port_calls()
    drain_handler_calls()
  end

  defp assert_replay_ran_no_handler(ctx, before) do
    assert drain_handler_calls() == 0
    refute_received {:port_call, _name, _arg}
    assert snapshot(ctx) == before
    assert length(before.record_ids) == 2
    assert [_] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")
  end

  defp pending_timer!(ctx, filter) do
    Timer
    |> where([t], t.instance_id == ^ctx.instance_id and t.status == "pending")
    |> where(^filter)
    |> Repo.one!(prefix: ctx.schema)
  end

  test "rebuild_projection runs no handler and changes nothing" do
    ctx = stream_case!(:plain)
    before = snapshot(ctx)
    arm_spies!()

    assert {:ok, _result} = Projector.rebuild_projection(ctx.schema, [])

    assert_replay_ran_no_handler(ctx, before)
  end

  test "a timer fire runs no handler and changes nothing" do
    ctx = stream_case!(:timer)
    timer = pending_timer!(ctx, dynamic([t], t.node_id == "tail"))
    before = snapshot(ctx)
    arm_spies!()

    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema)

    assert_replay_ran_no_handler(ctx, before)
  end

  test "an escalation fire runs no handler and changes nothing" do
    ctx = stream_case!(:escalation)
    timer = pending_timer!(ctx, dynamic([t], t.timer_type == "escalation"))
    before = snapshot(ctx)
    arm_spies!()

    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema)

    assert_replay_ran_no_handler(ctx, before)
  end

  test "a cancellation runs no handler and changes nothing" do
    ctx = stream_case!(:plain)
    before = snapshot(ctx)
    arm_spies!()

    assert {:ok, _} =
             Engine.cancel_instance(
               ctx.instance_id,
               %{actor_id: ctx.user.id, idempotency_key: Fx.unique("gh2725-cancel")},
               prefix: ctx.schema
             )

    assert_replay_ran_no_handler(ctx, before)
  end
end
