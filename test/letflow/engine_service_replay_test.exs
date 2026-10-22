defmodule Letflow.EngineServiceReplayTest do
  @moduledoc """
  GH #2577 (rows 2 and 5 of the append audit, service-task landing, D-3) -- a landing whose derived
  `<completion key>::sys_vars` or `<completion key>::entity_writes` is already claimed.

  The landing checks the dispatch row and the SERVICE_TASK_COMPLETED key before it writes, so only
  the derived keys reach the replay clause without a race: they are claimed here with a real event
  first (EventStore.append/2), so the landing's own append is the duplicate. The answer is
  `{:ok, :already_final}` (D-3); the landing transaction rolls back and nothing of it is written.

  Real Postgres through `Letflow.Engine.advance_after_service_task_outcome/4`; fixtures from
  `Letflow.EntityWritesFixture`. `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore

  @body %{"label" => "L1", "note" => "N1"}

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

  # The payloads the landing itself writes, so the claim passes the event registry.
  defp sys_payload(ctx),
    do: %{
      "node_id" => ctx.dispatch.node_id,
      "cause" => "entity_writes",
      "values" => %{"_sys.move" => Ecto.UUID.generate()}
    }

  defp applied_payload(ctx),
    do: %{
      "node_id" => ctx.dispatch.node_id,
      "task_id" => nil,
      "dispatch_id" => ctx.dispatch.id,
      "lines_hash" => "forced",
      "lines" => []
    }

  defp claim!(ctx, key, event_type, payload) do
    assert {:ok, _claimed} =
             EventStore.append(
               %{
                 instance_id: ctx.instance_id,
                 event_type: event_type,
                 payload: Jason.encode!(payload),
                 actor_id: ctx.user.id,
                 idempotency_key: key
               },
               prefix: ctx.schema
             )
  end

  defp snapshot(ctx) do
    %{
      events: Fx.all_instance_event_count(ctx.schema, ctx.instance_id),
      records: Fx.all_records(ctx.schema),
      audits: Fx.audit_rows(ctx.schema, "entity_write.process_step"),
      projection: Fx.projection!(ctx.schema, ctx.instance_id),
      dispatch_status: Fx.dispatch!(ctx.schema, ctx.dispatch.id).status
    }
  end

  defp assert_landing_wrote_nothing(ctx, before) do
    assert snapshot(ctx) == before
    assert Fx.instance_events(ctx.schema, ctx.instance_id, "SERVICE_TASK_COMPLETED") == []
    assert Fx.dlq_entries(ctx.schema) == []
  end

  test "row 2 (service): a claimed ::sys_vars key answers already_final and writes nothing" do
    ctx = Fx.service_case!("gh2577-svc-row2", Fx.service_graph(two_lines()))
    key = "service_task_dispatch:#{ctx.dispatch.id}"
    claim!(ctx, key <> "::sys_vars", "INSTANCE_SYS_VARIABLES_SET", sys_payload(ctx))
    before = snapshot(ctx)

    assert {:ok, :already_final} = Fx.apply_http(ctx, @body)

    assert_landing_wrote_nothing(ctx, before)
  end

  test "row 5 (service): a claimed ::entity_writes key answers already_final and writes nothing" do
    ctx = Fx.service_case!("gh2577-svc-row5", Fx.service_graph(two_lines()))
    key = "service_task_dispatch:#{ctx.dispatch.id}"
    claim!(ctx, key <> "::entity_writes", "TASK_ENTITY_WRITES_APPLIED", applied_payload(ctx))
    before = snapshot(ctx)

    assert {:ok, :already_final} = Fx.apply_http(ctx, @body)

    assert_landing_wrote_nothing(ctx, before)
    assert Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET") == []
  end
end
