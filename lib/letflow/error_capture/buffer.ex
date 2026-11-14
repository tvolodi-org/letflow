defmodule Letflow.ErrorCapture.Buffer do
  @moduledoc """
  Owner of the two public ETS tables behind `Letflow.ErrorCapture.record/1` and the flusher that copies them
  into `error_groups` (T-1951, design section 5.2). Pattern: `Letflow.Api.Scope.ShadowEvidence`.

  ## Tables

  * `:letflow_error_capture` (set), one tuple per signature: `{signature, count, trace_seq, tenant_n, meta}`
    (positions 2, 3, 4 are the `update_counter` positions).
  * `:letflow_error_capture_samples` (set): the trace ring `{{sig, :trace, slot}, seq, trace_id}` with
    `slot = rem(seq, 5)` (the LAST 5 trace ids of the window), the tenant set `{{sig, :tenant, tenant_id}}`
    (at most 100 per signature per window) and the `:overflow` counter.

  ## Flush

  Once per `:flush_interval_ms` (and on `flush/1`), when capture is enabled and the platform company
  resolves, per signature with a count: ONE `Repo.insert_all/3` upsert in the platform schema (INV-1; the
  prefix is server configuration, never request input; INV-7: placeholders only). The inserted row stamps
  every time column with the flush's own `now`; "new" is `alerted_new_at IS NULL`, driven by a conditional
  UPDATE, not by comparing times. On success exactly the snapshot amount is subtracted and exactly the
  snapshot sample objects are deleted, so records made during the flush survive. A transient failure keeps
  the entries and logs one constant line. When capture is off or no platform company is configured the
  buffered entries are dropped (no unbounded growth).

  ## Shutdown

  `terminate/2` flushes with `alerts: false` and catches exits: `Letflow.Obs.Alerts.TaskSupervisor` is the last
  infrastructure child and has already stopped. Groups written there alert on the next flush after boot.
  """

  use GenServer, shutdown: 10_000

  import Ecto.Query

  require Logger

  alias Letflow.ErrorCapture
  alias Letflow.ErrorCapture.Group
  alias Letflow.Obs.Alerts
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @main ErrorCapture.main_table()
  @samples ErrorCapture.samples_table()
  @default_interval 60_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Flushes synchronously (tests; the timer calls the same code). `alerts: false` skips the alert calls.
  `{:error, :not_running}` when the process is down.
  """
  @spec flush(keyword()) :: :ok | {:error, term()}
  def flush(opts \\ [alerts: true]) do
    GenServer.call(__MODULE__, {:flush, Keyword.get(opts, :alerts, true)}, 30_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Runs the retention prune now (tests). Returns the number of rows cleared."
  @spec prune_now() :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_now do
    GenServer.call(__MODULE__, :prune, 30_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # -- GenServer ----------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@main, [:public, :named_table, :set, {:write_concurrency, true}])
    :ets.new(@samples, [:public, :named_table, :set, {:write_concurrency, true}])
    schedule()
    {:ok, %{pruned_day: Date.utc_today()}}
  end

  @impl GenServer
  def handle_call({:flush, alerts?}, _from, state) do
    {result, state} = run_flush(state, alerts?)
    {:reply, result, state}
  end

  def handle_call(:prune, _from, state) do
    {:reply, safe_prune(), state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    {_result, state} = run_flush(state, true)
    schedule()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    try do
      _ = run_flush(state, false)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
      _, _ -> :ok
    end

    :ok
  end

  defp schedule do
    interval = Keyword.get(ErrorCapture.config(), :flush_interval_ms, @default_interval)
    Process.send_after(self(), :flush, interval)
  end

  # -- Flush ----------------------------------------------------------------------------------

  defp run_flush(state, alerts?) do
    result = do_flush(alerts?)
    state = maybe_prune(state)
    {result, state}
  rescue
    _ ->
      log_failure("error")
      {{:error, :flush_failed}, state}
  catch
    kind, _ ->
      log_failure(to_string(kind))
      {{:error, :flush_failed}, state}
  end

  defp do_flush(alerts?) do
    report_overflow()

    with true <- ErrorCapture.enabled?(),
         {:ok, prefix} <- PlatformTenant.platform_prefix(),
         {:ok, platform_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      :ets.select_delete(@main, [{{:_, 0, :_, :_, :_}, [], [true]}])
      now = DateTime.utc_now()

      results =
        for {sig, count, _seq, tenant_n, meta} <- :ets.tab2list(@main), count > 0 do
          flush_one(prefix, platform_id, now, alerts?, {sig, count, tenant_n, meta})
        end

      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :flush_failed}
    else
      _disabled_or_unconfigured ->
        :ets.delete_all_objects(@main)
        :ets.delete_all_objects(@samples)
        :ok
    end
  end

  defp flush_one(prefix, platform_id, now, alerts?, {sig, count, tenant_n, meta}) do
    traces = :ets.match_object(@samples, {{sig, :trace, :_}, :_, :_})
    tenants = :ets.match_object(@samples, {{sig, :tenant, :_}})

    trace_ids =
      traces
      |> Enum.sort_by(fn {_k, seq, _t} -> seq end, :desc)
      |> Enum.map(fn {_k, _s, t} -> t end)

    tenant_ids = Enum.map(tenants, fn {{_sig, :tenant, id}} -> id end)
    bucket = hour_of(now)

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: platform_id,
      signature: sig,
      source: meta.source,
      kind: meta.kind,
      method: meta.method,
      route: meta.route,
      error_type: meta.error_type,
      top_frame: meta.top_frame,
      status: meta.status,
      count: count,
      hour_bucket: bucket,
      hour_count: count,
      tenant_ids: tenant_ids,
      last_trace_ids: trace_ids,
      first_seen_at: now,
      last_seen_at: now,
      inserted_at: now,
      updated_at: now
    }

    {_n, [group]} = upsert(prefix, row)

    :ets.update_counter(@main, sig, [{2, -count}, {4, -tenant_n}])
    Enum.each(traces, &:ets.delete_object(@samples, &1))
    Enum.each(tenants, &:ets.delete_object(@samples, &1))

    if alerts?, do: alert(prefix, group, now)
    :ok
  rescue
    e ->
      log_failure(inspect(e.__struct__))
      :error
  catch
    kind, _ ->
      log_failure(to_string(kind))
      :error
  end

  defp upsert(prefix, row) do
    Repo.insert_all(Group, [row],
      prefix: prefix,
      on_conflict:
        from(g in Group,
          update: [
            set: [
              count: fragment("? + EXCLUDED.count", g.count),
              last_seen_at: fragment("EXCLUDED.last_seen_at"),
              updated_at: fragment("EXCLUDED.updated_at"),
              hour_count:
                fragment(
                  "CASE WHEN ? = EXCLUDED.hour_bucket THEN ? + EXCLUDED.hour_count ELSE EXCLUDED.hour_count END",
                  g.hour_bucket,
                  g.hour_count
                ),
              hour_bucket: fragment("EXCLUDED.hour_bucket"),
              tenant_ids:
                fragment(
                  "(SELECT COALESCE(array_agg(x), '{}') FROM (SELECT DISTINCT x FROM unnest(? || EXCLUDED.tenant_ids) AS x LIMIT 100) t)",
                  g.tenant_ids
                ),
              last_trace_ids: fragment("(EXCLUDED.last_trace_ids || ?)[1:5]", g.last_trace_ids)
            ]
          ]
        ),
      conflict_target: [:signature],
      returning: [
        :id,
        :seq,
        :source,
        :kind,
        :method,
        :route,
        :error_type,
        :top_frame,
        :status,
        :count,
        :hour_bucket,
        :hour_count,
        :tenant_ids,
        :first_seen_at,
        :last_seen_at,
        :alerted_new_at,
        :growth_alerted_hour
      ]
    )
  end

  # -- Alerts ---------------------------------------------------------------------------------

  defp alert(prefix, group, now) do
    threshold = Keyword.get(ErrorCapture.config(), :growth_alert_per_hour, 20)

    if is_nil(group.alerted_new_at) do
      {n, _} =
        Repo.update_all(
          from(g in Group, where: g.id == ^group.id and is_nil(g.alerted_new_at)),
          [set: [alerted_new_at: now]],
          prefix: prefix
        )

      if n == 1, do: notify(prefix, group, "new")
    end

    if group.hour_count > threshold do
      bucket = group.hour_bucket

      {n, _} =
        Repo.update_all(
          from(g in Group,
            where:
              g.id == ^group.id and
                (is_nil(g.growth_alerted_hour) or g.growth_alerted_hour != ^bucket)
          ),
          [set: [growth_alerted_hour: bucket]],
          prefix: prefix
        )

      if n == 1, do: notify(prefix, group, "growth")
    end

    :ok
  end

  defp notify(prefix, group, reason) do
    payload = %{
      "trigger" => "error_group_alert",
      "reason" => reason,
      "group" => "EG-#{group.seq}",
      "group_id" => group.id,
      "source" => group.source,
      "kind" => group.kind,
      "method" => group.method,
      "route" => group.route,
      "error_type" => group.error_type,
      "top_frame" => group.top_frame,
      "status" => group.status,
      "count" => group.count,
      "hour_count" => group.hour_count,
      "hour" => DateTime.to_iso8601(group.hour_bucket),
      "tenants_affected" => length(group.tenant_ids),
      "first_seen_at" => DateTime.to_iso8601(group.first_seen_at),
      "last_seen_at" => DateTime.to_iso8601(group.last_seen_at)
    }

    Alerts.notify_error_group(prefix, payload)
  catch
    :exit, _ -> :ok
  end

  # -- Retention ------------------------------------------------------------------------------

  defp maybe_prune(%{pruned_day: day} = state) do
    today = Date.utc_today()

    if day == today do
      state
    else
      _ = safe_prune()
      %{state | pruned_day: today}
    end
  end

  # Owner line 9: after the retention period the company and trace ids go; the counts stay.
  defp safe_prune do
    with true <- ErrorCapture.enabled?(),
         {:ok, prefix} <- PlatformTenant.platform_prefix() do
      days = Keyword.get(ErrorCapture.config(), :retention_days, 90)
      cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

      {n, _} =
        Repo.update_all(
          from(g in Group, where: g.last_seen_at < ^cutoff),
          [set: [tenant_ids: [], last_trace_ids: []]],
          prefix: prefix
        )

      {:ok, n}
    else
      _ -> {:ok, 0}
    end
  rescue
    _ ->
      log_failure("prune")
      {:error, :prune_failed}
  end

  # -- Helpers --------------------------------------------------------------------------------

  defp hour_of(%DateTime{} = now), do: %{now | minute: 0, second: 0, microsecond: {0, 6}}

  defp report_overflow do
    case :ets.lookup(@samples, :overflow) do
      [{:overflow, n}] when n > 0 ->
        :ets.delete(@samples, :overflow)
        Logger.warning("error_capture_overflow count=#{n}")

      _ ->
        :ok
    end
  end

  defp log_failure(class), do: Logger.error("error_capture_flush_failed class=#{class}")
end
