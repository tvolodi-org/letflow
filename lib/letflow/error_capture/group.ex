defmodule Letflow.ErrorCapture.Group do
  @moduledoc """
  Persistence shape of an `error_groups` row (T-1951). Written only in the platform company's schema
  (see `Letflow.ErrorCapture.Buffer`); `tenant_id` is the platform tenant. `seq` is the number shown as
  `EG-<seq>`. No exception message, no user text and no user id is ever stored here.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "error_groups" do
    field(:seq, :integer, read_after_writes: true)
    field(:tenant_id, :binary_id)
    field(:signature, :string)
    field(:source, :string)
    field(:kind, :string)
    field(:method, :string)
    field(:route, :string)
    field(:error_type, :string)
    field(:top_frame, :string)
    field(:status, :integer)
    field(:message, :string)
    field(:count, :integer, default: 0)
    field(:hour_bucket, :utc_datetime_usec)
    field(:hour_count, :integer, default: 0)
    field(:tenant_ids, {:array, :binary_id}, default: [])
    field(:last_trace_ids, {:array, :string}, default: [])
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:alerted_new_at, :utc_datetime_usec)
    field(:growth_alerted_hour, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
