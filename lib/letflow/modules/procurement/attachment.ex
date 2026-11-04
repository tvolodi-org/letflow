defmodule Letflow.Modules.Procurement.Attachment do
  @moduledoc """
  Persistence shape of a `procurement_attachments` row (GH #3503, REQ-626 part A): the link from one
  version of a purchase request to one stored file (`repository_artifacts`, by content hash).

  Insert-only: `Letflow.Modules.Procurement.Attachments` is the only writer and has no update or
  delete; a database trigger refuses both. A replacement is a new row with `replaces_id` set. There
  is no `tenant_id` column; the schema prefix is the tenant (0006 D2).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "procurement_attachments" do
    field(:document_id, :binary_id)
    field(:version_no, :integer)
    field(:slot_id, :binary_id)
    field(:content_hash, :binary)
    field(:file_name, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:uploaded_by, :binary_id)
    field(:uploaded_at, :utc_datetime_usec)
    field(:replaces_id, :binary_id)
  end

  @fields ~w(id document_id version_no slot_id content_hash file_name content_type byte_size
             uploaded_by uploaded_at replaces_id)a

  @doc "Insert changeset: the two partial unique indexes become `:slot_conflict` errors."
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required(List.delete(@fields, :replaces_id))
    |> unique_constraint(:slot_id, name: :procurement_attachments_root_idx)
    |> unique_constraint(:replaces_id, name: :procurement_attachments_replaces_idx)
  end
end
