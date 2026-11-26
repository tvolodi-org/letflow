defmodule Letflow.Notifications.OutboundCap do
  @moduledoc """
  The outbound SEND CAP of a tenant (T-2592, pilot gap G4): the RESERVATION that
  accounts for a send BEFORE it leaves the platform.

  ## What it does

  `reserve/3` takes one slot out of the tenant's cap for the current clock hour
  and for the current UTC day: the counter rows of the two windows are created if they do not exist yet, and each is incremented with a
  single guarded statement (`send_count = send_count + 1 WHERE send_count <
  cap`). The increment is atomic, so two sends of the same tenant at the same
  moment cannot both take the last slot -- the ceiling holds, not "the ceiling
  holds unless two sends overlap".

  ## Why the reservation comes BEFORE the send

  The cap used to be counted over the `notification_deliveries` rows, so the
  send was accounted for only once its OUTCOME row could be written -- and the
  send had already left the platform by then. A delivery log that cannot be
  written (a database error, a row that does not fit) was then a send that
  never counted, and the tenant's ceiling never tripped: the flooding the cap
  exists to stop. The reservation is taken before the adapter is called, so a
  send is counted whether or not the outcome row can be written afterwards.

  ## Fail closed

  A cap that cannot be read or reserved is a cap that is OVER: the reservation
  refuses the send. A flood is cheaper than a missed cap, and a send that was
  not reserved is a send nobody can account for.

  ## The transaction boundary

  The reservation opens NO transaction of its own and never rolls one back. An
  over-cap refusal is a typed result: the guarded `UPDATE` matched no row, so
  there is nothing to undo, and the caller's transaction stays usable (a
  `Repo.rollback/1` inside a nested `Repo.transaction/1` is a full ROLLBACK in
  production, where the nested begin is a no-op; the sandbox hides it with a
  SAVEPOINT). When the hour slot was taken and the day window is over, the hour
  slot is given back by a compensating decrement.

  A reservation made INSIDE a caller's transaction is part of that transaction
  and is lost if it rolls back. The caller must therefore call the dispatcher
  OUTSIDE the engine's own transaction, exactly as the sibling platform-step
  dispatcher is called from its poller (`Letflow.PlatformFunctions.Dispatcher`).

  ## Pure and total

  Never raises: every failure is a typed result. The prefix is the tenant
  schema the counter lives in (INV-1).
  """

  import Ecto.Query

  alias Letflow.Notifications.OutboundCounter
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  # The outbound channel of the counter rows. The Telegram adapter is the next
  # channel: it gets its own rows and its own count (the cap is per tenant and
  # CHANNEL).
  @channel "email"

  @doc """
  Reserves one send for the tenant of `prefix` on the MAIL channel.

  The tenant id of the counter rows is DERIVED from the prefix the rows are
  written into (INV-1 (c)); it is never taken from the caller. A prefix that
  names no tenant is `{:error, :cap_unavailable}`.

  `hour_cap` and `day_cap` are the caps of the tenant (a tenant may lower the
  platform ceiling, never raise it).

  Returns `:reserved` when the slot was taken, `{:error, :rate_limited}` when
  the tenant is over its cap, and `{:error, :cap_unavailable}` when the cap
  could not be read or reserved at all -- both refusals mean NOTHING is sent.
  """
  @spec reserve(String.t(), pos_integer(), pos_integer()) ::
          :reserved | {:error, :rate_limited | :cap_unavailable}
  def reserve(prefix, hour_cap, day_cap)
      when is_binary(prefix) and is_integer(hour_cap) and is_integer(day_cap) do
    reserve(prefix, @channel, hour_cap, day_cap)
  end

  @doc """
  Reserves one send for the tenant of `prefix` on the CHANNEL `channel`.

  The cap is counted PER CHANNEL (the G2 authority record, option A (c) item 7:
  "a cap per tenant and channel, per hour and per day"), so the file channel
  of the notification step (T-2596, pilot gap G12) has its own rows and its
  own count: a tenant that sends a lot of mail may still write its files, and
  a definition that writes files in a loop cannot fill the tenant's disk.

  The channel name is a closed set of strings, chosen by the caller that owns
  the channel -- never by a tenant's data.
  """
  @spec reserve(String.t(), String.t(), pos_integer(), pos_integer()) ::
          :reserved | {:error, :rate_limited | :cap_unavailable}
  def reserve(prefix, channel, hour_cap, day_cap)
      when is_binary(prefix) and is_binary(channel) and is_integer(hour_cap) and
             is_integer(day_cap) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hour_start = window(now, :hour)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- reserve_window(prefix, tenant_id, channel, "hour", hour_cap, hour_start) do
      case reserve_window(prefix, tenant_id, channel, "day", day_cap, window(now, :day)) do
        :ok ->
          :reserved

        {:error, code} ->
          # Give the hour slot back: nothing is sent, so nothing is spent.
          release_window(prefix, tenant_id, channel, "hour", hour_start)
          to_result(code)
      end
    else
      {:error, code} -> to_result(code)
    end
  rescue
    _exception -> {:error, :cap_unavailable}
  catch
    _kind, _reason -> {:error, :cap_unavailable}
  end

  defp to_result({:over_cap, _period}), do: {:error, :rate_limited}
  defp to_result(_other), do: {:error, :cap_unavailable}

  defp release_window(prefix, tenant_id, channel, period, window_start) do
    Repo.update_all(
      from(c in OutboundCounter,
        where:
          c.tenant_id == ^tenant_id and c.channel == ^channel and c.period == ^period and
            c.window_started_at == ^window_start and c.send_count > 0,
        update: [set: [send_count: fragment("? - 1", c.send_count)]]
      ),
      [],
      prefix: prefix
    )

    :ok
  end

  # The window a reservation belongs to: the clock hour and the UTC day. A
  # FIXED window (not a sliding one over the log), so the row is the singleton
  # the atomic increment locks. `DateTime.truncate/2` knows only the second,
  # the millisecond and the microsecond, so the coarser windows are cut here.
  defp window(now, :hour), do: %{now | minute: 0, second: 0, microsecond: {0, 0}}
  defp window(now, :day), do: %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

  # One window's reservation: the row is created if the window has none yet,
  # then the count is incremented with a single guarded statement. The guard is
  # in the statement itself (`send_count < cap`), so two concurrent
  # reservations of the same tenant cannot both take the last slot.
  defp reserve_window(prefix, tenant_id, channel, period, cap, window_start) do
    with :ok <- ensure_row(prefix, tenant_id, channel, period, window_start) do
      {updated, _returned} =
        Repo.update_all(
          from(c in OutboundCounter,
            where:
              c.tenant_id == ^tenant_id and c.channel == ^channel and c.period == ^period and
                c.window_started_at == ^window_start and c.send_count < ^cap,
            update: [set: [send_count: fragment("? + 1", c.send_count)]]
          ),
          [],
          prefix: prefix
        )

      if updated == 1 do
        :ok
      else
        {:error, {:over_cap, period}}
      end
    end
  end

  defp ensure_row(prefix, tenant_id, channel, period, window_start) do
    %OutboundCounter{}
    |> OutboundCounter.changeset(%{
      tenant_id: tenant_id,
      channel: channel,
      period: period,
      window_started_at: window_start,
      send_count: 0
    })
    |> Repo.insert(
      prefix: prefix,
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :channel, :period, :window_started_at]
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, _changeset} -> {:error, :counter_unavailable}
    end
  end
end
