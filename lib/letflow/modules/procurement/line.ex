defmodule Letflow.Modules.Procurement.Line do
  @moduledoc """
  Persistence shape of a `procurement_lines` row (GH #3188, REQ-558 part 1): the per-line state that
  is not an event. Today only `fulfilled_quantity`, which starts at 0 and is only read: no operation
  of this slice records fulfilment (receipt, acceptance and payment request are later slices).

  A row exists only once the first event of the line is recorded; a missing row means 0.
  """

  use Ecto.Schema

  @primary_key false

  schema "procurement_lines" do
    field(:document_id, :binary_id, primary_key: true)
    field(:line_no, :integer, primary_key: true)
    field(:fulfilled_quantity, :decimal)
    field(:inserted_at, :utc_datetime_usec)
  end
end
