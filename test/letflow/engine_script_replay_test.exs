defmodule Letflow.EngineScriptReplayTest do
  @moduledoc """
  GH #2577 (rows 6 and its failure landing, D-4) -- a script-task landing whose own derived key is
  already claimed by another request.

  The script landings share the dispatch CAS, so a replay would be caught there first; the keys
  are claimed with a real event (EventStore.append/2) so the landing's own append is the duplicate.
  The answer is `{:ok, :stale}` and nothing of the landing is written. The failure landing must not
  answer an error, because ScriptTaskDispatcher.apply_with_followup/3 turns an error into a
  `script_rejected` follow-up row (the hazard D-4 names).

  Real Postgres through `Letflow.Engine.apply_script_task_result/3`; fixtures from
  `Letflow.Support.ScriptTaskFixture`. `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.EventStore
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    %{t: F.tenant!("gh2577-script-replay")}
  end

  defp success_result(row, output) do
    {:ok, output,
     %{row: row, phase: :ran, outcome: :ok, detail: nil, fail_code: nil, hmac: nil, stats: nil}}
  end

  defp failure_result(row) do
    {:failed, :script_error, nil,
     %{
       row: row,
       phase: :ran,
       outcome: :script_error,
       detail: nil,
       fail_code: nil,
       hmac: nil,
       stats: nil
     }}
  end

  # A valid event of the instance under `key`: the first claimant of the landing's key.
  defp claim!(t, instance_id, key) do
    assert {:ok, _claimed} =
             EventStore.append(
               %{
                 instance_id: instance_id,
                 event_type: "INSTANCE_SYS_VARIABLES_SET",
                 payload:
                   Jason.encode!(%{
                     "node_id" => "script",
                     "cause" => "entity_writes",
                     "values" => %{"_sys.move" => Ecto.UUID.generate()}
                   }),
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: key
               },
               prefix: t.schema_name
             )
  end

  defp snapshot(t, instance_id) do
    %{
      events: F.event_types(t.schema_name, instance_id),
      variables: F.projection(t.schema_name, instance_id).variables,
      status: F.projection(t.schema_name, instance_id).status,
      rows: F.rows(t.schema_name, instance_id),
      dlq: F.dlq_count(t.schema_name)
    }
  end

  test "row 6 (success landing): a claimed script_run key answers stale and changes nothing", %{
    t: t
  } do
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2})
    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
    claim!(t, b.instance_id, "script_run:#{row.id}:#{row.attempt}")
    before = snapshot(t, b.instance_id)

    assert Engine.apply_script_task_result(
             F.claim(row),
             success_result(row, %{"total" => 4}),
             t.schema_name
           ) == {:ok, :stale}

    assert snapshot(t, b.instance_id) == before
    refute "SCRIPT_TASK_COMPLETED" in F.event_types(t.schema_name, b.instance_id)
    refute "SCRIPT_RUN_RECORDED" in F.event_types(t.schema_name, b.instance_id)
  end

  test "failed landing (script_failure): a claimed dispatch key answers stale, no refusal row", %{
    t: t
  } do
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2})
    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
    claim!(t, b.instance_id, "script_task_dispatch:#{row.id}:#{row.attempt}")
    before = snapshot(t, b.instance_id)

    assert Engine.apply_script_task_result(F.claim(row), failure_result(row), t.schema_name) ==
             {:ok, :stale}

    # no ERROR, no DLQ entry, no SCRIPT_RUN_RECORDED, and the row is not finished as failed
    assert snapshot(t, b.instance_id) == before
    refute "EXECUTION_ERROR" in F.event_types(t.schema_name, b.instance_id)
    refute "SCRIPT_RUN_RECORDED" in F.event_types(t.schema_name, b.instance_id)
  end
end
