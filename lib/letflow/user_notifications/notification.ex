defmodule Letflow.UserNotifications.Notification do
  @moduledoc """
  Persistence shape of a `user_notifications` row (T-1561): one in-app notification of one user.
  `tenant_id` is kept in the row (INV-1); the schema prefix is the isolation.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "user_notifications" do
    field(:tenant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:kind, :string)
    field(:ref_id, :binary_id)
    field(:title, :string)
    field(:read_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
