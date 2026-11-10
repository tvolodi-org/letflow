defmodule Letflow.Platform.ModuleRollout.Rollout do
  @moduledoc """
  `Ecto.Schema` for `platform_module_rollouts` (RU-S6, decision 0055 fact 10): the global (not
  tenant-scoped) record of one module version rolled out tenant by tenant by
  `Letflow.ModuleUpgrade.Fleet`. Sibling of `Letflow.Platform.MigrationRollout.Rollout`.

  `(module_id, to_version)` is the natural key (unique index): starting the same rollout again
  returns the same row. `halt_after` is the setting value at start; `consecutive_failures` counts
  failed outcomes since the last success or skip.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "platform_module_rollouts" do
    field(:module_id, :string)
    field(:to_version, :string)
    field(:status, :string, default: "running")
    field(:halt_after, :integer)
    field(:consecutive_failures, :integer, default: 0)
    field(:started_by, Ecto.UUID)
    field(:started_at, :naive_datetime)
    field(:completed_at, :naive_datetime)
    field(:halted_at, :naive_datetime)
  end

  @type t :: %__MODULE__{}
end
