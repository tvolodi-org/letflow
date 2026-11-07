defmodule Letflow.UserPreferences.Preference do
  @moduledoc """
  Persistence shape of a `user_preferences` row (T-1389): one preference key of one user, unique
  on `(user_id, key)`. `value` holds the wrapper `%{"v" => value}` (Ecto `:map` cannot hold a
  bare scalar); only `Letflow.UserPreferences` wraps and unwraps it. No `tenant_id`: the schema
  is the isolation (decision 0006 D2).
  """

  use Ecto.Schema

  @primary_key false
  schema "user_preferences" do
    field(:user_id, :binary_id)
    field(:key, :string)
    field(:value, :map)

    timestamps(type: :utc_datetime_usec, inserted_at: false)
  end

  @type t :: %__MODULE__{}
end
