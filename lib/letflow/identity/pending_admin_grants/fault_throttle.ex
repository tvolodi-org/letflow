defmodule Letflow.Identity.PendingAdminGrants.FaultThrottle do
  @moduledoc """
  ISS-1030 (design section 7 step 11, OQ-16): the once-per-tenant-per-hour
  throttle for the WARNING that `Letflow.Identity.PendingAdminGrants.bind_on_login/5`
  logs when a bind hits a real fault (no platform tenant configured, a missing
  `TENANT_ADMIN` binding, a database error, a lock timeout, a missing table).

  A fault must be visible to an operator, but the bind runs on the login path,
  so an unthrottled line would be one per request. The table is keyed by tenant
  id (a database-resolved value, so its size is bounded by the number of
  tenants) and holds the monotonic second of the last line logged.

  Owned by this small process only so that the named ETS table has a supervised
  owner; every read and write goes straight to ETS from the calling process.
  """

  use GenServer

  @table :letflow_pending_admin_bind_fault_throttle
  @window_seconds 3_600

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
    {:ok, %{}}
  end

  @doc """
  True when a warning for `tenant_id` may be logged now (and records that it
  was), false when one was already logged within the last hour. When the table
  does not exist (the process is not running) it answers true: a fault is never
  hidden because the throttle is absent.
  """
  @spec allow?(tenant_id :: String.t()) :: boolean()
  def allow?(tenant_id) do
    now = System.monotonic_time(:second)

    case :ets.whereis(@table) do
      :undefined ->
        true

      _tid ->
        case :ets.lookup(@table, tenant_id) do
          [{_key, last}] when now - last < @window_seconds ->
            false

          _none_or_expired ->
            :ets.insert(@table, {tenant_id, now})
            true
        end
    end
  end

  @doc "The name of the ETS table (for tests)."
  @spec table() :: atom()
  def table, do: @table
end
