defmodule Letflow.ErrorCapture do
  @moduledoc """
  Server error capture and grouping (T-1951, maintenance slice 3 part A; design
  `docs/design/platform-maintenance.md` section 2.5). OFF by default (`config :letflow, :error_capture,
  enabled: false`; `LETFLOW_ERROR_CAPTURE_ENABLED=true` turns it on).

  ## Flow

  An unhandled raise under `/api/v1` (`Letflow.Plugs.ApiPipeline.handle_errors/2`) and every 5xx answer that
  is sent (`Letflow.Plugs.ErrorCapture`, 503 excepted: admission shedding, `/ready` and the export's
  "unavailable" are designed refusals) call `record/1`. `record/1` does ETS work only, in the caller's process:
  it never touches the database and never raises (it runs inside an error handler and a `before_send`
  callback, where a raise would replace the original error). `Letflow.ErrorCapture.Buffer` copies the counts
  into `error_groups` of the PLATFORM company's schema once per flush interval (60 s): that is the throttle,
  one write per signature per interval, while the counter keeps counting.

  ## Signature (`Letflow.ErrorCapture.Signature`)

  Source, kind, method, route template, error type, top `Letflow.*` frame, status. The exception message, frame
  arguments, file and line are never read or stored.

  ## Decisions

  * Only code names, the route template, method, status, the opaque trace id and the company id are kept.
    That is treated as operational telemetry, not "captured facts" of owner line 4 (security review confirms).
  * The affected-company set is capped at 100 per signature per window. Two concurrent first sightings of the
    same company may both bump the window's tenant counter, so the cap can be reached a little early; the
    stored set stays distinct and at most 100. A `record/1` that lands between the flush's snapshot and its
    `delete_object` sees the company as present and does not bump the counter: that company can be missing
    from the next window. Both effects are small and accepted.
  * Unhandled raises outside `/api/v1` are not captured (the root router has no `Plug.ErrorHandler`); their
    handled 5xx answers are.
  * Web capture (`source: "web"`) is a follow-up (part B); it calls `record/1` too.
  """

  alias Letflow.ErrorCapture.{Group, Signature}
  alias Letflow.PlatformTenant
  alias Letflow.Repo

  import Ecto.Query

  @main :letflow_error_capture
  @samples :letflow_error_capture_samples
  @ring 5
  @tenant_cap 100

  @doc false
  def main_table, do: @main
  @doc false
  def samples_table, do: @samples
  @doc false
  def ring_size, do: @ring
  @doc false
  def tenant_cap, do: @tenant_cap

  @doc "The configuration keyword list (`enabled`, `flush_interval_ms`, ...)."
  @spec config() :: keyword()
  def config, do: Application.get_env(:letflow, :error_capture, [])

  @doc "True when capture is switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc "Records an unhandled raise caught in `handle_errors/2`. Never raises."
  @spec record_exception(Plug.Conn.t(), atom(), term(), list()) :: :ok
  def record_exception(conn, kind, reason, stack) do
    if enabled?() do
      {method, route} = Signature.route_parts(conn)

      record(%{
        source: "server",
        kind: "exception",
        method: method,
        route: route,
        error_type: Signature.error_type(kind, reason, stack),
        top_frame: Signature.top_frame(stack),
        status: conn.status || 500,
        tenant_id: tenant_of(conn),
        trace_id: trace_of(conn)
      })
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Records a sent 5xx answer. Never raises."
  @spec record_response(Plug.Conn.t()) :: :ok
  def record_response(conn) do
    if enabled?() do
      {method, route} = Signature.route_parts(conn)

      record(%{
        source: "server",
        kind: "http_status",
        method: method,
        route: route,
        error_type: "http_" <> Integer.to_string(conn.status),
        top_frame: "",
        status: conn.status,
        tenant_id: tenant_of(conn),
        trace_id: trace_of(conn)
      })
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  The common ETS write. `entry` carries `:source, :kind, :method, :route, :error_type, :top_frame, :status`
  and optionally `:tenant_id`, `:trace_id`. ETS only; never raises.
  """
  @spec record(map()) :: :ok
  def record(entry) do
    if enabled?(), do: do_record(entry)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_record(entry) do
    meta = Map.take(entry, [:source, :kind, :method, :route, :error_type, :top_frame, :status])
    sig = Signature.compute(meta)
    max = Keyword.get(config(), :max_signatures, 1_000)

    if not :ets.member(@main, sig) and :ets.info(@main, :size) >= max do
      :ets.update_counter(@samples, :overflow, {2, 1}, {:overflow, 0})
    else
      :ets.insert_new(@main, {sig, 0, 0, 0, meta})
      record_trace(sig, Map.get(entry, :trace_id))
      record_tenant(sig, Map.get(entry, :tenant_id))
    end

    :ok
  end

  defp record_trace(sig, trace_id) when is_binary(trace_id) do
    [_count, seq] = :ets.update_counter(@main, sig, [{2, 1}, {3, 1}])
    :ets.insert(@samples, {{sig, :trace, rem(seq, @ring)}, seq, String.slice(trace_id, 0, 64)})
  end

  defp record_trace(sig, _none), do: :ets.update_counter(@main, sig, {2, 1})

  defp record_tenant(sig, tenant_id) when is_binary(tenant_id) do
    unless :ets.member(@samples, {sig, :tenant, tenant_id}) do
      n = :ets.update_counter(@main, sig, {4, 1})
      if n <= @tenant_cap, do: :ets.insert_new(@samples, {{sig, :tenant, tenant_id}})
    end
  end

  defp record_tenant(_sig, _none), do: :ok

  defp tenant_of(conn) do
    case conn.assigns |> Map.get(:auth_context, %{}) |> Map.get(:tenant_id) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp trace_of(conn) do
    case Map.get(conn.assigns, :trace_id) do
      id when is_binary(id) -> String.slice(id, 0, 64)
      _ -> nil
    end
  end

  @doc """
  The export: newest `last_seen_at` first, at most `limit` (1..100) groups as plain maps. The number of
  affected companies, never their ids.
  """
  @spec list_recent(1..100) :: {:ok, [map()]} | {:error, :unavailable}
  def list_recent(limit) when limit in 1..100 do
    with {:ok, prefix} <- PlatformTenant.platform_prefix() do
      rows =
        Repo.all(from(g in Group, order_by: [desc: g.last_seen_at, desc: g.seq], limit: ^limit),
          prefix: prefix
        )

      {:ok, Enum.map(rows, &export_map/1)}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp export_map(g) do
    %{
      number: "EG-#{g.seq}",
      source: g.source,
      kind: g.kind,
      method: g.method,
      route: g.route,
      error_type: g.error_type,
      top_frame: g.top_frame,
      status: g.status,
      count: g.count,
      hour_count: g.hour_count,
      hour: g.hour_bucket,
      tenants_affected: length(g.tenant_ids),
      last_trace_ids: g.last_trace_ids,
      first_seen_at: g.first_seen_at,
      last_seen_at: g.last_seen_at
    }
  end
end
