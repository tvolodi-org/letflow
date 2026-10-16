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
    assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == "advanced"
  end
end
