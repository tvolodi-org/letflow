defmodule Letflow.Entities.Views.View do
  @moduledoc """
  Persistence shape of an `entity_views` row (REQ-555, GH #3157, decision 0066).

  A saved list view: a name, one entity type, ordered `columns` (field names), and a `filter` and
  `sort` stored in the wire shape of `POST /entities/query` (`{"field","op","value"}`,
  `{"field","dir"}`). It holds no record value. The writer is `Letflow.Entities.Views`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "entity_views" do
    field(:tenant_id, :binary_id)
    field(:entity_type, :string)
    field(:name, :string)
    field(:columns, {:array, :string})
    field(:filter, {:array, :map})
    field(:sort, {:array, :map})
    field(:created_by, :binary_id)
    field(:updated_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
