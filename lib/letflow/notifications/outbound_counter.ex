defmodule Letflow.Notifications.OutboundCounter do
  @moduledoc """
  The RESERVATION counter of a tenant's outbound send cap (T-2592, pilot gap G4).

  One row per (tenant, channel, period, window): the window is the clock hour
  or the UTC day the reservation belongs to, so the row is the singleton the
  atomic reservation locks (`send_count = send_count + 1 WHERE send_count <
  cap`).

  ## Why the counter is not the delivery log

  The cap used to be counted over the `notification_deliveries` rows, so a row
  that could not be written was a send that was never counted -- and the send
  had already left the platform. The counter is written BEFORE the send, so a
  send is accounted for whether or not the delivery log row can be written
  afterwards (the delivery log is the OUTCOME record; the counter is the
  CAP).

  ## What it holds

  A tenant id, a channel name, a period, a window and a number. No address, no
  subject, no body, no person (INV-4).

  ## The extension point

  `channel` is the outbound channel of the row: `"email"` today, the Telegram
  adapter's channel when it arrives. The cap is counted PER CHANNEL, so a second
  channel gets its own rows and its own count; the template key is NOT a
  dimension (a definition that rotates template keys must not reach several
  times the ceiling).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "notification_outbound_counters" do
    field(:tenant_id, :binary_id)
    field(:channel, :string)
    field(:period, :string)
    field(:window_started_at, :utc_datetime_usec)
    field(:send_count, :integer)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @periods ~w(hour day)

  @doc """
  The closed set of periods a counter row may carry: the clock hour and the
  UTC day.
  """
  @spec periods() :: [String.t()]
  def periods, do: @periods

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(counter \\ %__MODULE__{}, attrs) do
    counter
    |> cast(attrs, [:tenant_id, :channel, :period, :window_started_at, :send_count])
    |> validate_required([:tenant_id, :channel, :period, :window_started_at, :send_count])
    |> validate_inclusion(:period, @periods)
    |> check_constraint(:period, name: :notification_outbound_counters_period_chk)
    |> check_constraint(:send_count, name: :notification_outbound_counters_send_count_chk)
  end
end
