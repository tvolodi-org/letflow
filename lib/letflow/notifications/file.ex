defmodule Letflow.Notifications.File do
  @moduledoc """
  One file of the tenant-scoped NOTIFICATION FILE AREA (T-2596, pilot gap G12):
  the bytes a notification step's "file" channel rendered, the template it came
  from, the server-generated name it is stored under and the instance that
  produced it.

  The row lives in the tenant's own schema, so the tenant it belongs to comes
  from the schema it is read from (INV-1 (c)) -- `tenant_id` is kept in the row
  as well, because every other tenant-scoped table of the platform keeps it.

  The BYTES are here, not in a file system: the area is a database table, so a
  notification file cannot become a path on the server (the spike's section 2.h:
  "Never an arbitrary server path" then holds by construction). Never select
  `bytes` in a list query -- `Letflow.Notifications.Files` reads it only in
  `fetch/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "notification_files" do
    field(:tenant_id, :binary_id)
    field(:name, :string)
    field(:template_key, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:sha256, :string)
    field(:bytes, :binary)
    field(:trigger_ref, :binary_id)
    field(:inserted_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(file \\ %__MODULE__{}, attrs) do
    file
    |> cast(attrs, [
      :tenant_id,
      :name,
      :template_key,
      :content_type,
      :byte_size,
      :sha256,
      :bytes,
      :trigger_ref,
      :inserted_at,
      :expires_at
    ])
    |> validate_required([
      :tenant_id,
      :name,
      :template_key,
      :content_type,
      :byte_size,
      :sha256,
      :bytes,
      :inserted_at
    ])
    |> check_constraint(:byte_size, name: :notification_files_byte_size_chk)
  end
end
