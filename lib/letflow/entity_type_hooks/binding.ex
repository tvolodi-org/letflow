defmodule Letflow.EntityTypeHooks.Binding do
  @moduledoc """
  REQ-567 slice E-1 part 1 (GH #3217) -- one pin of a published `entity_write` script version to an
  entity type (`entity_type_hook_bindings`, a per-tenant table; the schema prefix is passed on every
  `Repo` call, never set here). At most one binding per entity type (unique index).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "entity_type_hook_bindings" do
    field(:tenant_id, :binary_id)
    field(:entity_type, :string)
    field(:script_key, :string)
    field(:script_version, :integer)
    field(:script_sha256, :string)
    field(:bound_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end
end
