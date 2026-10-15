defmodule Letflow.Definitions.ProcessDefinition do
  @moduledoc """
  Ecto schema for the `process_definitions` table. See
  `lib/letflow/design/req027-definition-core-schema.md` §3.1 and §5.1.

  ## Ported source (REQ-027 acceptance criterion 5)

  Ported from R-Co's `src/design/definition.md` — the PD-01 sections (module
  purpose, `Store.create`, the `Definition` ↔ `process_definitions` database
  mapping, and the `uq_definition_version` / `uq_active_definition` unique
  constraints table) and the PD-07 section (the nullable free-text `stage`
  column and its `idx_def_stage` partial index, whose SQL is R-Co's
  `migrations/014_definition_stage.sql`). The same document's PD-08 section is
  the ported source for `instance_definition_snapshots`, the table that
  references this one — see `Letflow.Definitions.InstanceDefinitionSnapshot`,
  whose foreign key onto `process_definitions.id` deliberately carries no
  `ON DELETE CASCADE`. The table DDL this schema reads is ported from R-Co's
  `migrations/004_definitions.sql`.

  ## Scope — this requirement builds schema only

  This requirement (REQ-027) builds schema only. Graph/node/edge structural
  validation is REQ-028 (`Letflow.Definitions.Graph`, already merged) and
  REQ-029; CRUD operations — `create/1`, `get_by_id/1`, `get_active_by_name/1`,
  `list/1`, `activate/1`, `deprecate/1`, `archive/1` — are REQ-030; the
  snapshot create/retrieve functions are REQ-033. Those are separate
  requirements building on this table. Do not read this module as the
  definition store landing early.

  ## `status` is stored lowercase, and that is load-bearing (design INV-DEF-3)

  `status` is an `Ecto.Enum` over the lowercase atoms `:draft`, `:active`,
  `:deprecated` and `:archived`, stored as the lowercase strings `"draft"`,
  `"active"`, `"deprecated"` and `"archived"`. This deliberately diverges from
  R-Co, which stores the uppercase `DRAFT`/`ACTIVE`/`DEPRECATED`/`ARCHIVED`
  (`migrations/004_definitions.sql`). The stored string is load-bearing: the
  `uq_active_definition` partial unique index carries PD-03's
  single-active-per-name invariant through the predicate
  `WHERE status = 'active'`, and if the enum's dumped value and that predicate
  ever disagree the index silently matches no rows and the invariant is
  unenforced with no error anywhere. Changing either one without the other is a
  defect.

  The bare atom-list `Ecto.Enum` form below is what produces the lowercase
  dump: `Ecto.Enum.init/1` maps a plain list of atoms through
  `to_string(atom)` (`deps/ecto/lib/ecto/enum.ex:81-83`). This is the one place
  REQ-027 knowingly departs from its sibling REQ-023's convention, where
  `Letflow.EventStore.InstanceProjection` preserves R-Co's uppercase via the
  keyword-mapping form. Self-consistency between dump and predicate is the
  property that matters, not the case itself.

  ## `status` is never castable from caller input (design INV-DEF-8)

  Neither changeset below casts `:status`. The column's `draft` default is the
  only way a row acquires an initial status — PD-01 hard-codes DRAFT and "the
  `params` struct carries no `status` field" (`definition.md:472`). Every
  subsequent transition is a guarded single-statement UPDATE
  (`... WHERE id = $1 AND status = '<expected>'`), never a changeset-mediated
  read-modify-write: that `WHERE` clause *is* the concurrency control, and a
  load-then-update would reintroduce the lost-update race it exists to prevent.
  REQ-030 owns PD-04's authoritative transition table (only `draft → active`,
  `active → deprecated` and `deprecated → archived` are permitted).

  ## `stage` is open-ended free text (design INV-DEF-4)

  Per PD-07, `stage` is a nullable free-text label with **no** enum, no
  allowed-value list and no check constraint — "no enum validation is applied
  (stage labels are open-ended text per PD-07)" (`definition.md:1486-1487`).
  Only nullability and a length bound are enforced. The column is nullable "so
  that existing rows are unaffected (no back-fill required)"
  (`definition.md:1467-1468`), and `idx_def_stage`'s `WHERE stage IS NOT NULL`
  predicate depends on an omitted stage landing as `NULL`.

  ## No `@schema_prefix` (design INV-DEF-7)

  This table lives in many Postgres schemas — one per tenant — so every read
  and write must pass `prefix: schema_name` explicitly at call time rather than
  relying on a compile-time prefix. `schema_name` comes from a
  `Letflow.TenantProvisioning.Registration` row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "process_definitions" do
    field(:name, :string)
    field(:version, :string)
    field(:description, :string)

    field(:status, Ecto.Enum,
      values: [:draft, :active, :deprecated, :archived],
      default: :draft
    )

    field(:stage, :string)
    field(:graph, :map, default: %{"nodes" => [], "edges" => []})
    field(:created_by, Ecto.UUID)
    field(:archived_at, :utc_datetime_usec)

    # REQ-125 (MOB-3 delta sync) -- server-assigned watermark for
    # `GET /definitions/delta`'s `since`/`next_since` cursor. Never castable
    # from caller input (mirrors :status's own INV-DEF-8 protection, above) --
    # stamped only via Ecto.Changeset.put_change/3 in
    # Letflow.Definitions.insert_definition/3, or via a raw Repo.update_all/3
    # `set:` list in activate_draft/3 and run_transition/5. See
    # lib/letflow/design/req125-definitions-delta-sync.md §5.1.
    field(:sequence_number, :integer, default: 0)

    # GH #2587 / REQ-499 PR B1 (decision 0054 D4a, design D-B.24, invariant I-B11): the
    # activator authority recorded when a graph with `entity_writes` is activated (user id,
    # roles, evaluated permissions, authorised (entity_type, op) pairs); NULL otherwise.
    # Never castable from caller input: neither changeset below lists it, and the only
    # writer is the activation write of `Letflow.Definitions.activate/2`, version rollback
    # and promotion (a raw `Repo.update_all/3` `set:` list).
    field(:activated_by, :map)

    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :draft | :active | :deprecated | :archived

  @doc """
  Structural changeset for creating a process definition. Does no I/O.
  """
  @spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def create_changeset(definition, attrs) do
    definition
    |> cast(attrs, [:name, :version, :description, :stage, :graph, :created_by])
    |> validate_required([:name, :version, :graph, :created_by])
    |> validate_common()
  end

  @doc """
  Structural changeset for updating a process definition's mutable fields.
  Does no I/O.

  PROVENANCE (historical, not current decision authority):
  The castable field list intentionally excludes `:status`, `:tenant_id` and
  `:created_by` (`src/definition/store.zig:101-108` for the equivalent field
  list). Status movement is a guarded UPDATE, not a changeset (see this
  module's moduledoc), and tenant/creator identity is set once at creation,
  never through a caller-supplied update.
  """
  @spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def update_changeset(definition, attrs) do
    definition
    |> cast(attrs, [:name, :version, :description, :stage, :graph])
    |> validate_required([:name, :version, :graph])
    |> validate_common()
  end

  # The length bounds and the two unique-constraint declarations are identical on
  # both changesets. The constraint declarations are what turn a 23505 into
  # {:error, changeset} at Repo.insert/2 rather than a raised Ecto.ConstraintError —
  # that distinction is the error contract REQ-030 depends on. Both are matched by
  # INDEX name, because Ecto emits CREATE UNIQUE INDEX rather than
  # ALTER TABLE ... ADD CONSTRAINT.
  defp validate_common(changeset) do
    changeset
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:version, min: 1, max: 255)
    |> validate_length(:stage, max: 255)
    |> unique_constraint([:name, :version], name: :uq_definition_version)
    |> unique_constraint(:name, name: :uq_active_definition)
  end
end
