defmodule Letflow.NumberSequences.Number do
  @moduledoc """
  Persistence shape of a `number_sequence_numbers` row (REQ-541, GH #3160): the allocation log,
  one row per numbered record, keyed by (entity type, record id). A row is never updated or
  deleted (trigger), so a deleted or cancelled record keeps its number and the number is never
  reused. The unique index on (sequence, period, number) is the backstop against a duplicate.
  """

  use Ecto.Schema

  @primary_key false
  schema "number_sequence_numbers" do
    field(:tenant_id, :binary_id)
    field(:sequence_id, :binary_id)
    field(:period, :string)
    field(:number, :integer)
    field(:entity_type, :string, primary_key: true)
    field(:record_id, Ecto.UUID, primary_key: true)
    field(:formatted, :string)
  end
end
