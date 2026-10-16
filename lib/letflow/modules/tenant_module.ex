defmodule Letflow.Modules.TenantModule do
  @moduledoc """
  Ecto schema for the tenant-scoped `tenant_modules` table (REQ-402, design
  `lib/letflow/design/req402-tenant-modules-install-context.md` §2). One row
  per platform module installed into a tenant's own schema
  (`Letflow.Modules.Installs.install/3`).

  ## File placement (D3)

  `lib/letflow/modules/tenant_module.ex`, one level, no subdirectory — core
  mechanism file, named explicitly in
  `docs/migration/decisions/0039-platform-module-solution-layering.md` D3.

  ## Tenant scoping (INV-1)

  This table lives in the tenant's own schema (created by the migration's
  `if prefix() do` guard, §1) — there is no `tenant_id` column, and no
  association: the schema itself is the tenant boundary. Every read/write
  against this schema must pass `prefix: prefix` explicitly
  (`Letflow.Modules.Installs` is the only caller in this requirement's
  scope).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenant_modules" do
    field(:module_id, :string)
    field(:version, :string)
    field(:installed_at, :utc_datetime_usec)
    field(:settings, :map, default: %{})
    # GH #2590 / REQ-501 R2: `Letflow.Modules.Catalog.manifest_hash/1` recorded at install.
    # NULL for a module installed before the column existed (OQ-R7: no backfill, no
    # reconstruction). Cast only by `insert_changeset/2`, never by `settings_changeset/2`.
    field(:manifest_hash, :string)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          module_id: String.t(),
          version: String.t(),
          installed_at: DateTime.t(),
          settings: map(),
          manifest_hash: String.t() | nil
        }

  @doc """
  Structural changeset for inserting a newly-installed module's row. Does no
  I/O. `unique_constraint/2` is the DB-level backstop behind
  `Letflow.Modules.Installs.install/3`'s own already-installed pre-check —
  same "check-then-insert plus a DB unique constraint as the race backstop"
  shape `Letflow.Definitions.SolutionPackInstall` already uses.
  """
  @spec insert_changeset(%__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(tenant_module, attrs) do
    tenant_module
    |> cast(attrs, [:module_id, :version, :installed_at, :settings, :manifest_hash])
    |> validate_required([:module_id, :version, :installed_at])
    |> unique_constraint(:module_id, name: :tenant_modules_module_id_idx)
  end

  @doc """
  Changeset for updating the `settings` field on an already-installed row
  (REQ-414). Casts and requires `:settings` only — `:module_id`, `:version`,
  and `:installed_at` are immutable after insert and are not touched here.
  """
  @spec settings_changeset(%__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def settings_changeset(tenant_module, attrs) do
    tenant_module
    |> cast(attrs, [:settings])
    |> validate_required([:settings])
  end
end
