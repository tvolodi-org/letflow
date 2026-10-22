defmodule Letflow.Scheduler.Timer do
  @moduledoc """
  Ecto schema for the `timers` table. See
  `lib/letflow/design/req186-scheduler-core.md` §1.5. Ordinary
  `Ecto.Schema`, no process, no `gen_statem` — matches
  `Letflow.Dlq.Entry`'s own plain-CRUD-table precedent.

  ## No `@schema_prefix`

  Like every other tenant-scoped table in this codebase, `timers` lives in
  many Postgres schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time.

  ## `status`, `timer_type` — plain `:string`, not `Ecto.Enum` (design §1.1)

  `status` has a DB-level CHECK constraint (`chk_timers_status`, the
  migration) restricting it to exactly `"pending"`/`"fired"`/`"cancelled"`/
  `"failed"` — the DB constraint is the acceptance-criterion-mandated
  backstop, not a substitute for a changeset check, so this schema stays
  plain `:string` (an `Ecto.Enum` would duplicate that guard at the
  application layer for no additional acceptance-criterion-driven benefit).
  `timer_type` is plain `:string` too — extensible, mirroring
  `dlq_entries.entry_type`'s own precedent — with a changeset-level
  `validate_inclusion/3` in `arm_changeset/2` as its only guard (no DB CHECK
  on this column, per design §1.1).

  ## No `timestamps/1`

  `fired_at`/`cancelled_at`/`failed_at`/`created_at` are specific, narrow
  timestamp columns this table's own contract names — not a generic
  last-modified column nothing in the acceptance criteria requires. Same
  rationale as `Letflow.Dlq.Entry`.

  ## Changesets — one per distinct write path (design §1.5)

  Mirrors `Letflow.Dlq.Entry`'s multi-changeset shape: `arm_changeset/2`
  (`Letflow.Scheduler.create/2`), `fire_changeset/2` (the fire-transaction
  step), `retry_increment_changeset/2` (the separate failure-accounting
  transaction, ISS-303/ISS-0618), `fail_changeset/2` (the terminal-failure
  step), and `rearm_changeset/2` — reserved for REQ-188, not called by any
  REQ-186 function; the atom is defined here so REQ-188's own design does
  not have to guess a name.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timer_types Letflow.Scheduler.TimerTypes.all()

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "timers" do
    field(:tenant_id, Ecto.UUID)
    field(:instance_id, Ecto.UUID)
    field(:token_id, Ecto.UUID)

    field(:timer_type, :string)
    field(:node_id, :string)
    field(:fire_at, :utc_datetime_usec)

    field(:status, :string, default: "pending")
    field(:fired_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)
    field(:failed_at, :utc_datetime_usec)
    field(:cancel_reason, :string)

    field(:fire_error_count, :integer, default: 0)

    field(:repeat_expression, :string)
    field(:repeat_interval_us, :integer)
    field(:repeat_total, :integer)
    field(:fired_count, :integer)

    field(:created_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          instance_id: Ecto.UUID.t(),
          token_id: Ecto.UUID.t() | nil,
          timer_type: String.t(),
          node_id: String.t(),
          fire_at: DateTime.t(),
          status: String.t(),
          fired_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          cancel_reason: String.t() | nil,
          fire_error_count: non_neg_integer(),
          repeat_expression: String.t() | nil,
          repeat_interval_us: non_neg_integer() | nil,
          repeat_total: pos_integer() | nil,
          fired_count: non_neg_integer() | nil,
          created_at: DateTime.t()
        }

  @doc """
  Structural changeset for `Letflow.Scheduler.create/2` (design §2.1).
  `status` is not castable through this changeset — always forced to
  `"pending"` by the context function, matching `Letflow.Dlq.enqueue/2`'s
  own "four fields the changeset can't override" discipline.
  """
  @spec arm_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def arm_changeset(timer, attrs) do
    timer
    |> cast(attrs, [
      :id,
      :tenant_id,
      :instance_id,
      :token_id,
      :timer_type,
      :node_id,
      :fire_at,
      :repeat_expression,
      :repeat_interval_us,
      :repeat_total,
      :fired_count,
      :created_at
    ])
    |> validate_required([
      :id,
      :tenant_id,
      :instance_id,
      :timer_type,
      :node_id,
      :fire_at,
      :created_at
    ])
    |> validate_inclusion(:timer_type, @timer_types)
  end

  @doc """
  Structural changeset for the fire-transaction step (design §2.4). Casts
  only `[:status, :fired_at]` — always sets `status: "fired"`.
  """
  @spec fire_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def fire_changeset(timer, attrs) do
    timer
    |> cast(attrs, [:status, :fired_at])
    |> validate_required([:status, :fired_at])
  end

  @doc """
  Structural changeset for the failure-accounting step (design §2.5,
  ISS-303/ISS-0618). Casts only `[:fire_error_count]`.
  """
  @spec retry_increment_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def retry_increment_changeset(timer, attrs) do
    timer
    |> cast(attrs, [:fire_error_count])
    |> validate_required([:fire_error_count])
  end

  @doc """
  Structural changeset for the terminal-failure step (design §2.5 step 3).
  Casts only `[:status, :failed_at]` — always sets `status: "failed"`.
  """
  @spec fail_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def fail_changeset(timer, attrs) do
    timer
    |> cast(attrs, [:status, :failed_at])
    |> validate_required([:status, :failed_at])
  end

  @doc """
  Structural changeset for `Letflow.Scheduler.maybe_rearm_timer/3` (REQ-188
  design §1.3). Unlike the other changesets in this module, this one builds
  a COMPLETE new row (a fresh chain successor), not a partial update of an
  existing struct — so it casts the same full field list `arm_changeset/2`
  casts, plus the recurrence quartet and `fire_at`/`status`. `status` is
  still always forced to `"pending"` by the caller
  (`Letflow.Scheduler.build_rearm_attrs/2`), never caller-controlled,
  matching `arm_changeset/2`'s own discipline.
  """
  @spec rearm_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def rearm_changeset(timer, attrs) do
    timer
    |> cast(attrs, [
      :id,
      :tenant_id,
      :instance_id,
      :token_id,
      :timer_type,
      :node_id,
      :created_at,
      :status,
      :fire_at,
      :repeat_expression,
      :repeat_interval_us,
      :repeat_total,
      :fired_count
    ])
    |> validate_required([
      :id,
      :tenant_id,
      :instance_id,
      :timer_type,
      :node_id,
      :fire_at,
      :status,
      :repeat_expression,
      :repeat_interval_us,
      :fired_count,
      :created_at
    ])
  end
end
