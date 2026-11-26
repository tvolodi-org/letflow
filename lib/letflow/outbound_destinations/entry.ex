defmodule Letflow.OutboundDestinations.Entry do
  @moduledoc """
  One row of a tenant's OUTBOUND ALLOW-LIST (T-2597, pilot gap G14 -- the
  "Register a tenant" pilot).

  A row is one of two things, told apart by `destination`:

    * `destination IS NULL` -- the CHANNEL itself is allowed (the mail channel,
      the file channel). The door.
    * `destination IS NOT NULL` -- one DESTINATION is allowed on that channel:
      a recipient domain for the mail channel (`uat.letflow.internal`), a host
      for the HTTP channel. The address behind the door.

  The row holds no address, no subject, no body and no person (INV-4): a tenant
  id, a channel name, a destination name, the actor who added it and the time.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "outbound_destinations" do
    field(:tenant_id, :binary_id)
    field(:channel, :string)
    field(:destination, :string)
    field(:inserted_by, :binary_id)
    # Set only on a row listed by the G14 backfill (an already-active definition used it).
    field(:definition_id, :binary_id)
    field(:reason, :string)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry \\ %__MODULE__{}, attrs) do
    entry
    |> cast(attrs, [:tenant_id, :channel, :destination, :inserted_by, :definition_id, :reason])
    |> validate_required([:tenant_id, :channel])
    |> check_constraint(:channel, name: :outbound_destinations_channel_chk)
  end
end
