defmodule Letflow.Engine.Task do
  @moduledoc """
  Ecto schema for the `tasks` table. See
  `lib/letflow/design/req043-instance-engine-schema.md` §4.

  PROVENANCE (historical, not current decision authority):
  ## Scope — schema only, `src/tasks/store.zig`'s query surface NOT ported here

  PROVENANCE (historical, not current decision authority):
  This module is the Ecto schema for the `tasks` table only — the table
  `EE-03` (`src/engine/instance.zig`'s task-activation path) and `EE-04` (task
  completion) write into. R-Co's `src/tasks/store.zig` (1202 lines)
  additionally builds a standalone task query/list/filter surface
  (`TaskStore.list/6`-equivalent: `instance_id`/`status`/`assignee_ref`
  filters, pagination) — **that surface is not ported by this module or by
  REQ-043 at all.** It belongs to S4's tasks routes or its own later
  requirement, per `docs/migration/stage-3-instance-engine.md`'s explicit scope
  boundary. Do not read this schema module as `TaskStore`'s functional
  equivalent — it is schema only, with no query/list/filter functions of its
  own.

  REQ-043 builds only the migration
  (`priv/repo/migrations/20260818110003_create_tasks.exs`) and this schema
  module — no context-module write path (`create/N`, `complete/N`) exists yet;
  those are REQ-045/051's job.

  ## `status` dumps uppercase (design §4.3 point 3, INV-EE43-4)

  `status`'s `Ecto.Enum` dumps **uppercase** (`"PENDING"`/`"COMPLETED"`/
  `"CANCELLED"`), a fixed convention per design §4.3 point 3/INV-EE43-4 — unlike
  `Letflow.Engine.TokenRecord.status`, which dumps lowercase (R-Co itself stores
  these two tables' status columns with different casing too, so this split is
  not a Letflow-introduced inconsistency). Both moduledocs state
  this so neither reader "fixes" the two tables into matching casings.

  ## No `@schema_prefix`

  Like every other multi-tenant table in this schema, `tasks` lives in many
  Postgres schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.

  ## No `tenant_id` column (Decision 0006 D2)

  This table lived inside a per-tenant Postgres schema from the start
  (Decision 0003 Dimension B) — the schema boundary alone already made any
  `tenant_id` column here fully redundant. Decision 0006 D2
  (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`)
  removes it. Do not re-add a `tenant_id` field to this schema without first
  re-reading that record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tasks" do
    field(:instance_id, Ecto.UUID)
    field(:token_id, Ecto.UUID)
    field(:node_id, :string)
    field(:node_name, :string)

    field(:status, Ecto.Enum,
      values: [pending: "PENDING", completed: "COMPLETED", cancelled: "CANCELLED"],
      default: :pending
    )

    field(:assignee_type, :string)
    field(:assignee_ref, :string)
    field(:form_schema, :map)
    field(:output_variables, :map)
    field(:completed_by, Ecto.UUID)
    field(:completed_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)

    # REQ-518 PR 2d (AC 12): the scope node of the approver rule F1. In NO cast list; written only
    # by `TaskActivation.insert_task_row/4`, from the instance's scope node (REQ-532); never in a
    # response map.
    field(:scope_node_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{scope_node_id: String.t() | nil}

  @doc """
  The audit-state map of a task: `Letflow.Audit.struct_state/2` minus `scope_node_id` (REQ-518
  PR 2d), the ONE owner of that exclusion so audit payloads stay byte-identical to before the
  column existed.
  """
  @spec audit_state(t()) :: map()
  def audit_state(%__MODULE__{} = task), do: Letflow.Audit.struct_state(task, [:scope_node_id])

  @type status :: :pending | :completed | :cancelled

  @doc """
  Structural changeset for creating a task row at activation time. Does no I/O.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :instance_id,
      :token_id,
      :node_id,
      :node_name,
      :assignee_type,
      :assignee_ref,
      :form_schema
    ])
    |> validate_required([:instance_id, :token_id, :node_id, :node_name])
  end

  @doc """
  Structural changeset for completing (or cancelling) an existing task row.
  `instance_id`, `token_id`, `node_id` and `node_name` are structurally not
  castable here — a task never changes which instance/token/node it belongs
  to.
  """
  @spec complete_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def complete_changeset(task, attrs) do
    task
    |> cast(attrs, [:status, :output_variables, :completed_by, :completed_at, :cancelled_at])
    |> validate_required([:status])
  end

  @doc """
  Structural changeset for claim/assign/reassign (REQ-085,
  `lib/letflow/design/req085-task-routes-write.md` §3.2). Writes
  `assignee_type`/`assignee_ref` together, always both at once — the same
  "paired write" discipline `insert_changeset/2` already establishes for
  task-activation time, restated here for the claim/assign/reassign write
  path. No I/O.
  """
  @spec assignment_changeset(t(), attrs :: %{assignee_type: String.t(), assignee_ref: String.t()}) ::
          Ecto.Changeset.t()
  def assignment_changeset(task, attrs) do
    task
    |> cast(attrs, [:assignee_type, :assignee_ref])
    |> validate_required([:assignee_type, :assignee_ref])
  end
end
