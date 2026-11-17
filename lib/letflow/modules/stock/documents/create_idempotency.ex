defmodule Letflow.Modules.Stock.Documents.CreateIdempotency do
  @moduledoc """
  The per-tenant idempotency record for the stock document routes: `POST /modules/stock/documents`
  (REQ-846) and `POST /modules/stock/documents/:id/issue` and `/post` (REQ-847).

  One row per namespaced client key: `key` (the stored form, e.g.
  `"client:stock_create:<actor_id>:<raw>"`, family `stock_issue` or `stock_post` for the actions),
  `document_id` (the document that request created, or acted on), and `body_hash` (SHA-256 hex of
  the canonical body; for an action row the hash of the document id). A create row is written inside
  the same transaction that creates the document; an issue or post row is written by
  `ActionIdempotency` after the action succeeded, outside its transactions, under a per-key advisory
  lock. A row is never updated or deleted: a replay either matches and replays the original result,
  or mismatches and answers 409 `idempotency_key_reuse`.
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
