defmodule Letflow.SharedStockAccess.Credential do
  @moduledoc """
  REQ-858 (decision 0091 section 4.2): one row of the tenant schema table `shared_stock_access`.

  Holds only the lowercase hex SHA-256 of the value (`token_hash`), never the value (INV-4).
  The struct is never encoded into a response: `Letflow.Routers.Identity` builds its answer
  from an explicit allowlist. Rows are written only by `Letflow.SharedStockAccess`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "shared_stock_access" do
    field(:token_hash, :string, redact: true)
    field(:actor_id, :binary_id)
    field(:created_by_user_id, :binary_id)
    field(:created_at, :utc_datetime_usec)
    field(:rotated_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:revoked_by_user_id, :binary_id)

    timestamps()
  end

  @type t :: %__MODULE__{}
end
