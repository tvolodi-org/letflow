defmodule Letflow.Notifications.OutboundCap do
  @moduledoc """
  The outbound SEND CAP of a tenant (T-2592, pilot gap G4): the RESERVATION that
  accounts for a send BEFORE it leaves the platform.

  ## What it does

  `reserve/4` takes one slot out of the tenant's cap for the current clock hour
  and for the current UTC day, in ONE transaction: the counter rows of the two
  windows are created if they do not exist yet, and each is incremented with a
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

  The reservation runs in its own transaction, so it is committed before the
  send leaves -- a rollback of the caller's transaction cannot take the
  reservation with it. The caller must therefore call the dispatcher OUTSIDE
  the engine's own transaction, exactly as the sibling platform-step dispatcher
  is called from its poller (`Letflow.PlatformFunctions.Dispatcher`).

  ## Pure and total

  Never raises: every failure is a typed result. The prefix is the tenant
  schema the counter lives in (INV-1).
  """

  import Ecto.Query

  alias Letflow.Notifications.OutboundCounter
  alias Letflow.Repo

  # The outbound channel of the counter rows. The Telegram adapter is the next
  # channel: it gets its own rows and its own count (the cap is per tenant and
  # CHANNEL).
  @channel "email"

  @doc """
  Reserves one send for the tenant of `prefix`.

  `hour_cap` and `day_cap` are the caps of the tenant (a tenant may lower the
  platform ceiling, never raise it).

  Returns `:reserved` when the slot was taken, `{:error, :rate_limited}` when
  the tenant is over its cap, and `{:error, :cap_unavailable}` when the cap
  could not be read or reserved at all -- both refusals mean NOTHING is sent.
  """
  @spec reserve(String.t(), Ecto.UUID.t(), pos_integer(), pos_integer()) ::
          :reserved | {:error, :rate_limited | :cap_unavailable}
  def reserve(prefix, tenant_id, hour_cap, day_cap)
      when is_binary(prefix) and is_binary(tenant_id) and is_integer(hour_cap) and
             is_integer(day_cap) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.transaction(fn ->
           with :ok <- reserve_window(prefix, tenant_id, "hour", hour_cap, window(now, :hour)),
                :ok <- reserve_window(prefix, tenant_id, "day", day_cap, window(now, :day)) do
             :reserved
           else
             # The rollback carries the CODE, so the caller can tell a cap that
             # is over from a cap that could not be read at all.
             {:error, code} -> Repo.rollback(code)
           end
         end) do
      {:ok, :reserved} -> :reserved
      {:error, {:over_cap, _period}} -> {:error, :rate_limited}
      {:error, _other} -> {:error, :cap_unavailable}
    end
  rescue
    _exception -> {:error, :cap_unavailable}
  catch
    _kind, _reason -> {:error, :cap_unavailable}
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
  defp reserve_window(prefix, tenant_id, period, cap, window_start) do
    with :ok <- ensure_row(prefix, tenant_id, period, window_start) do
      {updated, _returned} =
        Repo.update_all(
          from(c in OutboundCounter,
            where:
              c.tenant_id == ^tenant_id and c.channel == ^@channel and c.period == ^period and
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

  defp ensure_row(prefix, tenant_id, period, window_start) do
    %OutboundCounter{}
    |> OutboundCounter.changeset(%{
      tenant_id: tenant_id,
      channel: @channel,
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
