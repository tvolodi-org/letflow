defmodule Letflow.Platform.ModuleRollout.Outcome do
  @moduledoc """
  `Ecto.Schema` for `platform_module_rollout_outcomes` (RU-S6): one row per tenant per rollout.
  Holds ids and codes only; no tenant data. `(rollout_id, tenant_id)` is unique.

  Statuses: `pending`, `running` (claimed), `succeeded`, `failed`, `skipped`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "platform_module_rollout_outcomes" do
    field(:rollout_id, Ecto.UUID)
    field(:tenant_id, Ecto.UUID)
    field(:status, :string, default: "pending")
    field(:error_code, :string)
    field(:plan_hash, :string)
    field(:attempted_at, :naive_datetime)
    field(:completed_at, :naive_datetime)
  end

  @type t :: %__MODULE__{}
end
