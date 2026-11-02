defmodule Letflow.Metrics.RegistryTest do
  @moduledoc """
  Unit tests for `Letflow.Metrics.Registry` (REQ-194). No Postgres needed -- these
  exercise the ETS/`:telemetry` mechanics directly, not the full HTTP/engine call
  sites (see `test/letflow/routers/metrics_exposition_test.exs` for the end-to-end
  coverage).

  `Letflow.Metrics.Registry` is started once, platform-wide, by
  `Letflow.Application` -- these tests talk to that SAME already-running process
  (matching `letflow_metrics`'s own "one process-wide table" design), so every test
  emits `:telemetry.execute/3` directly (exactly like real call sites do) and reads
  back via `snapshot/0`, rather than starting a second instance.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Metrics.Registry

  test "handle_task_completed/3 only accepts the closed definition_status enum, never an arbitrary value" do
    :telemetry.execute([:letflow, :task, :completed], %{count: 1}, %{definition_status: :draft})

    %{counters: counters} = Registry.snapshot()
    assert Map.get(counters, {:task_completions_total, %{definition_status: "draft"}}, 0) >= 1

    # A malformed/unexpected metadata shape must not raise or corrupt state -- it is
    # silently ignored (defensive default clause).
    assert :ok =
             Registry.dispatch(
               [:letflow, :task, :completed],
               %{count: 1},
               %{definition_status: :not_a_real_status},
               nil
             )

    refute Map.has_key?(
             Registry.snapshot().counters,
             {:task_completions_total, %{definition_status: "not_a_real_status"}}
           )
  end

  test "handle_event_append_stop/3 observes a histogram with no labels" do
    :telemetry.execute([:letflow, :event_store, :append, :stop], %{duration: 1_000_000}, %{})

    %{histograms: histograms} = Registry.snapshot()

    assert %{count: count, buckets: buckets} =
             Map.fetch!(histograms, {:event_append_duration_seconds, %{}})

    assert count >= 1
    assert Map.has_key?(buckets, :infinity)
  end

  test "handle_repo_query/3 derives query_type from the leading SQL keyword only" do
    :telemetry.execute([:letflow, :repo, :query], %{total_time: 500_000}, %{query: "SELECT 1"})

    :telemetry.execute([:letflow, :repo, :query], %{total_time: 500_000}, %{
      query: "insert into foo values (1)"
    })

    :telemetry.execute([:letflow, :repo, :query], %{total_time: 500_000}, %{query: "BEGIN"})

    %{histograms: histograms} = Registry.snapshot()
    assert Map.has_key?(histograms, {:db_query_duration_seconds, %{query_type: "select"}})
    assert Map.has_key?(histograms, {:db_query_duration_seconds, %{query_type: "insert"}})
    assert Map.has_key?(histograms, {:db_query_duration_seconds, %{query_type: "other"}})
  end

  test "handle_http_request/3 increments requests_total always, errors_total only when status >= 500" do
    route = "/registry-test-route-#{System.unique_integer([:positive, :monotonic])}"

    :telemetry.execute(
      [:letflow, :http, :request],
      %{duration: 1},
      %{method: "GET", route_template: route, status: 200}
    )

    :telemetry.execute(
      [:letflow, :http, :request],
      %{duration: 1},
      %{method: "GET", route_template: route, status: 503}
    )

    %{counters: counters} = Registry.snapshot()

    assert Map.get(
             counters,
             {:http_requests_total, %{method: "GET", route_template: route, status: "200"}}
           ) == 1

    assert Map.get(
             counters,
             {:http_requests_total, %{method: "GET", route_template: route, status: "503"}}
           ) == 1

    assert Map.get(counters, {:http_errors_total, %{route_template: route}}) == 1
  end

  test "set_active_instances/1 writes the gauge and a fresh refresh timestamp; mark_active_instances_refresh_failed/0 is a documented no-op" do
    assert :ok = Registry.set_active_instances(42)

    %{gauges: gauges} = Registry.snapshot()
    assert Map.get(gauges, {:active_instances, %{}}) == 42
    ts = Map.fetch!(gauges, {:active_instances_last_refresh_timestamp_seconds, %{}})
    assert ts > 0

    assert :ok = Registry.mark_active_instances_refresh_failed()

    %{gauges: gauges_after} = Registry.snapshot()
    assert Map.get(gauges_after, {:active_instances, %{}}) == 42
    assert Map.get(gauges_after, {:active_instances_last_refresh_timestamp_seconds, %{}}) == ts
  end
end
