defmodule Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch do
  @moduledoc """
  GH 2534 PR 7c-1: Ecto schema for the tenant table `script_task_dispatches` (design
  `lib/letflow/design/gh2534-7c-script-handler.md` section 3.1). No `@schema_prefix`: every
  call passes `prefix:`.

  The only changeset is `arm_changeset/2` (the INSERT at activation). The claim, reschedule,
  finish, sweep and cancel writes are explicit `update_all` calls with full predicates in
  `Letflow.Engine.ScriptTaskDispatcher` / `Letflow.Engine`, each setting `updated_at`
  (anti-pattern 4183). `status` and `attempt` are not castable. Every column is value-free.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "script_task_dispatches" do
    field(:instance_id, Ecto.UUID)
    field(:token_id, Ecto.UUID)
    field(:node_id, :string)
    field(:script_key, :string)
    field(:script_version, :integer)
    field(:script_sha256, :string)
    field(:status, :string, default: "pending")
    field(:attempt, :integer, default: 0)
    field(:busy_retries, :integer, default: 0)
    field(:sweep_failures, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:claimed_at, :utc_datetime_usec)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:claimed_by, :string)
    field(:event_time, :utc_datetime_usec)
    field(:triggering_user_id, Ecto.UUID)
    field(:outcome, :string)
    field(:outcome_detail, :string)
    field(:finished_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          instance_id: Ecto.UUID.t(),
          token_id: Ecto.UUID.t(),
          node_id: String.t(),
          script_key: String.t(),
          script_version: pos_integer(),
          script_sha256: String.t(),
          status: String.t(),
          attempt: non_neg_integer(),
          busy_retries: non_neg_integer(),
          sweep_failures: non_neg_integer(),
          next_attempt_at: DateTime.t(),
          claimed_at: DateTime.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          claimed_by: String.t() | nil,
          event_time: DateTime.t(),
          triggering_user_id: Ecto.UUID.t() | nil,
          outcome: String.t() | nil,
          outcome_detail: String.t() | nil,
          finished_at: DateTime.t() | nil
        }

  @arm_fields [
    :id,
    :instance_id,
    :token_id,
    :node_id,
    :script_key,
    :script_version,
    :script_sha256,
    :event_time,
    :triggering_user_id,
    :next_attempt_at
  ]

  @doc """
  The activation INSERT (design 4.4): identity columns, the arm-time `event_time` (= the
  script's `ctx.now`), the command actor and `next_attempt_at`. `status`/`attempt` are not
  castable (the column defaults apply).
  """
  @spec arm_changeset(t(), map()) :: Ecto.Changeset.t()
  def arm_changeset(dispatch, attrs) do
    dispatch
    |> cast(attrs, @arm_fields)
    |> validate_required(@arm_fields -- [:triggering_user_id])
  end
end
