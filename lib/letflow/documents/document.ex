defmodule Letflow.Documents.Document do
  @moduledoc """
  Persistence shape of a tenant's `documents` row (REQ-500, GH #2588, decision 0056).

  One row per document. `number` and `period` stay NULL until the first issue and are
  write-once after it; `current_version` names the version a reader sees. The writer is
  the `Letflow.Documents` context (PR B), not this module.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "documents" do
    field(:tenant_id, :binary_id)
    field(:type_key, :string)
    field(:legal_entity_id, :binary_id)
    field(:issuing_org_unit_id, :binary_id)
    field(:period, :string)
    field(:number, :integer)
    field(:source_ref, :map)
    field(:current_version, :binary_id)
    field(:on_hold, :boolean, default: false)
    field(:hold_set_at, :utc_datetime_usec)
    field(:hold_set_by, :binary_id)
    field(:hold_reason_code, :string)
    field(:hold_reason_note, :string)
    field(:hold_cleared_at, :utc_datetime_usec)
    field(:hold_cleared_by, :binary_id)
    field(:hold_clear_reason_code, :string)
    field(:hold_clear_reason_note, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
