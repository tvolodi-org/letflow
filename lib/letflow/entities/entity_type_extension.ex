defmodule Letflow.Entities.EntityTypeExtension do
  @moduledoc """
  One `x_` addition a tenant made to a module entity type (REQ-576 / GH #3258, decision
  0067-tenant-x D2, slice I1: storage only).

  Per-tenant placement: the row lives in the tenant schema table `entity_type_extensions`, chosen
  only through the `:prefix` option of the Repo call (no `@schema_prefix`), with `tenant_id` kept
  in the row as well (INV-1). The database enforces the shape (`x_` name, `field` kind, object
  spec, `active`/`retired` status, unique `(tenant_id, entity_type, name)`).

  Deliberately no changeset and no Repo call here: nothing writes or reads this table yet. The
  write path, validation and caps arrive with the following slices.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "entity_type_extensions" do
    field(:tenant_id, :binary_id)
    field(:entity_type, :string)
    field(:kind, :string)
    field(:name, :string)
    field(:spec, :map)
    field(:position, :integer)
    field(:status, :string)

    timestamps(type: :utc_datetime_usec)
  end
end
