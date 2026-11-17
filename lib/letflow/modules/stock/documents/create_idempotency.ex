defmodule Letflow.Modules.Stock.Documents.CreateIdempotency do
  @moduledoc """
  The per-tenant idempotency record for `POST /modules/stock/documents` (REQ-846).

  One row per namespaced client key: `key` (the stored form, e.g.
  `"client:stock_create:<actor_id>:<raw>"`), `document_id` (the document that
  request created), and `body_hash` (SHA-256 hex of the canonical body). The
  row is created inside the same transaction that creates the document and is
  never updated or deleted: a replay either matches the hash and replays the
  original result, or mismatches and answers 409 `idempotency_key_reuse`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # No auto-generated PK: `key` is the primary key, supplied by the caller.
  @primary_key {:key, :string, autogenerate: false}
  schema "stock_create_idempotency" do
    field(:document_id, Ecto.UUID)
    field(:body_hash, :string)
  end

  @doc "Changeset used only for `Repo.insert!/2`; all three fields are required."
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:key, :document_id, :body_hash])
    |> validate_required([:key, :document_id, :body_hash])
    |> validate_length(:key, max: 256)
    |> validate_length(:body_hash, is: 64)
  end
end
