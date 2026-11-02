defmodule Letflow.Metrics.ExpositionTest do
  @moduledoc """
  Unit tests for `Letflow.Metrics.Exposition.render/0` (REQ-194) -- pure formatting,
  no HTTP layer. `Letflow.Metrics.Registry` is the same process-wide instance every
  other test file also emits into, so assertions here check STRUCTURE (headers
  present, well-formed sample lines, correct label escaping) rather than exact
  values -- see `test/letflow/routers/metrics_exposition_test.exs` for
  value-level/end-to-end coverage using route templates unique to that file.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Metrics.Exposition

  @prometheus_names [
    "letflow_active_instances",
    "letflow_active_instances_last_refresh_timestamp_seconds",
    "letflow_task_completions_total",
    "letflow_event_append_duration_seconds",
    "letflow_db_query_duration_seconds",
    "letflow_http_requests_total",
    "letflow_http_errors_total"
  ]

  test "renders a # HELP and # TYPE line for every one of the six OBS-02 families (plus the staleness gauge)" do
    body = Exposition.render()

    for name <- @prometheus_names do
      assert body =~ "# HELP #{name} ", "missing # HELP line for #{name}"
      assert body =~ "# TYPE #{name} ", "missing # TYPE line for #{name}"
    end
  end

  test "histogram families render _bucket/_sum/_count lines with a terminal +Inf bucket" do
    :telemetry.execute([:letflow, :event_store, :append, :stop], %{duration: 2_000_000}, %{})

    body = Exposition.render()

    assert body =~ ~r/^letflow_event_append_duration_seconds_bucket\{le="[\d.]+"\} \d+$/m
    assert body =~ ~r/^letflow_event_append_duration_seconds_bucket\{le="\+Inf"\} \d+$/m
    assert body =~ ~r/^letflow_event_append_duration_seconds_sum [\d.]+$/m
    assert body =~ ~r/^letflow_event_append_duration_seconds_count \d+$/m
  end

  test "label values are escaped -- a quote/backslash in a label value never breaks the line shape" do
    route = ~s(/exposition-test-"quoted"-\\route)

    :telemetry.execute(
      [:letflow, :http, :request],
      %{duration: 1},
      %{method: "GET", route_template: route, status: 200}
    )

    body = Exposition.render()

    assert body =~ ~s(route_template="/exposition-test-\\"quoted\\"-\\\\route")
  end

  test "counter family labels are sorted deterministically (method, route_template, status)" do
    :telemetry.execute(
      [:letflow, :http, :request],
      %{duration: 1},
      %{method: "POST", route_template: "/exposition-test-sort-order", status: 201}
    )

    body = Exposition.render()

    assert body =~
             ~r/letflow_http_requests_total\{method="POST",route_template="\/exposition-test-sort-order",status="201"\}/
  end
end
