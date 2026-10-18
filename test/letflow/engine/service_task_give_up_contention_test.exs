defmodule Letflow.Engine.ServiceTaskGiveUpContentionTest do
  @moduledoc """
  GH #2706 / PR-3 (design `lib/letflow/design/gh2706-cancel-snapshot-and-lock-timeouts.md`
  section 4.2, dispatcher half): when the :give_up landing of a SERVICE_TASK dispatch
  (`Letflow.Engine.set_instance_error/2`) cannot take its locks, `poll_and_dispatch/1` logs a
  classified failure (`reason=execution_error_contention`, tags only) and writes the
  `service_task.advance_failed` audit entry; the instance stays active.

  A concurrent row lock cannot be used under the SQL sandbox (one connection), so the landing is
  failed deterministically, as `ServiceTaskEntityWritesDispatcherTest` does: a trigger on
  `dlq_entries` -- DDL inside the sandboxed tenant schema, rolled back with it -- raises a
  `55P03` on the landing's DLQ insert. The SSRF gate blocks the loopback URL, which is an
  immediate give-up (no outbound call).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.EntityWritesFixture, as: Fx

  test "a give-up landing that hits lock contention is logged and audited with the contention tag" do
    base = Fx.tenant_case!("gh2706-pr3-disp")
    graph = Fx.service_graph([], %{"endpoint" => "https://127.0.0.1/hook"})
    ctx = Fx.attach_service_pending!(base, graph)
    fail_dlq_inserts!(ctx.schema)

    log =
      capture_log([level: :warning], fn ->
        send(self(), {:summary, ServiceTaskDispatcher.poll_and_dispatch(ctx.schema)})
      end)

    assert_received {:summary, %{claimed: 1}}

    # the instance stays active, nothing committed by the landing
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
    assert Fx.instance_events(ctx.schema, ctx.instance_id, "EXECUTION_ERROR") == []

    assert log =~ "service_task advance failed: dispatch_id=#{ctx.dispatch.id}"
    assert log =~ "reason=execution_error_contention"
    refute log =~ "reason=other"

    assert [entry] = Fx.audit_rows(ctx.schema, "service_task.advance_failed")
    assert entry.resource_id == ctx.instance_id
    assert entry.after_state == %{"node_id" => "svc", "reason" => "execution_error_contention"}
  end

  defp fail_dlq_inserts!(schema) do
    Ecto.Adapters.SQL.query!(
      Letflow.Repo,
      """
      CREATE FUNCTION "#{schema}".gh2706_fail_landing() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'gh2706 chaos: landing refused' USING ERRCODE = '55P03';
      END $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Letflow.Repo,
      """
      CREATE TRIGGER gh2706_fail_landing BEFORE INSERT ON "#{schema}".dlq_entries
      FOR EACH ROW EXECUTE FUNCTION "#{schema}".gh2706_fail_landing()
      """,
      []
    )
  end
end
