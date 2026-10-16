defmodule Letflow.Metrics.Exposition do
  @moduledoc """
  REQ-194 (design `lib/letflow/design/req194-prometheus-metrics.md` §8) -- formats
  `Letflow.Metrics.Registry.snapshot/0`'s state as Prometheus exposition text
  (`# HELP`/`# TYPE`/sample lines). Pure function: registry snapshot in, formatted
  text out -- trivially unit-testable without any HTTP layer involved, and never
  touches `Letflow.Repo` (§6/§8 -- the DB-unavailable graceful-degradation contract
  depends on this: `render/0` can only ever read already-updated ETS state).

  This is the exact shape `web/src/api/metrics.ts`'s `parsePrometheusText/1` already
  parses -- see `Letflow.Routers.MetricsExposition`'s moduledoc for the full
  consumer-contract reasoning.
  """

  alias Letflow.Metrics.Registry

  # {family, kind, prometheus_name, help_text} -- the seven families (six OBS-02, design §3; one REQ-497 PR 1b),
  # in a fixed rendering order.
  @families [
    {:active_instances, :gauge, "letflow_active_instances",
     "Number of active workflow instances, platform-wide."},
    {:active_instances_last_refresh_timestamp_seconds, :gauge,
     "letflow_active_instances_last_refresh_timestamp_seconds",
     "Unix timestamp (seconds) of the last successful active-instance count refresh."},
    {:task_completions_total, :counter, "letflow_task_completions_total",
     "Total number of completed tasks, labelled by definition_status."},
    {:event_append_duration_seconds, :histogram, "letflow_event_append_duration_seconds",
     "Event-store append latency, in seconds."},
    {:db_query_duration_seconds, :histogram, "letflow_db_query_duration_seconds",
     "Database query latency, in seconds, labelled by query_type."},
    {:http_requests_total, :counter, "letflow_http_requests_total",
     "Total number of HTTP requests, labelled by method/route_template/status."},
    {:http_errors_total, :counter, "letflow_http_errors_total",
     "Total number of HTTP responses with status >= 500, labelled by route_template."},
    # REQ-497 PR 1b (design 4.3): shadow-mode scope would-denies.
    {:scope_shadow_would_deny_total, :counter, "letflow_scope_shadow_would_deny_total",
     "Total number of shadow-mode org-scope would-deny decisions, labelled by reason."}
  ]

  @spec render() :: String.t()
  def render do
    snapshot = Registry.snapshot()

    @families
    |> Enum.map(fn {family, kind, name, help} ->
      render_family(family, kind, name, help, snapshot)
    end)
    |> Enum.join("")
  end

  defp render_family(family, :gauge, name, help, snapshot) do
    header(name, "gauge", help) <> render_samples(snapshot.gauges, family, name)
  end

  defp render_family(family, :counter, name, help, snapshot) do
    header(name, "counter", help) <> render_samples(snapshot.counters, family, name)
  end

  defp render_family(family, :histogram, name, help, snapshot) do
    lines =
      snapshot.histograms
      |> Enum.filter(fn {{f, _labels}, _data} -> f == family end)
      |> Enum.map(fn {{_f, labels}, data} -> histogram_lines(name, labels, data) end)
      |> Enum.join("")

    header(name, "histogram", help) <> lines
  end

  defp render_samples(values, family, name) do
    values
    |> Enum.filter(fn {{f, _labels}, _value} -> f == family end)
    |> Enum.map(fn {{_f, labels}, value} -> sample_line(name, labels, value) end)
    |> Enum.join("")
  end

  defp header(name, type, help) do
    "# HELP #{name} #{help}\n# TYPE #{name} #{type}\n"
  end

  defp histogram_lines(name, labels, %{buckets: buckets, sum: sum, count: count}) do
    bucket_lines =
      (Registry.histogram_bucket_boundaries() ++ [:infinity])
      |> Enum.map(fn le ->
        bucket_labels = Map.put(labels, :le, format_le(le))
        sample_line("#{name}_bucket", bucket_labels, Map.fetch!(buckets, le))
      end)
      |> Enum.join("")

    bucket_lines <>
      sample_line("#{name}_sum", labels, sum) <> sample_line("#{name}_count", labels, count)
  end

  defp format_le(:infinity), do: "+Inf"
  defp format_le(le) when is_float(le), do: Float.to_string(le)

  defp sample_line(name, labels, value) do
    "#{name}#{label_string(labels)} #{format_value(value)}\n"
  end

  defp label_string(labels) when map_size(labels) == 0, do: ""

  defp label_string(labels) do
    pairs =
      labels
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> ~s(#{k}="#{escape_label_value(v)}") end)
      |> Enum.join(",")

    "{#{pairs}}"
  end

  defp escape_label_value(v) do
    v
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)
end
