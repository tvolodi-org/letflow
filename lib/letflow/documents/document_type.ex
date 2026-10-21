defmodule Letflow.Documents.DocumentType do
  @moduledoc """
  Persistence shape of a tenant's `document_types` row (REQ-500, GH #2588, decision 0056).

  This module is a shape, not an API. The only writer of document rows is the
  `Letflow.Documents` context (PR B). Callers pass `prefix:` for the tenant schema.
  A type is frozen by the database once a document of its key exists (see the
  `document_types_guard_*` triggers in the immutability migration).
  """

  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}

  schema "document_types" do
    field(:tenant_id, :binary_id)
    field(:owner_module, :string)
    field(:numbering_scope, Ecto.Enum, values: [:year, :none])
    field(:number_prefix, :string)
    field(:number_pad, :integer)
    field(:legal_entity_required, :boolean)
    field(:restricted_fields_allowed, :boolean, default: false)
    field(:declared_fields, :map)
    field(:template_ref, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
