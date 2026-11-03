defmodule Letflow.Modules.TenantModuleUpgrade do
  @moduledoc """
  One row of the per-tenant `tenant_module_upgrades` journal (GH #3578 / REQ-640, decision 0055 D1).
  No `tenant_id` field: tenancy is the schema prefix (decision 0006 D2), so every use passes an
  explicit `prefix:` (INV-1), as `Letflow.Modules.TenantModule` does.

  No writer or reader exists in this slice (the table starts empty). `kind` is limited to
  `:upgrade | :rollback`; uninstall and reactivate belong to the uninstall record (0055 D11). A later
  status read must not expose `step_cursor`, `runner_id` or the lease fields (INV-2).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenant_module_upgrades" do
    field(:module_id, :string)
    field(:from_version, :string)
    field(:to_version, :string)
    field(:kind, Ecto.Enum, values: [:upgrade, :rollback])
    field(:state, Ecto.Enum, values: [:planned, :running, :failed, :done, :abandoned])
    field(:plan_hash, :string)
    field(:actor_id, :binary_id)
    field(:rationale, :string)
    field(:step_id, :string)
    field(:step_cursor, :string)
    field(:steps_done, {:array, :string}, default: [])
    field(:touches, :map)
    field(:catchup_from_seq, :integer)
    field(:runner_id, :string)
    field(:epoch, :integer, default: 1)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:error_code, :string)
  end

  @fields [
    :module_id,
    :from_version,
    :to_version,
    :kind,
    :state,
    :plan_hash,
    :actor_id,
    :rationale,
    :step_id,
    :step_cursor,
    :steps_done,
    :touches,
    :catchup_from_seq,
    :runner_id,
    :epoch,
    :heartbeat_at,
    :started_at,
    :finished_at,
    :error_code
  ]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:module_id, :from_version, :to_version, :kind, :state])
  end
end
