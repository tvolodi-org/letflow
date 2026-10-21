defmodule Letflow.Documents.DocumentVersion do
  @moduledoc """
  Persistence shape of a `document_versions` row (REQ-500, GH #2588, decision 0056).

  A version moves through `draft`, `issued`, `superseded`, `cancelled` or `discarded`.
  Which columns may change on which transition is decided by the database
  (`guard_document_versions`); this shape does not repeat those rules. The writer is
  the `Letflow.Documents` context (PR B).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "document_versions" do
    field(:tenant_id, :binary_id)
    field(:document_id, :binary_id)
    field(:version_no, :integer)
    field(:status, Ecto.Enum, values: [:draft, :issued, :superseded, :cancelled, :discarded])
    field(:content, :map)
    field(:content_hash, :string)
    field(:issued_at, :utc_datetime_usec)
    field(:issued_by, :binary_id)
    field(:superseded_by_version, :binary_id)
    field(:cancelled_at, :utc_datetime_usec)
    field(:cancelled_by, :binary_id)
    field(:cancel_reason, :string)
    field(:discarded_at, :utc_datetime_usec)
    field(:discarded_by, :binary_id)
    field(:artefact_hash, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
