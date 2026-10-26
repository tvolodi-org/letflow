defmodule Letflow.Plugs.ProvisionerAuth.RateLimiter do
  @moduledoc """
  REQ-572 / decision 0072 P10: the fixed-window rate limit of the provisioner credential, one budget
  per credential class (`:write`, `:read`). Only an ACCEPTED credential consumes the budget, so a
  flood of bad credentials costs nothing here.

  Config (`config :letflow, Letflow.Plugs.ProvisionerAuth`): `limit` (default 60), `window_seconds`
  (default 60), `clock` (a 0-arity function returning seconds, for tests).

  Owned by this small process only so that the named ETS table has a supervised owner; every read and
  write goes straight to ETS from the calling process. When the table does not exist the request is
  admitted (the limiter is absent, not a reason to refuse a credentialed call).
  """

  use GenServer

  @table :letflow_provisioner_rate_limit
  @default_limit 60
  @default_window 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
    {:ok, %{}}
  end

  @doc """
  Counts one request for `class`. `:ok`, or `{:error, retry_after}` with whole seconds to the end of
  the window, clamped to `1..window`.
  """
  @spec hit(:write | :read) :: :ok | {:error, pos_integer()}
  def hit(class) when class in [:write, :read] do
    config = Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth, [])
    limit = Keyword.get(config, :limit, @default_limit)
    window = Keyword.get(config, :window_seconds, @default_window)
    now = clock(config)
    window_start = div(now, window) * window

    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        count = :ets.update_counter(@table, {class, window_start}, 1, {{class, window_start}, 0})
        :ets.select_delete(@table, [{{{class, :"$1"}, :_}, [{:<, :"$1", window_start}], [true]}])

        if count > limit do
          {:error, min(max(window_start + window - now, 1), window)}
        else
          :ok
        end
    end
  end

  @doc "Empties the table (tests)."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp clock(config) do
    case Keyword.get(config, :clock) do
      fun when is_function(fun, 0) -> fun.()
      _default -> System.system_time(:second)
    end
  end
end
