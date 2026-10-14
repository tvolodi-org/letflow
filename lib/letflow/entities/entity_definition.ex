defmodule Letflow.Entities.EntityDefinition do
  @moduledoc """
  `Ecto.Schema` for the persisted `entity_definitions` table (REQ-226). See
  `lib/letflow/design/req226-entity-definitions-persistence-crud.md` §1
  (migration schema) and §3.2 (this schema's field list) for the full design
  this module implements.

  This is the **persisted-row** half of the document/persistence split named
  in the design's §3.1: `Letflow.Entities.Definition` (REQ-225) is a plain
  document `@type` describing the shape of the JSON blob stored in this
  schema's `definition_json` column; this module is the `Ecto.Schema` for
  the denormalised row referencing that blob's `Letflow.Repository`-owned
  `artifact_version_id`. `Letflow.Entities.Definitions` (plural, the CRUD
  context module) is the third, distinct member of this family -- see that
  module's moduledoc.

  `status` is a local read-convenience denormalisation of REQ-203's
  `artifact_activations` pointer, kept in sync by
  `Letflow.Entities.Definitions.activate_definition/4`; a reader needing an
  authoritative "is this currently active" answer still calls
  `Letflow.Repository.Activation.resolve/3` directly (design §1.2), or the
  `entity_definitions`-aware
  `Letflow.Entities.Definitions.get_active_definition_by_name/2`.

  As of ISS-0519's fix (C), "kept in sync" is actually enforced, not merely
  intended: `activate_definition/4` demotes every sibling row under the same
  `(tenant_id, name)` to `:inactive` before promoting the target row, and the
  partial unique index `entity_definitions_tenant_name_active_idx`
  (`(tenant_id, name) WHERE status = 'active'`) makes "at most one `:active`
  row per name" a real, DB-enforced invariant rather than an
  application-level hope. See
  `lib/letflow/design/iss0519-entity-definition-versioning-fix.md`.

  No `updated_at` column (`timestamps(updated_at: false)`) -- this table has
  no update path in REQ-226's own scope beyond `status` (design §1.4).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "entity_definitions" do
    field(:tenant_id, :binary_id)
    field(:name, :string)
    field(:display_name, :string)
    field(:definition_json, :map)
    field(:content_hash, :binary)
    field(:logical_shape_version, :binary)
    field(:artifact_version_id, :binary_id)
    field(:status, Ecto.Enum, values: [:active, :inactive])
    # REQ-496 (0050 D7): the owning module id, or nil. Never cast; set only by
    # `put_managed_by/2` on a new row, and immutable in the DB (trigger).
    field(:managed_by, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required_fields [
    :tenant_id,
    :name,
    :display_name,
    :definition_json,
    :content_hash,
    :logical_shape_version,
    :artifact_version_id,
    :status
  ]

  # Must match the explicit `:name` given to `unique_index/3` in
  # priv/repo/migrations/20260906000001_create_entity_definitions.exs
  # exactly, same reasoning as `Letflow.Repository.ArtifactVersion.changeset/2`'s
  # own `@unique_version_number_constraint_name`.
  @unique_tenant_name_shape_constraint_name :entity_definitions_tenant_name_shape_idx

  # ISS-0519 fix (C), design §5.2: must match the explicit `:name` given to
  # the new partial `unique_index/3` in
  # priv/repo/migrations/<next-timestamp>_add_entity_definitions_active_partial_index.exs
  # exactly.
  @unique_tenant_name_active_constraint_name :entity_definitions_tenant_name_active_idx

  @doc """
  Structural insert/update changeset. `unique_constraint/3` translates the
  `(tenant_id, name, logical_shape_version)` UNIQUE violation
  (design §1.3/§5) into a changeset error on `:name`; a second
  `unique_constraint/3` (ISS-0519 fix (C)) translates the partial
  `(tenant_id, name) WHERE status = 'active'` UNIQUE violation into a
  changeset error on `:status`, so a bug reintroducing "2 simultaneously
  active rows per name" surfaces as a changeset error instead of a raw
  `Ecto.ConstraintError`; `foreign_key_constraint/3` translates a
  hypothetical `artifact_version_id` FK violation into a changeset error --
  matching `Letflow.Repository.Activation.changeset/2`'s own
  `foreign_key_constraint/3` idiom.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = entity_definition, attrs) do
    entity_definition
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name, name: @unique_tenant_name_shape_constraint_name)
    |> unique_constraint(:status, name: @unique_tenant_name_active_constraint_name)
    |> foreign_key_constraint(:artifact_version_id)
  end

  @doc """
  Stamps `managed_by` with `module_id` on a changeset for a NEW row (REQ-496,
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §2.2) -- the only
  code that can set the column; `changeset/2` never casts it. On a changeset over a
  row already loaded from the DB it adds an `"is immutable"` error on `:managed_by`
  instead (the DB trigger refuses such an update anyway).
  """
  @spec put_managed_by(Ecto.Changeset.t(), module_id :: String.t()) :: Ecto.Changeset.t()
  def put_managed_by(%Ecto.Changeset{data: data} = changeset, module_id)
      when is_binary(module_id) do
    case Ecto.get_meta(data, :state) do
      :built -> put_change(changeset, :managed_by, module_id)
      _loaded -> add_error(changeset, :managed_by, "is immutable")
    end
  end
end
