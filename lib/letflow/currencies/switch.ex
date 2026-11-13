defmodule Letflow.Currencies.Switch do
  @moduledoc """
  Persistence shape of a `tenant_currencies` row (REQ-823, GH #4394): the tenant's switch for one
  currency code (`active`) and the mark of the tenant currency (`tenant_currency`, at most one
  true row). The only writer is `Letflow.Currencies`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenant_currencies" do
    field(:tenant_id, :binary_id)
    field(:code, :string)
    field(:active, :boolean, default: false)
    field(:tenant_currency, :boolean, default: false)
    field(:updated_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
