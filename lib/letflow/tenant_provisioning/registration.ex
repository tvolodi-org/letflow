defmodule Letflow.TenantProvisioning.Registration do
  @moduledoc """
  Ecto schema for the `tenant_schemas` table — a registration record mapping a
  tenant to its provisioned physical Postgres schema. See
  `lib/letflow/design/req022-tenant-schema-provisioning.md` section 1 for why
  this struct is deliberately not named `TenantSchema` (that name would be
  ambiguous between the *Postgres schema* it maps to and the *Ecto schema*
  this module itself defines). Everywhere in this codebase, unqualified
  "schema" means the Postgres namespace; the struct defined here is always
  written as `Registration`.

  `migrations_applied_at` is `nil` until `Letflow.TenantProvisioning.replay_migrations/2`
  succeeds at least once for this tenant.

  GH #2727: `migration_replay_failed_at` / `migration_replay_failure_code` are
  both `nil` while the tenant's last `replay_all_pending/0` outcome was a
  success, and both set (time, fixed reason code) after a failure. They are not
  in `changeset/2`'s cast list; only `Letflow.TenantProvisioning` writes them.

  No `belongs_to :tenant` association is declared on `tenant_id`, matching
  this codebase's existing convention of a plain `field :tenant_id, Ecto.UUID`
  even where a DB-level foreign key exists (see
  `Letflow.Identity.TenantRole.group_id`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenant_schemas" do
    field(:tenant_id, Ecto.UUID)
    field(:schema_name, :string)
    field(:migrations_applied_at, :naive_datetime)
    field(:migration_replay_failed_at, :naive_datetime)
    field(:migration_replay_failure_code, :string)

    timestamps(inserted_at: :provisioned_at, updated_at: false)
  end

  @type t :: %__MODULE__{}

  # Mirrors Letflow.TenantProvisioning.schema_name_for_tenant/1's own derivation
  # (tenant_id -> "tenant_" <> 32 lowercase hex chars, no hyphens). Not called from
  # there -- this is the data-level half of the same guarantee, added per ISS-0027
  # (GH#85) so the DDL-identifier safety argument for
  # `CREATE SCHEMA IF NOT EXISTS "#{schema_name}"` is enforced by this changeset on
  # every write, not just by the call graph (today, schema_name_for_tenant/1 is the
  # only writer -- this is defence in depth against a future second writer, e.g. S3's
  # instance engine or S4's API surface, ever bypassing that derivation).
  @schema_name_format ~r/^tenant_[0-9a-f]{32}\z/

  @doc """
  Defensive structural changeset for insert/upsert. Casts and requires
  `tenant_id`/`schema_name`, validates `schema_name` against the exact shape
  `Letflow.TenantProvisioning.schema_name_for_tenant/1` produces (ISS-0027/GH#85),
  and declares `unique_constraint/2` for both `tenant_id`/`schema_name` (typed
  fallbacks for `tenant_schemas`'s two DB-level unique indexes) plus
  `foreign_key_constraint(:tenant_id)` (typed fallback for the DB-level FK to
  `tenants.id`).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(registration, attrs) do
    registration
    |> cast(attrs, [:tenant_id, :schema_name, :migrations_applied_at])
    |> validate_required([:tenant_id, :schema_name])
    |> validate_format(:schema_name, @schema_name_format)
    |> unique_constraint(:tenant_id)
    |> unique_constraint(:schema_name)
    |> foreign_key_constraint(:tenant_id)
  end
end
