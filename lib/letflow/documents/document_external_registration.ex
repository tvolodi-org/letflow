defmodule Letflow.Documents.DocumentExternalRegistration do
  @moduledoc """
  Persistence shape of a `document_external_registrations` row (REQ-500, GH #2588).

  Append-only: the database refuses UPDATE, DELETE and TRUNCATE. Slice 1 creates the
  table and writes nothing to it; the registration flow comes in a later slice.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "document_external_registrations" do
    field(:tenant_id, :binary_id)
    field(:document_id, :binary_id)
    field(:version_id, :binary_id)
    field(:system, :string)
    field(:external_ref, :string)
    field(:registered_at, :utc_datetime_usec)
  end
end
