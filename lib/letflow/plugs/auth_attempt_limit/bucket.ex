defmodule Letflow.Plugs.AuthAttemptLimit.Bucket do
  @moduledoc """
  The ETS-backed token bucket behind `Letflow.Plugs.AuthAttemptLimit` (GH T-1558 part 1).
  Owns ONE named public ETS table, `:letflow_auth_attempt_limit`, separate from the
  public-read and login-discovery tables.

  Same lazy-refill idea as `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket`, with integer
  micro-token state so `consume/4` is a compare-and-swap. A row is
  `{{:auth_attempt, mode, address_id}, mode, tokens_u, last_ms}`; the live-row count sits in
  the bookkeeping row `{:count, :count, n}`.

  ## Bounded state

  Only lossless eviction: `sweep/1` deletes rows whose tokens have refilled to capacity
  (identical to an absent row). A new key must reserve a slot against `max_keys`; at the cap
  an inline sweep (throttled) runs and, if still full, the new key is refused (fail closed).
  A live key is never evicted.

  `peek/4`, `consume/4` and `sweep/1` are plain `:ets` calls made from the calling process;
  the `GenServer` only owns the table and the periodic sweep clock.
  """

  use GenServer

  alias Letflow.Plugs.AuthAttemptLimit, as: Limiter

  @table :letflow_auth_attempt_limit
  @micro 1_000_000
  @max_cas_attempts 8
  @inline_sweep_min_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Limiter.validate_config!(Application.get_env(:letflow, Limiter, []))

    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    Process.send_after(self(), :sweep, Limiter.config().sweep_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(System.monotonic_time(:millisecond))
    Process.send_after(self(), :sweep, Limiter.config().sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @spec table() :: :letflow_auth_attempt_limit
  def table, do: @table

  @doc "Test seam: empties the table (rows and count)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Looks at `key`'s bucket without spending a token. `:ok` when at least one token is
  available (or the key is absent and a slot is free), else `:rate_limited`. An absent key
  while the table is full (after one throttled sweep) is refused: fail closed.
  """
  @spec peek(tuple(), pos_integer(), number(), integer()) :: :ok | :rate_limited
  def peek(key, capacity, refill_per_sec, now_ms) do
    case :ets.lookup(@table, key) do
      [{^key, _mode, tokens_u, last_ms}] ->
        if refill(tokens_u, last_ms, now_ms, rate_u_s(refill_per_sec), capacity * @micro) >=
             @micro,
           do: :ok,
           else: :rate_limited

      [] ->
        if size() < Limiter.config().max_keys do
          :ok
        else
          maybe_inline_sweep(now_ms)
          if size() < Limiter.config().max_keys, do: :ok, else: :rate_limited
        end
    end
  end

  @doc """
  Spends one token of `key`'s bucket. `:rate_limited` when empty, when a new key finds the
  table full, or when the bounded CAS retries run out (fail closed).
  """
  @spec consume(tuple(), pos_integer(), number(), integer()) :: :ok | :rate_limited
  def consume(key, capacity, refill_per_sec, now_ms) do
    attempt(key, capacity * @micro, rate_u_s(refill_per_sec), now_ms, @max_cas_attempts)
  end

  @doc "Whole seconds (at least 1) until `key` holds one token again."
  @spec retry_after(tuple(), pos_integer(), number(), integer()) :: pos_integer()
  def retry_after(key, capacity, refill_per_sec, now_ms) do
    rate = rate_u_s(refill_per_sec)

    tokens_u =
      case :ets.lookup(@table, key) do
        [{^key, _mode, t, last}] -> refill(t, last, now_ms, rate, capacity * @micro)
        [] -> 0
      end

    max(1, ceil(max(@micro - tokens_u, 0) / rate))
  end

  defp attempt(_key, _cap_u, _rate, _now, 0), do: :rate_limited

  defp attempt({:auth_attempt, mode, _} = key, cap_u, rate, now_ms, left) do
    case :ets.lookup(@table, key) do
      [{^key, ^mode, tokens_u, last_ms} = row] ->
        refilled = refill(tokens_u, last_ms, now_ms, rate, cap_u)

        cond do
          refilled < @micro ->
            :rate_limited

          :ets.select_replace(@table, [
            {row, [], [{:const, {key, mode, refilled - @micro, now_ms}}]}
          ]) ==
              1 ->
            :ok

          true ->
            attempt(key, cap_u, rate, now_ms, left - 1)
        end

      [] ->
        case reserve_slot(now_ms) do
          :refused ->
            :rate_limited

          :reserved ->
            if :ets.insert_new(@table, {key, mode, cap_u - @micro, now_ms}) do
              :ok
            else
              release(1)
              attempt(key, cap_u, rate, now_ms, left - 1)
            end
        end
    end
  end

  defp reserve_slot(now_ms) do
    cap = Limiter.config().max_keys

    if bump() <= cap do
      :reserved
    else
      release(1)
      maybe_inline_sweep(now_ms)

      if bump() <= cap do
        :reserved
      else
        release(1)
        :refused
      end
    end
  end

  defp bump, do: :ets.update_counter(@table, :count, {3, 1}, {:count, :count, 0})

  defp release(n) do
    :ets.update_counter(@table, :count, {3, -n}, {:count, :count, 0})
    :ok
  end

  @doc "Live-row count, O(1)."
  @spec size() :: non_neg_integer()
  def size do
    case :ets.lookup(@table, :count) do
      [{:count, :count, n}] -> max(n, 0)
      [] -> 0
    end
  end

  defp maybe_inline_sweep(now_ms) do
    marker = :inline_sweep

    won? =
      case :ets.lookup(@table, marker) do
        [] ->
          :ets.insert_new(@table, {marker, :inline_sweep, now_ms})

        [{^marker, :inline_sweep, last} = old] ->
          now_ms - last >= @inline_sweep_min_interval_ms and
            :ets.select_replace(@table, [{old, [], [{:const, {marker, :inline_sweep, now_ms}}]}]) ==
              1
      end

    if won?, do: sweep(now_ms)
    :ok
  end

  @doc """
  Deletes exactly the idle rows (tokens refilled to capacity), returning the number deleted.
  """
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms) do
    config = Limiter.config()

    deleted =
      Enum.sum(
        for {mode, capacity, refill} <- [
              {:failures, config.failure_capacity, config.failure_refill_per_sec},
              {:requests, config.request_capacity, config.request_refill_per_sec}
            ] do
          select_delete_idle(mode, now_ms, capacity * @micro, rate_u_s(refill))
        end
      )

    # Delete first, decrement second: the count only ever over-estimates.
    if deleted > 0, do: release(deleted)
    deleted
  end

  defp select_delete_idle(mode, now_ms, cap_u, rate) do
    elapsed = {:-, now_ms, :"$3"}

    guard = [
      {:andalso, {:>=, elapsed, 0}, {:>=, {:+, :"$2", {:div, {:*, elapsed, rate}, 1000}}, cap_u}}
    ]

    :ets.select_delete(@table, [{{:"$1", mode, :"$2", :"$3"}, guard, [true]}])
  end

  defp refill(tokens_u, last_ms, now_ms, rate, cap_u) do
    elapsed = max(now_ms - last_ms, 0)
    min(cap_u, tokens_u + div(elapsed * rate, 1000))
  end

  defp rate_u_s(refill_per_sec), do: round(refill_per_sec * @micro)
end
