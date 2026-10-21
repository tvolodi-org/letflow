defmodule Letflow.Engine.ServiceTaskEntityWritesDispatcherTest do
  @moduledoc """
  GH #2587 / REQ-499 PR C2, I-C3 / T1 (design `gh2587-req499-pr-c-service-task-writes.md` D-C.9,
  C-3, C-4): the external call is AT-MOST-ONCE. These cases go through the REAL
  `ServiceTaskDispatcher.poll_and_dispatch/1` (the outbound HTTP call to a real local server and
  the re-entry into the engine), not through a direct call of the engine entry point:

    * a contention failure of the entity step is re-applied by the engine and the outbound call
      count stays exactly 1;
    * exhausted contention and a refusal land the instance in ERROR and the call count is still
      exactly 1 (nothing re-claims the `advanced` row);
    * the dispatcher logs no error line for the success or the re-applied contention.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Support.ChaosEntityPort
  alias Letflow.WebhookTestServer

  @body ~s({"label":"L1","note":"N1"})

  setup do
    Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)

    on_exit(fn ->
      Application.delete_env(:letflow, :service_task_ssrf_validation_enabled)
      ChaosEntityPort.disarm!()
    end)

    %{server: WebhookTestServer.start(200, @body)}
  end

  defp lines do
    [
      Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
      Fx.line("stock_note", %{"label" => %{"const" => "fixed"}, "note" => %{"var" => "note"}})
    ]
  end

  defp pending_case!(server, lines) do
    base = Fx.tenant_case!("gh2587c-disp")
    Fx.define_type!(base.schema, "stock_move", %{})
    Fx.define_type!(base.schema, "stock_note", %{})

    graph = Fx.service_graph(lines, %{"endpoint" => server.url})
    Fx.attach_service_pending!(base, graph)
  end

  defp outbound_calls(acc \\ 0) do
    receive do
      {:webhook_test_server_request, _request} -> outbound_calls(acc + 1)
    after
      0 -> acc
    end
  end

  test "a contention failure is re-applied by the engine; the outbound call happens exactly once",
       %{server: server} do
    ctx = pending_case!(server, lines())
    counter = ChaosEntityPort.arm!(:lock_not_available, 1)

    log =
      capture_log(fn ->
        send(self(), {:summary, ServiceTaskDispatcher.poll_and_dispatch(ctx.schema)})
      end)

    assert_received {:summary, %{claimed: 1, advanced: 1}}
    assert outbound_calls() == 1
    assert :counters.get(counter, 1) == 2
    assert length(Fx.all_records(ctx.schema)) == 2
    assert Fx.dlq_entries(ctx.schema) == []
    refute log =~ "[error]"

    # the row is `advanced` and nothing re-claims it: a second poll makes no second call
    assert %{claimed: 0} = ServiceTaskDispatcher.poll_and_dispatch(ctx.schema)
    assert outbound_calls() == 0
  end

  test "exhausted contention lands ERROR; the call count is still exactly 1", %{server: server} do
    ctx = pending_case!(server, lines())
    counter = ChaosEntityPort.arm!(:lock_not_available, :infinity)

    assert %{claimed: 1, given_up: 1} = ServiceTaskDispatcher.poll_and_dispatch(ctx.schema)

    assert outbound_calls() == 1
    assert :counters.get(counter, 1) == 3
    assert Fx.all_records(ctx.schema) == []
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
    assert [entry] = Fx.dlq_entries(ctx.schema)
    assert entry.error_detail["code"] == "entity_write_contention"

    assert %{claimed: 0} = ServiceTaskDispatcher.poll_and_dispatch(ctx.schema)
    assert outbound_calls() == 0
  end

  test "a data-dependent refusal lands ERROR; the call count is exactly 1 and the response is not stored",
       %{server: server} do
    # line 1 needs `label`, which the response (and the line) does not provide
    refusing = [
      Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
      Fx.line("stock_note", %{"note" => %{"var" => "note"}})
    ]

    ctx = pending_case!(server, refusing)

    assert %{claimed: 1, given_up: 1} = ServiceTaskDispatcher.poll_and_dispatch(ctx.schema)

    assert outbound_calls() == 1
    assert Fx.all_records(ctx.schema) == []
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
    assert [entry] = Fx.dlq_entries(ctx.schema)
    assert entry.error_detail["code"] == "validation_failed"
    refute inspect(entry) =~ "L1"
    assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == :advanced
  end

  # GH #2587 PR C1 (fence-open condition 2, design D-C.8 d): the residual. When the ERROR landing
  # itself cannot commit, the dispatcher (the REAL `poll_and_dispatch/1`, real HTTP call, real
  # engine re-entry) logs a classified tag and writes the `service_task.advance_failed` audit
  # entry. A concurrent row lock cannot be used under the SQL sandbox (one connection), so the
  # landing is failed deterministically instead: the apply is exhausted with the chaos port
  # (contention, so the engine goes to the landing), and a trigger on `dlq_entries` -- created in
  # the sandboxed tenant schema, rolled back with it -- raises a lock_not_available error
  # (`55P03`) on the landing's DLQ insert only. The apply never touches `dlq_entries`.
  test "a landing that cannot commit is audited as service_task.advance_failed by the dispatcher",
       %{server: server} do
    ctx = pending_case!(server, lines())
    fail_dlq_inserts!(ctx.schema)
    ChaosEntityPort.arm!(:lock_not_available, :infinity)

    log =
      capture_log(fn ->
        send(self(), {:summary, ServiceTaskDispatcher.poll_and_dispatch(ctx.schema)})
      end)

    assert_received {:summary, %{claimed: 1}}
    assert outbound_calls() == 1

    # the residual state: nothing committed, the instance still ACTIVE, the row still advanced
    assert Fx.all_records(ctx.schema) == []
    assert Fx.dlq_entries(ctx.schema) == []
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
    assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == :advanced
    refute "SERVICE_TASK_COMPLETED" in Fx.instance_event_types(ctx.schema, ctx.instance_id)

    # the engine logs the landing failure and the dispatcher logs + audits it, tags only
    assert log =~ "service task entity write landing failed: dispatch_id=#{ctx.dispatch.id}"
    assert log =~ "reason=contention"
    assert log =~ "service_task advance failed: dispatch_id=#{ctx.dispatch.id}"
    assert log =~ "reason=entity_write_landing_failed"

    error_lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[error]"))
    assert Enum.any?(error_lines, &(&1 =~ "landing failed" and &1 =~ "reason=contention"))

    assert Enum.any?(
             error_lines,
             &(&1 =~ "service_task advance failed" and
                 &1 =~ "reason=entity_write_landing_failed")
           )

    refute Enum.any?(error_lines, &(&1 =~ "L1" or &1 =~ "N1"))

    assert [entry] = Fx.audit_rows(ctx.schema, "service_task.advance_failed")
    assert entry.resource_type == "instance"
    assert entry.resource_id == ctx.instance_id
    assert entry.actor_id == Letflow.EventStore.platform_actor_id()
    assert entry.after_state == %{"node_id" => "svc", "reason" => "entity_write_landing_failed"}
    refute inspect(entry) =~ "L1"

    # nothing re-claims the advanced row: still exactly one outbound call
    assert %{claimed: 0} = ServiceTaskDispatcher.poll_and_dispatch(ctx.schema)
    assert outbound_calls() == 0
  end

  # No `on_exit` cleanup: the trigger and its function are DDL inside the test's SQL-sandbox
  # transaction (the tenant is provisioned on that connection), so the sandbox rollback removes
  # both; nothing is committed to the shared database.
  defp fail_dlq_inserts!(schema) do
    Ecto.Adapters.SQL.query!(
      Letflow.Repo,
      """
      CREATE FUNCTION "#{schema}".c1_fail_landing() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'c1 chaos: landing refused' USING ERRCODE = '55P03';
      END $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Letflow.Repo,
      """
      CREATE TRIGGER c1_fail_landing BEFORE INSERT ON "#{schema}".dlq_entries
      FOR EACH ROW EXECUTE FUNCTION "#{schema}".c1_fail_landing()
      """,
      []
    )
  end
end
