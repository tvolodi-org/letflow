defmodule Letflow.Identity.RoleScopeGrant do
  @moduledoc """
  `Ecto.Schema` for one `role_scope_grants` row (REQ-497 / GH #2533 PR 1a, decision 0051 D1;
  design `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` section
  2.1).

  A row says a principal (a group or a user, polymorphic, so no association) holds `role`
  either tenant-wide (`tenant_wide: true`, `scope_node_id: nil`) or at one scope node
  (`tenant_wide: false`, `scope_node_id` set); the
  `role_scope_grants_tenant_wide_xor_node` CHECK forbids anything else. Per-tenant table, no
  `tenant_id` column (0006 D2).

  Only `Letflow.Identity.RoleScopeGrants` writes the table (the single-writer scan
  `mix letflow.check_role_scope_grants_writers` enforces it). Its 1a writers use
  `Repo.insert_all/3` for the idempotent tenant-wide insert; `changeset/2` builds the stage-2
  scoped row (REQ-517 `RoleScopeGrants.insert_scoped/5`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "role_scope_grants" do
    field(:principal_type, Ecto.Enum, values: [:user, :group])
    field(:principal_id, :binary_id)
    field(:role, :string)
    field(:scope_node_id, :string)
    field(:tenant_wide, :boolean)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          principal_type: :user | :group | nil,
          principal_id: Ecto.UUID.t() | nil,
          role: String.t() | nil,
          scope_node_id: String.t() | nil,
          tenant_wide: boolean() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Casts the five data fields, requires all but `scope_node_id`, restricts `role` to
  `Letflow.Api.Authorization.roles/0`, and maps the table's CHECK and partial unique index
  names to changeset errors. The `scope_node_id` foreign key (REQ-517 migration
  `20261018100001`) maps to a changeset error.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:principal_type, :principal_id, :role, :scope_node_id, :tenant_wide])
    |> validate_required([:principal_type, :principal_id, :role, :tenant_wide])
    |> validate_inclusion(
      :role,
      Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
    )
    |> check_constraint(:scope_node_id, name: :role_scope_grants_tenant_wide_xor_node)
    |> check_constraint(:principal_type, name: :role_scope_grants_principal_type_check)
    |> foreign_key_constraint(:scope_node_id, name: :role_scope_grants_scope_node_id_fkey)
    |> unique_constraint([:principal_type, :principal_id, :role],
      name: :role_scope_grants_tenant_wide_uniq
    )
    |> unique_constraint([:principal_type, :principal_id, :role, :scope_node_id],
      name: :role_scope_grants_scoped_uniq
    )
  end
end
