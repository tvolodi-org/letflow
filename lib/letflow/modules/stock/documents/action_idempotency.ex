defmodule Letflow.Modules.Stock.Documents.ActionIdempotency do
  @moduledoc """
  Client-key replay for the issue and post routes of a stock document (REQ-847).

  Both routes take no body, so "same request" is the document id in the path. The stored key
  (`client:stock_issue:<actor>:<K>` or `client:stock_post:<actor>:<K>`, see `Letflow.Idempotency`)
  is bound to the document id of the first SUCCESSFUL request in the tenant's
  `stock_create_idempotency` table (the table REQ-846 chose; its `body_hash` column holds the
  SHA-256 of the document id here, and keys of the three families never collide because the
  family token is part of the key). No expiry; documents and tenants deployed before this change
  have no rows and keep today's behaviour. A refused request binds nothing.

  `run/5` serialises requests with the same key on a session advisory lock held on one checked-out
  connection (the action itself runs several transactions of its own, so a transaction-scoped lock
  cannot span it): lookup, then either the replay (the document as it is now, nothing written),
  the refusal `{:error, :idempotency_key_reuse}` (the key is bound to another document that the
  caller can read; for a document the caller cannot read the refusal of its own fetch, the
  unknown-document answer, so the key reveals nothing), or the action followed by the binding. A replay starts no posting instance and posts nothing.
  """

  alias Letflow.Modules.Stock.Documents.CreateIdempotency
  alias Letflow.Repo

  @doc """
  Runs `action` (a zero-arity function returning `{:ok, view}` or `{:error, reason}`) once per
  `key` and document `id`; `replay` (zero-arity, same return shape) answers a repeat. A `nil` key
  or an id that is not a UUID runs `action` unchanged.
  """
  @spec run(String.t(), String.t() | nil, term(), (-> term()), (-> term())) :: term()
  def run(_prefix, nil, _id, _replay, action), do: action.()

  def run(prefix, "client:" <> _ = key, id, replay, action) when is_binary(prefix) do
    case Ecto.UUID.cast(id) do
      {:ok, doc_id} -> serialised(prefix, key, doc_id, replay, action)
      :error -> action.()
    end
  end

  def run(_prefix, _server_minted_key, _id, _replay, action), do: action.()

  defp serialised(prefix, key, doc_id, replay, action) do
    Repo.checkout(fn ->
      Repo.query!("SELECT pg_advisory_lock(hashtextextended($1, 0))", [lock_key(prefix, key)])

      try do
        case Repo.get(CreateIdempotency, key, prefix: prefix) do
          %CreateIdempotency{document_id: ^doc_id} -> replay.()
          %CreateIdempotency{} -> reuse(replay)
          nil -> bind(prefix, key, doc_id, action.())
        end
      after
        Repo.query!("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [lock_key(prefix, key)])
      end
    end)
  end

  # The key is bound to another document. The caller's own fetch of the REQUESTED document goes
  # first: an id that does not exist for the caller (unknown, or outside its scope, which
  # `Access.units_allowed?(:stored)` lets through when the document is missing) gets that fetch's
  # refusal (the unknown-document 404), so a bound key is no oracle for document ids (INV-5).
  defp reuse(replay) do
    case replay.() do
      {:ok, _view} -> {:error, :idempotency_key_reuse}
      {:error, _reason} = refusal -> refusal
    end
  end

  # 64-bit key (hashtextextended) namespaced by the tenant schema and a fixed tag, so two tenants
  # never share a lock for equal keys and the int4 advisory-key space of other paths is not used.
  defp lock_key(prefix, key), do: "stock_action_idempotency:" <> prefix <> ":" <> key

  defp bind(prefix, key, doc_id, {:ok, _view} = ok) do
    %CreateIdempotency{}
    |> CreateIdempotency.changeset(%{
      key: key,
      document_id: doc_id,
      body_hash: Base.encode16(:crypto.hash(:sha256, doc_id), case: :lower)
    })
    |> Repo.insert!(prefix: prefix)

    ok
  end

  defp bind(_prefix, _key, _doc_id, other), do: other
end
