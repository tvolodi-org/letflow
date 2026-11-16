defmodule Letflow.Attachments.Link do
  @moduledoc """
  One attachment of an owner (T-2040): owner kind + id, purpose, position, main flag, caption and the
  blob (and optional thumbnail blob) it points at. No bytes here.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attachment_links" do
    field(:tenant_id, :binary_id)
    field(:owner_kind, :string)
    field(:owner_id, :binary_id)
    field(:purpose, :string)
    field(:position, :integer)
    field(:is_main, :boolean, default: false)
    field(:caption, :string)
    field(:blob_id, :binary_id)
    field(:thumb_blob_id, :binary_id)
    field(:uploaded_by, :binary_id)
    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
    field(:locked_at, :utc_datetime_usec)
    field(:retain_until, :utc_datetime_usec)
  end
end
