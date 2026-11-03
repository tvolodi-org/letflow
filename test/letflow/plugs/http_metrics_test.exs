defmodule Letflow.Plugs.HttpMetricsProbeRouter do
  @moduledoc false
  use Plug.Router

  plug(Letflow.Plugs.HttpMetrics)
  plug(:match)
  plug(:dispatch)

  get "/http-metrics-probe/:id" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "nope")
  end
end

defmodule Letflow.Plugs.HttpMetricsTest do
  @moduledoc """
  Unit tests for `Letflow.Plugs.HttpMetrics` (REQ-194) -- the Plug itself, in
  isolation from `Letflow.Metrics.Registry`'s own attachment (asserted via a raw
  `:telemetry` test handler here, not `Registry.snapshot/0`).
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import Plug.Test

  @probe_opts Letflow.Plugs.HttpMetricsProbeRouter.init([])

  defp attach_test_handler(test_pid, handler_id) do
    :telemetry.attach(
      handler_id,
      [:letflow, :http, :request],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, measurements, metadata})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emits [:letflow, :http, :request] with the matched route template, method, status" do
    handler_id = "http-metrics-test-#{System.unique_integer([:positive, :monotonic])}"
    attach_test_handler(self(), handler_id)

    conn(:get, "/http-metrics-probe/some-id-123")
    |> Letflow.Plugs.HttpMetricsProbeRouter.call(@probe_opts)

    assert_receive {:telemetry_event, %{duration: duration}, metadata}
    assert duration >= 0
    assert metadata.method == "GET"
    assert metadata.route_template == "/http-metrics-probe/:id"
    assert metadata.status == 200
    refute metadata.route_template =~ "some-id-123"
  end

  test "falls back to the literal \"unmatched\" route template when nothing matched" do
    handler_id = "http-metrics-test-unmatched-#{System.unique_integer([:positive, :monotonic])}"
    attach_test_handler(self(), handler_id)

    conn(:get, "/http-metrics-probe-does-not-exist")
    |> Letflow.Plugs.HttpMetricsProbeRouter.call(@probe_opts)

    assert_receive {:telemetry_event, _measurements, metadata}
    assert metadata.route_template == "unmatched"
    assert metadata.status == 404
  end

  test "GET /metrics itself is excluded -- no event emitted" do
    handler_id = "http-metrics-test-excluded-#{System.unique_integer([:positive, :monotonic])}"
    attach_test_handler(self(), handler_id)

    conn(:get, "/metrics")
    |> Letflow.Plugs.HttpMetricsProbeRouter.call(@probe_opts)

    refute_receive {:telemetry_event, _measurements, _metadata}, 50
  end
end
