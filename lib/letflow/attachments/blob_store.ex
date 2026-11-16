defmodule Letflow.Attachments.BlobStore do
  @moduledoc """
  Seam between the attachment service and where bytes live (T-2040). Only the PostgreSQL adapter
  exists; an object-store adapter would implement the same callbacks. All callbacks run inside the
  caller's transaction.
  """

  @type blob :: %{
          sha256: String.t(),
          content_type: String.t(),
          byte_size: pos_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          bytes: binary()
        }

  @callback put(prefix :: String.t(), tenant_id :: Ecto.UUID.t(), blob()) :: {:ok, Ecto.UUID.t()}
  @callback fetch(prefix :: String.t(), blob_id :: Ecto.UUID.t()) :: {:ok, binary()} | :error
  @callback release(prefix :: String.t(), blob_id :: Ecto.UUID.t()) :: :deleted | :kept
end
