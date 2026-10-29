defmodule Letflow.Modules.Procurement.LineEvent do
  @moduledoc """
  Persistence shape of a `procurement_line_events` row (GH #3188, REQ-558 part 1): one officer
  assignment, supplier selection or PO/contract reference of one purchase request line.

  Insert-only: `Letflow.Modules.Procurement.LineEvents` is the only writer and has no update or
  delete. There is no `tenant_id` column; the schema prefix is the tenant (0006 D2).
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "procurement_line_events" do
    field(:document_id, :binary_id)
    field(:line_no, :integer)
    field(:version_no, :integer)
    field(:kind, Ecto.Enum, values: [:officer, :supplier, :reference])
    field(:data, :map)
    field(:performer, :binary_id)
    field(:recorded_at, :utc_datetime_usec)
    field(:idempotency_key, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
