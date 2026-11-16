defmodule Letflow.Attachments.BlobStore.Postgres do
  @moduledoc """
  The one `Letflow.Attachments.BlobStore` adapter: rows of `attachment_blobs` in the tenant schema.

  `put/3` upserts on the sha256 and, on conflict, takes the existing row's lock (`DO UPDATE SET
  sha256 = EXCLUDED.sha256`), which serialises an add against a concurrent `release/2` of the same
  blob. `release/2` deletes the blob only when no link points at it (`ON DELETE RESTRICT` is the
  backstop).
  """
  @behaviour Letflow.Attachments.BlobStore

  import Ecto.Query

  alias Letflow.Attachments.{Blob, Link}
  alias Letflow.Repo

  @impl true
  def put(prefix, tenant_id, %{sha256: sha} = blob) do
    row = %Blob{
      tenant_id: tenant_id,
      sha256: sha,
      content_type: blob.content_type,
      byte_size: blob.byte_size,
      width: blob.width,
      height: blob.height,
      bytes: blob.bytes,
      inserted_at: DateTime.utc_now()
    }

    %Blob{id: id} =
      Repo.insert!(row,
        prefix: prefix,
        on_conflict: {:replace, [:sha256]},
        conflict_target: :sha256,
        returning: [:id]
      )

    {:ok, id}
  end

  @impl true
  def fetch(prefix, blob_id) do
    case Repo.one(from(b in Blob, where: b.id == ^blob_id, select: b.bytes), prefix: prefix) do
      nil -> :error
      bytes -> {:ok, bytes}
    end
  end

  @impl true
  def release(prefix, blob_id) do
    locked = from(b in Blob, where: b.id == ^blob_id, select: b.id, lock: "FOR UPDATE")

    case Repo.one(locked, prefix: prefix) do
      nil ->
        :kept

      id ->
        refs =
          Repo.aggregate(
            from(l in Link, where: l.blob_id == ^id or l.thumb_blob_id == ^id),
            :count,
            prefix: prefix
          )

        if refs == 0 do
          Repo.delete_all(from(b in Blob, where: b.id == ^id), prefix: prefix)
          :deleted
        else
          :kept
        end
    end
  end
end
