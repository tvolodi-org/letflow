defmodule Letflow.Metrics.Registry do
  @moduledoc """
  REQ-194 (design `lib/letflow/design/req194-prometheus-metrics.md` §5) -- the
  hand-rolled, ETS-backed collector behind `GET /metrics`
  (`Letflow.Routers.MetricsExposition`).

  ## Dependency decision (AC3 -- restated here, not left silent)

  **No metrics library is adopted.** `telemetry_metrics` and
  `telemetry_metrics_prometheus_core` were considered and rejected: this subsystem has
  exactly six fixed, hand-specified metric families with hand-specified,
  tenant-safety-critical label allow-lists, and a generic declarative reporter buys no
  reduction in the code that has to be reviewed for that invariant while adding an
  external release cadence and (for the Prometheus-core variant) its own HTTP-exposition
  path to reconcile with `Letflow.Router`'s existing route table. This module and
  `Letflow.Metrics.Exposition` are the hand-rolled registry/formatter that decision
  produces (design §10). The one dependency change this requirement DOES make --
  promoting the already-transitively-present `:telemetry` v1.4.2 to a direct `mix.exs`
  dependency -- is not a "metrics library" in this sense: `:telemetry` is a pub/sub
  primitive with no metric types, storage, or exposition format of its own; REVIEWER
  sign-off for that promotion is recorded separately per the requirement's own AC3.

  ## Mechanism

  Owns one named, public ETS table (`:letflow_metrics`, `:set`,
  `:named_table, :public, {:write_concurrency, true}`) and, on `init/1`, calls
  `:telemetry.attach_many/4` to subscribe to every REQUEST/EVENT-DRIVEN family in the
  table below. The actual counter/gauge/histogram mutation on each event runs via a
  plain module function invoked BY THE `:telemetry` DISPATCH MECHANISM IN THE EMITTING
  PROCESS -- never a `GenServer.call/cast` back to this process -- so no request ever
  waits on this process's mailbox; every increment is a direct, atomic `:ets` operation
  in the caller's own process. A crash-and-restart of this `GenServer` re-attaches
  cleanly via the same `init/1` and re-creates an EMPTY table -- counters/histograms
  reset across a restart, which is standard, expected Prometheus semantics (`rate()`/
  `increase()` tolerate resets natively); this is different from, and does not conflict
  with, `Letflow.Scheduler.Poller`'s own DB-unavailability graceful degradation (design
  §6), which is about the *data source* being temporarily unreachable while this
  process stays up.

  ## The seven families this registry maintains (six OBS-02, design §3; one REQ-497 PR 1b)

  | # | Prometheus name | Kind | Label allow-list | `:telemetry` event | Fed by |
  |---|---|---|---|---|---|
  | 1 | `letflow_active_instances` | gauge | none | none -- see below | `Letflow.Scheduler.Poller`'s tick, via `set_active_instances/1` |
  | 1b | `letflow_active_instances_last_refresh_timestamp_seconds` | gauge | none | none | same refresh step as #1 |
  | 2 | `letflow_task_completions_total` | counter | `definition_status` (closed 4-value enum) | `[:letflow, :task, :completed]` | `Letflow.Engine.complete_task/3` |
  | 3 | `letflow_event_append_duration_seconds` | histogram | none | `[:letflow, :event_store, :append, :stop]` | `Letflow.EventStore.append/2` (`:telemetry.span/3`) |
  | 4 | `letflow_db_query_duration_seconds` | histogram | `query_type` (5-value closed enum) | `[:letflow, :repo, :query]` (Ecto's own, already emitted -- attachment only, no new call site) | Ecto/`ecto_sql` |
  | 5 | `letflow_http_requests_total` | counter | `method`, `route_template`, `status` | `[:letflow, :http, :request]` | `Letflow.Plugs.HttpMetrics` |
  | 6 | `letflow_http_errors_total` | counter | `route_template` | same event as #5 (registry increments only when `status >= 500`) | `Letflow.Plugs.HttpMetrics` |
  | 7 | `letflow_scope_shadow_would_deny_total` | counter | `reason` (closed 6-value enum) | `[:letflow, :scope, :shadow, :would_deny]` | `Letflow.Api.Scope.Shadow` (REQ-497 PR 1b) |

  **Family 1 is deliberately NOT `:telemetry`-driven** (design §5/§6): "how many
  instances are active, platform-wide, right now" is not an event Letflow already
  raises anywhere, and needs a DB-availability-aware refresh cadence rather than an
  event-driven increment -- see `set_active_instances/1`/`mark_active_instances_refresh_failed/0`
  below, called directly by `Letflow.Scheduler.Poller`. This is a deliberate, named
  exception to the "emission call sites reference only `:telemetry`, never this module"
  rule that families 2-6 follow (AC8's own `grep` command, design §4, is scoped to
  `http_metrics.ex`/`engine.ex`/`event_store.ex` and deliberately excludes
  `scheduler/poller.ex` for exactly this reason).

  ## Tenant-safety invariant (design §1 Axis 2/3, AC6) -- enforced HERE, per-family

  Every `handle_*` function below extracts labels via a label allow-list literal to
  that family, hard-coded in this module's own source -- **never** a dynamic
  pass-through of whatever metadata keys an event happens to carry (mirroring
  `lib/letflow/routers/metrics.ex`'s own retired `counter_group/2`/`metrics_map/3`
  discipline: "hand-built key list, never a pass-through of whatever atoms the query
  happened to return"). No metric family emitted by this registry ever carries a
  `tenant_id`, `definition_id`, `instance_id`, `task_id`, `actor_id`, or any other
  per-entity/per-tenant identifier as a label value, at any point -- reviewing every
  `handle_*` function body below is sufficient to confirm this, because each one names
  its allowed label keys literally. This is the entire safety mechanism that makes
  `GET /metrics` a global, UNAUTHENTICATED endpoint safe (see
  `Letflow.Routers.MetricsExposition`'s moduledoc for the full Axis 2/3 reasoning).
  """

  use GenServer

  @table :letflow_metrics
  @handler_id "letflow-metrics-registry"

  # Prometheus's own conventional default-latency ladder, seconds. Fixed, not
  # runtime-configurable (design §3 -- a fixed bucket ladder keeps
  # `histogram_quantile` queries meaningful across scrapes).
  @histogram_buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

  @type metric_key :: {family_name :: atom(), labels :: %{optional(atom()) => String.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec histogram_bucket_boundaries() :: [float()]
  def histogram_bucket_boundaries, do: @histogram_buckets

  @impl true
  def init(_state) do
    :ets.new(@table, [:set, :named_table, :public, {:write_concurrency, true}])

    :telemetry.attach_many(
      @handler_id,
      [
        [:letflow, :task, :completed],
        [:letflow, :event_store, :append, :stop],
        [:letflow, :repo, :query],
        [:letflow, :http, :request],
        [:letflow, :scope, :shadow, :would_deny]
      ],
      &__MODULE__.dispatch/4,
      nil
    )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # :telemetry dispatch -- called in the EMITTING process, never routed through this
  # GenServer's own mailbox (design §5).
  # ---------------------------------------------------------------------------------

  @doc false
  def dispatch([:letflow, :task, :completed], measurements, metadata, config) do
    handle_task_completed(measurements, metadata, config)
  end

  def dispatch([:letflow, :event_store, :append, :stop], measurements, metadata, config) do
    handle_event_append_stop(measurements, metadata, config)
  end

  def dispatch([:letflow, :repo, :query], measurements, metadata, config) do
    handle_repo_query(measurements, metadata, config)
  end

  def dispatch([:letflow, :http, :request], measurements, metadata, config) do
    handle_http_request(measurements, metadata, config)
  end

  def dispatch([:letflow, :scope, :shadow, :would_deny], measurements, metadata, config) do
    handle_scope_shadow_would_deny(measurements, metadata, config)
  end

  # Family 7 -- letflow_scope_shadow_would_deny_total (REQ-497 PR 1b, design 4.3). Label
  # allow-list: `reason` ONLY, from the closed six-value `Letflow.Api.Scope.deny_reason()`
  # set; any other value is dropped. Never a tenant, user, policy or role label.
  @scope_shadow_reasons [
    :role_not_held,
    :no_grant_rows,
    :not_tenant_wide,
    :out_of_scope,
    :unresolvable,
    :grants_unavailable
  ]

  @spec handle_scope_shadow_would_deny(map(), map(), term()) :: :ok
  def handle_scope_shadow_would_deny(measurements, %{reason: reason}, _config)
      when reason in @scope_shadow_reasons do
    count = Map.get(measurements, :count, 1)
    incr_counter(:scope_shadow_would_deny_total, %{reason: Atom.to_string(reason)}, count)
  end

  def handle_scope_shadow_would_deny(_measurements, _metadata, _config), do: :ok

  # Family 2 -- letflow_task_completions_total. Label allow-list: definition_status
  # ONLY (a closed 4-value enum), never definition_id (design §1's restatement of
  # R-Co's "by definition" family -- see Letflow.Routers.MetricsExposition moduledoc).
  @spec handle_task_completed(map(), map(), term()) :: :ok
  def handle_task_completed(measurements, %{definition_status: status}, _config)
      when status in [:draft, :active, :deprecated, :archived] do
    count = Map.get(measurements, :count, 1)
    labels = %{definition_status: Atom.to_string(status)}
    incr_counter(:task_completions_total, labels, count)
  end

  def handle_task_completed(_measurements, _metadata, _config), do: :ok

  # Family 3 -- letflow_event_append_duration_seconds. No labels.
  @spec handle_event_append_stop(map(), map(), term()) :: :ok
  def handle_event_append_stop(measurements, _metadata, _config) do
    duration = Map.get(measurements, :duration, 0)
    observe_histogram(:event_append_duration_seconds, %{}, duration)
  end

  # Family 4 -- letflow_db_query_duration_seconds. Label allow-list: query_type ONLY,
  # derived from the leading SQL keyword (never the SQL text itself, never stored).
  # Attaches to Ecto's OWN already-emitted event -- no new instrumentation call site.
  @spec handle_repo_query(map(), map(), term()) :: :ok
  def handle_repo_query(measurements, metadata, _config) do
    query_type = query_type_from_sql(Map.get(metadata, :query))
    duration = Map.get(measurements, :total_time, 0)
    observe_histogram(:db_query_duration_seconds, %{query_type: query_type}, duration)
  end

  # Family 5/6 -- letflow_http_requests_total / letflow_http_errors_total. Label
  # allow-list: method/route_template/status (5), route_template only (6).
  # route_template is ALREADY normalized to Plug's own compiled route template by
  # Letflow.Plugs.HttpMetrics before this event is ever emitted (never a raw path).
  @spec handle_http_request(map(), map(), term()) :: :ok
  def handle_http_request(_measurements, metadata, _config) do
    method = to_string(Map.fetch!(metadata, :method))
    route_template = Map.fetch!(metadata, :route_template)
    status = Map.fetch!(metadata, :status)

    incr_counter(
      :http_requests_total,
      %{method: method, route_template: route_template, status: Integer.to_string(status)},
      1
    )

    if status >= 500 do
      incr_counter(:http_errors_total, %{route_template: route_template}, 1)
    end

    :ok
  end

  # ---------------------------------------------------------------------------------
  # Family 1 -- letflow_active_instances (+ companion staleness gauge). NOT
  # :telemetry-driven -- called directly by Letflow.Scheduler.Poller's tick (design
  # §5/§6), the one deliberate exception to the "never call this module directly"
  # rule (see moduledoc above).
  # ---------------------------------------------------------------------------------

  @spec set_active_instances(count :: non_neg_integer()) :: :ok
  def set_active_instances(count) when is_integer(count) and count >= 0 do
    :ets.insert(@table, {{:gauge, :active_instances, %{}}, count})

    :ets.insert(
      @table,
      {{:gauge, :active_instances_last_refresh_timestamp_seconds, %{}},
       DateTime.utc_now() |> DateTime.to_unix(:second)}
    )

    :ok
  end

  # Documented no-op (design §5): leaves the gauge and its refresh timestamp at their
  # last successfully-written values -- exactly the graceful-degradation behavior
  # design §6 requires. Exists as an explicit call site so a future reader (and a
  # test) can see the DB-unavailable path was considered deliberately, not omitted.
  @spec mark_active_instances_refresh_failed() :: :ok
  def mark_active_instances_refresh_failed, do: :ok

  # ---------------------------------------------------------------------------------
  # Read side -- called only by Letflow.Metrics.Exposition. Never mutates.
  # ---------------------------------------------------------------------------------

  @spec snapshot() :: %{
          gauges: %{metric_key() => number()},
          counters: %{metric_key() => non_neg_integer()},
          histograms: %{
            metric_key() => %{
              buckets: %{(float() | :infinity) => non_neg_integer()},
              sum: float(),
              count: non_neg_integer()
            }
          }
        }
  def snapshot do
    rows = :ets.tab2list(@table)

    gauges =
      for {{:gauge, family, labels}, value} <- rows, into: %{}, do: {{family, labels}, value}

    counters =
      for {{:counter, family, labels}, value} <- rows, into: %{}, do: {{family, labels}, value}

    histogram_keys =
      rows
      |> Enum.flat_map(fn
        {{:histogram_bucket, family, labels, _le}, _} -> [{family, labels}]
        {{:histogram_count, family, labels}, _} -> [{family, labels}]
        {{:histogram_sum, family, labels}, _} -> [{family, labels}]
        _other -> []
      end)
      |> Enum.uniq()

    histograms =
      for {family, labels} <- histogram_keys, into: %{} do
        buckets =
          for le <- @histogram_buckets, into: %{} do
            {le, get_row(rows, {:histogram_bucket, family, labels, le})}
          end

        count = get_row(rows, {:histogram_count, family, labels})
        sum_micros = get_row(rows, {:histogram_sum, family, labels})

        {{family, labels},
         %{
           buckets: Map.put(buckets, :infinity, count),
           sum: sum_micros / 1_000_000,
           count: count
         }}
      end

    %{gauges: gauges, counters: counters, histograms: histograms}
  end

  # ---------------------------------------------------------------------------------
  # Internal ETS mutation helpers -- atomic, lock-free from the caller's perspective.
  # ---------------------------------------------------------------------------------

  defp incr_counter(family, labels, amount) do
    key = {:counter, family, labels}
    :ets.update_counter(@table, key, {2, amount}, {key, 0})
    :ok
  end

  defp observe_histogram(family, labels, duration_native) do
    seconds =
      duration_native |> System.convert_time_unit(:native, :microsecond) |> Kernel./(1_000_000)

    micros = System.convert_time_unit(duration_native, :native, :microsecond)

    for le <- @histogram_buckets, seconds <= le do
      key = {:histogram_bucket, family, labels, le}
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
    end

    count_key = {:histogram_count, family, labels}
    :ets.update_counter(@table, count_key, {2, 1}, {count_key, 0})

    sum_key = {:histogram_sum, family, labels}
    :ets.update_counter(@table, sum_key, {2, micros}, {sum_key, 0})

    :ok
  end

  defp get_row(rows, key) do
    case List.keyfind(rows, key, 0) do
      {^key, value} -> value
      nil -> 0
    end
  end

  # Read-only inspection of the SQL keyword only (design §3) -- never the SQL text
  # itself, never stored beyond producing one of five fixed enum values.
  defp query_type_from_sql(nil), do: "other"

  defp query_type_from_sql(sql) when is_binary(sql) do
    case sql |> String.trim_leading() |> String.split(~r/\s+/, parts: 2) |> List.first() do
      nil -> "other"
      token -> classify_sql_keyword(String.upcase(token))
    end
  end

  defp query_type_from_sql(_other), do: "other"

  defp classify_sql_keyword("SELECT"), do: "select"
  defp classify_sql_keyword("INSERT"), do: "insert"
  defp classify_sql_keyword("UPDATE"), do: "update"
  defp classify_sql_keyword("DELETE"), do: "delete"
  defp classify_sql_keyword(_other), do: "other"
end
