defmodule Letflow.NumberSequences.Counter do
  @moduledoc """
  Persistence shape of a `number_sequence_counters` row (REQ-541, GH #3160): one counter per
  (definition, period), `period` being the year as text or the literal `"none"`. The counter
  only grows (trigger `number_sequence_counters_guard_update`). The only writer is
  `Letflow.NumberSequences`, under the row lock of decision 0056 D2.
  """

  use Ecto.Schema

  @primary_key false
  schema "number_sequence_counters" do
    field(:tenant_id, :binary_id)
    field(:sequence_id, :binary_id, primary_key: true)
    field(:period, :string, primary_key: true)
    field(:counter, :integer, default: 0)
  end
end
