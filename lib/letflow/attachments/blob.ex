defmodule Letflow.Attachments.Blob do
  @moduledoc """
  One stored, deduplicated byte string of the attachment service (T-2040): one row per sha256 within
  a tenant schema. Deletable (unlike the event store), which is why this table exists. Never select
  `bytes` in a list query; the service reads it only in `content/4`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attachment_blobs" do
    field(:tenant_id, :binary_id)
    field(:sha256, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:width, :integer)
    field(:height, :integer)
    field(:bytes, :binary)
    field(:inserted_at, :utc_datetime_usec)
  end
end
