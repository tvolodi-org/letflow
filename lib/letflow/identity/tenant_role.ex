defmodule Letflow.Identity.TenantRole do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Ecto schema for the `tenant_role` table. Shaped to match R-Co
  `src/identity/role_registry.zig`'s `TenantRoleStore` (`list_roles`,
  `upsert_role`), which REQ-020 implements against this schema.

  `group_id` carries a database-level foreign key to `groups.id` — unlike
  `Letflow.Identity.User.tenant_id`/`Letflow.Identity.Group.tenant_id`'s
  deliberate omission of a `tenants.id` FK elsewhere in this batch.
  `tenant_role` and `groups` are both per-tenant-owned tables that will
  live in the same tenant schema together once schema-per-tenant
  provisioning lands, so this FK stays valid across that future change and
  never needs to be dropped (see the `CreateTenantRole` migration's header
  comment for the full reasoning).

  `name` uniqueness is enforced today as a plain global unique index,
  standing in for "unique per tenant schema" under the single-default-schema
  deferral (see `lib/letflow/design/identity-schema.md` section 1).

  `changeset/2` (below) is owned by REQ-020 (`Letflow.Identity.RoleRegistry`) — it is a
  thin, defensive structural layer only (`cast`/`validate_required`/`unique_constraint`/
  `foreign_key_constraint`). The detailed name-format rule (codepoint-count,
  control-character exclusion) and the `group_id` UUID-format/existence checks are
  enforced by `RoleRegistry.upsert_role/2` itself, before this changeset is ever built —
  see `lib/letflow/design/req020-role-registry.md` §3.2.

  ## `kind` (ISS-0774)

  `kind` splits this table's single, previously-implicit domain
  (platform-permission role vs. process-routing role name — see
  `lib/letflow/design/iss-0774-role-domain-authorization.md` §0/§1) into an
  explicit, DB-level column, cast through `Ecto.Enum` — matching this
  codebase's established `Ecto.Enum`-over-a-string-column convention
  (`Letflow.Identity.User.status`/`auth_source`, `Letflow.Identity.Tenant.status`),
  not a Postgres-native enum type. `Ecto.Enum` rejects any value outside the
  two-member set at the changeset layer (same as `User.status`'s existing
  precedent); the additional "a `:platform_role`-kind row's `name` must be one
  of the eight recognized literals" rule is enforced by
  `RoleRegistry.upsert_role/4` itself, before this changeset is ever built —
  not duplicated here, matching this module's existing division of labor with
  `RoleRegistry`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type kind :: :platform_role | :process_routing_role

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenant_role" do
    field(:name, :string)
    field(:group_id, Ecto.UUID)
    field(:kind, Ecto.Enum, values: [:platform_role, :process_routing_role])

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{kind: kind()}

  @doc """
  Defensive structural changeset for insert/upsert. Casts and requires `name`/
  `group_id`/`kind`, and declares `unique_constraint(:name)` /
  `foreign_key_constraint(:group_id)` as typed fallbacks for the DB-level constraints
  REQ-015's migration already enforces (`unique_index(:tenant_role, [:name])`,
  `references(:groups, ...)`) — not a re-implementation of `RoleRegistry.upsert_role/4`'s
  own pre-DB-round-trip name-format/UUID-format/kind validation.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tenant_role, attrs) do
    tenant_role
    |> cast(attrs, [:name, :group_id, :kind])
    |> validate_required([:name, :group_id, :kind])
    |> unique_constraint(:name)
    |> foreign_key_constraint(:group_id)
  end
end
