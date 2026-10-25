defmodule Letflow.NumberSequences.Definition do
  @moduledoc """
  Persistence shape of a `number_sequence_definitions` row (REQ-541, GH #3160).

  One definition is bound to exactly one entity type (unique index on `entity_type`). It is
  insert-only: the migration refuses an UPDATE or DELETE. The writer is
  `Letflow.NumberSequences.create_definition/2` (audited: `create_definition_audited/3`).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "number_sequence_definitions" do
    field(:tenant_id, :binary_id)
    field(:key, :string)
    field(:entity_type, :string)
    field(:prefix, :string)
    field(:padding, :integer)
    field(:period, :string)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
