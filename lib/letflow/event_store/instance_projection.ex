defmodule Letflow.EventStore.InstanceProjection do
  @moduledoc """
  Ecto schema for the `instance_projections` table. See
  `lib/letflow/design/req023-event-store-schema.md` §3.3 and §5.1.

  ## Scope (REQ-023 acceptance criterion 5)

  This table's *schema* is event-store scope — this requirement (REQ-023)
  owns it, because R-Co's `src/design/event_store.md` "DB tables / columns
  per operation" section shows `Store.append()` reading and writing
  `instance_projections` directly for the ES-01 active-instance guard and
  the DB-03 `last_event_seq` update.

  **REQ-043 update:** the seven engine-owned columns R-Co's
  `migrations/001_event_store.sql` also carries — `definition_id`,
  `correlation_key`, `current_nodes`, `variables`, `error_detail`,
  `completed_at`, `cancelled_at`, and the `uq_instance_correlation` /
  `idx_proj_definition` indexes that depend on them — have now been added
  (`priv/repo/migrations/20260818110001_alter_instance_projections_add_engine_columns.exs`)
  and are declared below, so the columns *exist* and are Ecto-accessible. Do
  not read this as the instance-engine's write logic landing early, though:
  *meaningful population at instance start* is still EE-01 / S3 territory
  (REQ-045+, `src/engine/`, not built yet) — this is a schema-only change,
  identical caution to REQ-023's own original scope note above.

  ## No FK on `definition_id` (design req043 §2.2, confirmed not assumed)

  `definition_id` carries **no** `references/2` constraint, even though
  `process_definitions` already exists in Letflow at this migration's point in
  the ordering. `001_event_store.sql:83` declares `definition_id UUID NOT
  NULL` with no `REFERENCES` clause — confirmed by direct read, matching R-Co
  exactly rather than "completing" an asymmetry R-Co itself left. A future
  reader should not assume a real FK exists from the field's name alone.

  ## `current_nodes`'s Ecto type (design req043 §2.4/OQ-3 — resolved empirically,
  not by design-time guess)

  `current_nodes` is a `jsonb` column holding a JSON **array** (`'[]'::jsonb`
  DB-level default, "active token positions"), unlike `variables`/
  `error_detail` which hold JSON **objects**. The design flagged as an open
  question (OQ-3) whether `Ecto.Changeset.cast/3` would accept a `list()` value
  for a `:map`-typed field, naming `put_change/3` as the fallback if not.
  Empirically, against real Postgres, the actual failure is more fundamental
  than OQ-3 anticipated and `put_change/3` alone does not fix it: Ecto's
  built-in `:map` type's `dump/1` (`same_map/1` in `deps/ecto/lib/ecto/type.ex`)
  unconditionally requires `is_map/1`, rejecting any list at *insert* time
  regardless of how it entered the changeset — and `field(:current_nodes, :map,
  default: [])` fails even earlier, at compile time
  (`Ecto.Schema.validate_default!/3`), before any changeset exists at all.
  `current_nodes` therefore uses `Letflow.EventStore.JSONArray` — a small
  custom `Ecto.Type` (see that module's own moduledoc for the full empirical
  finding) whose `type/0` still reports `:map` (identical jsonb wire encoding)
  but whose `cast/1`/`dump/1`/`load/1` accept a `list()`. This is a **deviation
  from the approved design's literal `field(:current_nodes, :map, default:
  [])` text**, made because that literal text does not compile/run against
  real Ecto — flagged explicitly for REVIEWER. `variables`/`error_detail` hold
  genuine JSON objects, hit none of this, and keep the plain built-in `:map`
  type (`variables` with a normal `default: %{}`).

  ## `unique_constraint(:correlation_key, name: :uq_instance_correlation)` —
  also not in the design's literal §2.3 changeset text, added for the same
  reason `Letflow.Definitions.ProcessDefinition`'s `validate_common/1` and
  `Letflow.EventStore.IdempotencyRecord`'s `insert_changeset/2` already declare
  their own unique indexes: without it, a real `uq_instance_correlation`
  collision raises `Ecto.ConstraintError` out of `Repo.insert/2` instead of
  returning this project's established `{:error, changeset}` shape — exactly
  the "bare crash on realistic tenant-controlled input" pattern
  `docs/agents/instructions/security-invariants.md` INV-8 flags, confirmed by
  a real duplicate-insert against Postgres while implementing this
  requirement. Flagged for REVIEWER alongside `JSONArray` above.

  ## Derived state (design INV-EV-9)

  Per `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision C point
  3, this is a projection table: rebuildable at any time from a fold over
  `events`. Its real correctness boundary — "matches a fold over the event
  log" — is a runtime/test concern that no column constraint can express, which
  is why it is migrated with the same DSL and constraint discipline as any
  ordinary CRUD table and why, unlike every other schema in
  `lib/letflow/event_store/`, it legitimately exposes an `update_changeset/2`.

  ## No `@schema_prefix` (design INV-EV-8)

  Like every event-store schema module, this table lives in many Postgres
  schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.

  ## `definition_id` is non-nullable at the Elixir level (GH#310 / ISS-0091)

  The column is `NOT NULL` (confirmed above) and `insert_changeset/2` requires
  the field, so no row this schema represents can have a nil `definition_id`
  after insert -- `update_changeset/2` doesn't even cast it (immutable, per
  that function's own doc). `@type t`, below, previously left every field
  implicitly `term()` (`@type t :: %__MODULE__{}`), which is what let
  `Letflow.Engine.VariableSchema.validate_definition_id/1`'s nil guard read as
  a real defence: a reader relying on the struct's type alone would see
  `Ecto.UUID.t() | nil` and reasonably write exactly that guard. It defends a
  state the schema forbids, not one that occurs -- fixed here by typing
  `definition_id` explicitly. The guard itself is deliberately left in place:
  `VariableSchema.fetch_schemas/3` and `variable_validations/5` are that
  module's public entry points, not sealed to this struct as their only
  possible caller. What changed downstream is that `Letflow.Engine.complete_task/3`'s
  own public `@spec` no longer advertises the resulting
  `{:variable_schema_lookup_failed, _}` tuple as one of its returns, since
  nothing on that call path can produce it.

  ## `join_counters` (ISS-0397)

  Added by `priv/repo/migrations/20260901030001_add_join_counters_to_instance_projections.exs`
  (see `lib/letflow/design/iss0397-join-counters-fix.md`) to make
  `Letflow.Engine.JoinCounter` state durable across separate
  `Letflow.Engine.complete_task/3`/`advance_after_timer_fired/3` calls,
  closing REQ-048 design doc's own MAJOR OQ-3 / INV-EE48-7 gap. Same `:map`
  (jsonb), `null: false`, `default: %{}` idiom as `variables` above — a JSON
  object keyed by `join_node_id` strings, serialised/deserialised via
  `Letflow.Engine.SnapshotWriter.serialize_join_counters/1` /
  `deserialize_join_counters/1`, never read/written directly as a raw map by
  callers outside `Letflow.Engine`.

  ## `variable_labels` (decision 0062, GH #2616)

  Added by `priv/repo/migrations/20261022200001_add_variable_labels_to_instance_projections.exs`:
  per-variable restriction labels, `%{"var" => ["entity_type.field_name"]}`, `:map` (jsonb),
  `null: false`, `default: %{}`. Written only through `Letflow.Engine.VariableMerge.merge/5`'s
  result; an absent key is unlabelled, and rows that predate the column read `%{}`.

  ## No `tenant_id` column (Decision 0006 D2)

  This table carried `tenant_id` until Decision 0006 D2
  (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`)
  dropped it from every event-store table — the per-tenant Postgres schema
  already identifies the owning tenant, and 0006 §R3 documents that this
  table's own original migration header already conceded the column carried
  at most one distinct value per schema. See `lib/letflow/design/req023-event-store-schema.md`
  §2.5 for the superseded asymmetry rationale (retained there for history,
  not as current guidance).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:instance_id, :binary_id, autogenerate: false}
  schema "instance_projections" do
    field(:status, Ecto.Enum,
      values: [active: "ACTIVE", completed: "COMPLETED", cancelled: "CANCELLED", error: "ERROR"],
      default: :active
    )

    field(:last_event_seq, :integer, default: 0)

    field(:definition_id, Ecto.UUID)
    field(:correlation_key, :string)
    field(:current_nodes, Letflow.EventStore.JSONArray, default: [])
    field(:variables, :map, default: %{})
    field(:join_counters, :map, default: %{})
    field(:variable_labels, :map, default: %{})
    field(:error_detail, :map)
    field(:completed_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)

    # REQ-062 (SPC-01 sub-process runtime half, design §6.1) -- the durable
    # child->parent link. Both nullable: `nil` for every top-level (non-child)
    # instance, which is every instance `Letflow.Engine.create/2` (REQ-045)
    # produces -- that entry point never sets either field (AC6). Only
    # `Letflow.Engine.SubProcess.append_start_multi/7` (REQ-062) ever inserts
    # a row with these populated, for a freshly-created sub-process child.
    field(:parent_instance_id, Ecto.UUID)
    field(:parent_token_id, Ecto.UUID)

    timestamps(inserted_at: :started_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{definition_id: Ecto.UUID.t()}
  @type status :: :active | :completed | :cancelled | :error

  @doc """
  Structural changeset for creating an instance's projection row. Does no I/O.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(projection, attrs) do
    projection
    |> cast(attrs, [
      :instance_id,
      :status,
      :last_event_seq,
      :definition_id,
      :correlation_key,
      :current_nodes,
      :variables,
      :join_counters,
      :variable_labels,
      :parent_instance_id,
      :parent_token_id
    ])
    |> validate_required([:instance_id, :status, :definition_id])
    |> unique_constraint(:correlation_key, name: :uq_instance_correlation)
  end

  @doc """
  Structural changeset for advancing an existing projection row. `instance_id`,
  `definition_id` and `correlation_key` are structurally not castable here —
  a projection never changes which instance it describes, or which
  definition it was started from, or its correlation key (all immutable
  after the EE-01 insert, design req043 §2.3).
  """
  @spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def update_changeset(projection, attrs) do
    projection
    |> cast(attrs, [
      :status,
      :last_event_seq,
      :current_nodes,
      :variables,
      :join_counters,
      :variable_labels,
      :error_detail,
      :completed_at,
      :cancelled_at
    ])
    |> validate_required([:status, :last_event_seq])
    |> validate_number(:last_event_seq, greater_than_or_equal_to: 0)
  end

  @doc """
  Whether a projection status forbids further appends to its instance.

  `true` for `:completed` and `:cancelled` only. `:error` is **not** terminal —
  R-Co's `src/design/event_store.md:292` (Key invariant 10) names exactly
  CANCELLED and COMPLETED. Pure, no I/O. Exists so REQ-025's active-instance
  guard has one authoritative definition of "terminated" (design INV-EV-10).
  """
  @spec terminal?(status()) :: boolean()
  def terminal?(status) when status in [:completed, :cancelled], do: true
  def terminal?(status) when status in [:active, :error], do: false
end
