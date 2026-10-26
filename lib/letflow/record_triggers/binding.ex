defmodule Letflow.RecordTriggers.Binding do
  @moduledoc """
  REQ-570 slice T-1 part 1 (GH #3248) -- one pin of a published `entity_event` script version to an
  entity type and one record event (`record_trigger_bindings`, a per-tenant table; the schema prefix
  is passed on every `Repo` call, never set here). At most one binding per (entity type, event)
  (unique index); a type may carry bindings for several events.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "record_trigger_bindings" do
    field(:tenant_id, :binary_id)
    field(:entity_type, :string)
    field(:event, Ecto.Enum, values: [:created, :updated, :deleted])
    field(:script_key, :string)
    field(:script_version, :integer)
    field(:script_sha256, :string)
    field(:status, Ecto.Enum, values: [:active, :disabled], default: :active)
    field(:bound_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end
end
