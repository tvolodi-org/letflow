defmodule Letflow.Engine.Contention do
  @moduledoc """
  GH #2706 (design `lib/letflow/design/gh2706-cancel-snapshot-and-lock-timeouts.md`, section 3):
  the lock-timeout values and the contention classifier shared by the cancel path and the timer fire.

    * `lock_timeout_ms/0`: the 5 s compile-time constant that BOTH the transaction-local DB
      `lock_timeout` of `Letflow.Engine.cancel_instance/3` and the time cap of its leftover retry
      loop read, so the two can never drift apart. In a build with
      `config :letflow, :engine_test_seams` set (the test config only; compiled out of
      production) a positive integer in the process dictionary key
      `:contention_lock_timeout_ms_override` of the CALLING process replaces it, which is how a
      test reaches a real `55P03` in about 300 ms without lowering the timeout globally. The
      override also moves the retry loop's time cap, since both read this function.
    * `lock_timeout_setting/0`: the same value as the text bound as the transaction-local
      `lock_timeout` setting of the cancel transaction (INV-7: a runtime value is a bound parameter, never part of the SQL text).
    * `timer_fire_lock_timeout_ms/0` and `timer_fire_lock_timeout_setting/0` (GH #2707): the
      PER-WAIT lock timeout of `Letflow.Scheduler.fire_timer/2` (config
      `:timer_fire_lock_timeout_ms`, 2 s default; process-local override
      `:timer_fire_lock_timeout_ms_override` in `:engine_test_seams` builds) and its bound text.
    * `contention_code/1`: classifies a raised exception as a lock timeout or a deadlock. Used by
      new code only; the three older copies in `Letflow.Engine` are deliberately untouched (design
      Q5).
  """

  @contention_lock_timeout_ms 5_000

  @doc "The lock timeout in milliseconds (the override, in test-seam builds, else 5 s)."
  @spec lock_timeout_ms() :: pos_integer()
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    def lock_timeout_ms do
      case Process.get(:contention_lock_timeout_ms_override) do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> @contention_lock_timeout_ms
      end
    end
  else
    def lock_timeout_ms, do: @contention_lock_timeout_ms
  end

  @default_timer_fire_lock_timeout_ms 2_000

  @doc """
  GH #2707 (PR-3): the PER-WAIT lock timeout of one timer-fire transaction in milliseconds
  (`config :letflow, :timer_fire_lock_timeout_ms`, default 2 s). In a `:engine_test_seams` build a
  positive integer in the process dictionary key `:timer_fire_lock_timeout_ms_override` of the
  CALLING process replaces it (a test reaches a real `55P03` in about 300 ms).
  """
  @spec timer_fire_lock_timeout_ms() :: pos_integer()
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    def timer_fire_lock_timeout_ms do
      case Process.get(:timer_fire_lock_timeout_ms_override) do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> configured_timer_fire_lock_timeout_ms()
      end
    end
  else
    def timer_fire_lock_timeout_ms, do: configured_timer_fire_lock_timeout_ms()
  end

  defp configured_timer_fire_lock_timeout_ms do
    case Application.get_env(:letflow, :timer_fire_lock_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_timer_fire_lock_timeout_ms
    end
  end

  @doc "`timer_fire_lock_timeout_ms/0` as the text bound as the transaction-local setting."
  @spec timer_fire_lock_timeout_setting() :: String.t()
  def timer_fire_lock_timeout_setting,
    do: Integer.to_string(timer_fire_lock_timeout_ms()) <> "ms"

  @default_cold_append_lock_timeout_ms 2_000

  @doc """
  GH #2707 (PR-2): the PER-WAIT lock timeout in milliseconds that the cold appenders (attachment
  events, a Lua `emit_event`) pass as `EventStore.append/2`'s `:lock_timeout_ms` (config
  `:cold_append_lock_timeout_ms`, default 2 s). In a `:engine_test_seams` build a positive integer
  in the process dictionary key `:cold_append_lock_timeout_ms_override` of the CALLING process
  replaces it.
  """
  @spec cold_append_lock_timeout_ms() :: pos_integer()
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    def cold_append_lock_timeout_ms do
      case Process.get(:cold_append_lock_timeout_ms_override) do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> configured_cold_append_lock_timeout_ms()
      end
    end
  else
    def cold_append_lock_timeout_ms, do: configured_cold_append_lock_timeout_ms()
  end

  defp configured_cold_append_lock_timeout_ms do
    case Application.get_env(:letflow, :cold_append_lock_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_cold_append_lock_timeout_ms
    end
  end

  @doc "`lock_timeout_ms/0` as the text bound as the transaction-local `lock_timeout` setting."
  @spec lock_timeout_setting() :: String.t()
  def lock_timeout_setting, do: Integer.to_string(lock_timeout_ms()) <> "ms"

  # GH #2868: the transaction-local `lock_timeout` statements live here, the leaf module, so that
  # `Letflow.EventStore` need not depend on `Letflow.Engine`. This file is the one whitelisted
  # `set_config` site for them in the T-11 scan (`stamp_opener_scan_test`): the setting name is a
  # literal, the value always a BOUND parameter (INV-7), `true` = transaction-local (`SET LOCAL`).

  @doc """
  GH #2706 (design 3.1): the first statement of the cancel transaction bounds every later lock wait
  with `lock_timeout_setting/0`. Skipped when the caller already holds a transaction (`nested?`):
  Ecto nested transactions use no savepoint, so the setting would outlive this call.
  """
  @spec set_cancel_lock_timeout(Ecto.Repo.t() | module(), nested? :: boolean()) ::
          {:ok, nil | :set}
  def set_cancel_lock_timeout(_repo, true), do: {:ok, nil}

  def set_cancel_lock_timeout(repo, false) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [lock_timeout_setting()])

    {:ok, :set}
  end

  @doc """
  GH #2707 (PR-3): the FIRST statement of a timer-fire transaction, `Letflow.Scheduler.fire_timer/2`,
  with the PER-WAIT value `timer_fire_lock_timeout_setting/0`. Skipped when the caller already
  holds a transaction.
  """
  @spec set_timer_fire_lock_timeout(Ecto.Repo.t() | module(), nested? :: boolean()) ::
          {:ok, nil | :set}
  def set_timer_fire_lock_timeout(_repo, true), do: {:ok, nil}

  def set_timer_fire_lock_timeout(repo, false) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [timer_fire_lock_timeout_setting()])

    {:ok, :set}
  end

  @doc """
  GH #2707 (PR-2): the same statement for `Letflow.EventStore.append/2`'s `:lock_timeout_ms`
  option (a cold appender's bound).
  """
  @spec set_lock_timeout_ms(Ecto.Repo.t() | module(), pos_integer()) :: {:ok, :set}
  def set_lock_timeout_ms(repo, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [
      Integer.to_string(timeout_ms) <> "ms"
    ])

    {:ok, :set}
  end

  @doc """
  `{:ok, code}` for a `Postgrex.Error` that is a lock timeout (`55P03`) or a deadlock victim
  (`40P01`); `:error` for everything else (other codes, connection errors, non-exceptions).
  """
  @spec contention_code(term()) :: {:ok, :lock_not_available | :deadlock_detected} | :error
  def contention_code(%Postgrex.Error{postgres: %{code: code}})
      when code in [:lock_not_available, :deadlock_detected],
      do: {:ok, code}

  def contention_code(_other), do: :error
end
