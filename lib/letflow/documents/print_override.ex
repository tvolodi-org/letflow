defmodule Letflow.Documents.PrintOverride do
  @moduledoc """
  Persistence shape of a tenant's `document_print_overrides` row (REQ-579, GH #3289,
  decision 0068 D8 S2).

  This module is a shape, not an API. The only writer is `Letflow.Documents.PrintOverrides`;
  the database trigger `guard_document_print_overrides` refuses every other change. Callers
  pass `prefix:` for the tenant schema.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "document_print_overrides" do
    field(:tenant_id, :binary_id)
    field(:type_key, :string)
    field(:locale, :string)
    field(:version_no, :integer)
    field(:status, :string)
    field(:layout, :map)
    field(:layout_hash, :string)
    field(:layout_schema_version, :integer)
    field(:created_by, :binary_id)
    field(:activated_by, :binary_id)
    field(:activated_at, :utc_datetime_usec)
    field(:retired_at, :utc_datetime_usec)
    field(:reason_code, :string)
    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc "Every column except `:layout` (what `PrintOverrides.list/2` returns)."
  def metadata_fields, do: __schema__(:fields) -- [:layout]
end
