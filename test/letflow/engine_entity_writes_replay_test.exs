defmodule Letflow.EngineEntityWritesReplayTest do
  @moduledoc """
  GH #2577 (rows 2 and 3 of the append audit, complete_task) -- forced duplicates of the derived
  `<key>::sys_vars` and `<key>::entity_writes` keys.

  The key is claimed first with `EventStore.append/2`, so the completion's own append is the
  duplicate. The answer is the typed `:idempotency_key_reuse`, the completion transaction rolls
  back, and no completion, projection change, record or second event is written.

  Real Postgres through `Letflow.Engine.complete_task/3`; the fixtures are those of
  `Letflow.EntityWritesFixture`. `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore

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

  defp snapshot(ctx) do
    %{
      events: Fx.all_instance_event_count(ctx.schema, ctx.instance_id),
      projection: Fx.projection!(ctx.schema, ctx.instance_id),
      records: Fx.all_records(ctx.schema),
      task_status: Fx.task!(ctx.schema, ctx.task.id).status
    }
  end

  # The payloads the completion itself writes, so the claim passes the event registry.
  defp sys_payload(ctx),
    do: %{
      "node_id" => ctx.task.node_id,
      "cause" => "entity_writes",
      "values" => %{"_sys.move" => Ecto.UUID.generate()}
    }

  defp applied_payload(ctx),
    do: %{
      "node_id" => ctx.task.node_id,
      "task_id" => ctx.task.id,
      "dispatch_id" => nil,
      "lines_hash" => "forced",
      "lines" => []
    }

  # Claims `key` with a real event of the instance, so the completion's derived append replays.
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

  defp complete_with_key(ctx, key) do
    Engine.complete_task(
      ctx.task.id,
      %{
        output_variables: %{"label" => "L1", "note" => "N1"},
        actor_id: ctx.user.id,
        idempotency_key: key
      },
      prefix: ctx.schema
    )
  end

  defp assert_nothing_completed(ctx, before) do
    after_attempt = snapshot(ctx)

    # the forced claim is in `before`; the completion adds no event to the instance stream
    assert after_attempt.events == before.events
    assert after_attempt.projection == before.projection
    assert after_attempt.records == before.records
    assert after_attempt.task_status == :pending
    assert Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_COMPLETED") == []
  end

  test "row 2 (complete): a claimed ::sys_vars key answers idempotency_key_reuse and writes nothing" do
    ctx = Fx.case!("gh2577-row2", two_lines())
    key = Fx.unique("row2-complete")
    claim!(ctx, key <> "::sys_vars", "INSTANCE_SYS_VARIABLES_SET", sys_payload(ctx))
    before = snapshot(ctx)

    assert {:error, :idempotency_key_reuse} = complete_with_key(ctx, key)

    assert_nothing_completed(ctx, before)
    assert Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED") == []
  end

  test "row 3 (complete): a claimed ::entity_writes key answers idempotency_key_reuse and rolls back the sys event" do
    ctx = Fx.case!("gh2577-row3", two_lines())
    key = Fx.unique("row3-complete")
    claim!(ctx, key <> "::entity_writes", "TASK_ENTITY_WRITES_APPLIED", applied_payload(ctx))
    before = snapshot(ctx)

    assert {:error, :idempotency_key_reuse} = complete_with_key(ctx, key)

    assert_nothing_completed(ctx, before)
    # the SYS event written earlier in the same transaction is rolled back with it
    assert Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET") == []
  end
end
