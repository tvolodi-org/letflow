defmodule Letflow.RecordTriggers.OutboxRow do
  @moduledoc """
  REQ-606 slice T-2 part 1 (GH #3411) -- one row of `record_trigger_outbox`, a per-tenant table (the
  schema prefix is passed on every `Repo` call, never set here; there is no `tenant_id` column,
  decision 0006 D2). Written only by `Letflow.RecordTriggers.Outbox`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "record_trigger_outbox" do
    field(:binding_id, :binary_id)
    field(:entity_type, :string)
    field(:record_id, :binary_id)
    field(:event, Ecto.Enum, values: [:created, :updated, :deleted])
    field(:source_seq, :integer)
    field(:occurred_at, :utc_datetime_usec)
    field(:script_key, :string)
    field(:script_version, :integer)
    field(:script_sha256, :string)
    field(:depth, :integer, default: 0)
    field(:chain, {:array, :binary_id}, default: [])
    field(:actor_id, :binary_id)
    field(:status, Ecto.Enum, values: [:pending, :running, :done, :dead], default: :pending)
    field(:attempt, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:claimed_at, :utc_datetime_usec)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_code, :string)
    field(:done_at, :utc_datetime_usec)
  end
end
