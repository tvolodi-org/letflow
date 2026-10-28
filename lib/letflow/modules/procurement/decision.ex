defmodule Letflow.Modules.Procurement.Decision do
  @moduledoc """
  Persistence shape of a `procurement_decisions` row (GH #3162, REQ-544 part 2): one accepted
  decision (`approve`, `reject` or `return`) on one exact version of a purchase request.

  Insert-only: `Letflow.Modules.Procurement.Decisions` is the only writer and has no update or
  delete. There is no `tenant_id` column; the schema prefix is the tenant (0006 D2).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "procurement_decisions" do
    field(:document_id, :binary_id)
    field(:version_no, :integer)
    field(:content_hash, :string)
    field(:decision, Ecto.Enum, values: [:approve, :reject, :return])
    field(:performer, :binary_id)
    field(:decided_at, :utc_datetime_usec)
    field(:idempotency_key, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
