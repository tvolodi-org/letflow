defmodule Letflow.Scripts.ReadableMaster do
  @moduledoc """
  GH 2534 PR 7b-2a (advisor Q3 interim rule; replaced by 0051 stage 2's module-declared
  `tenant_wide`): one entity type a tenant admin has flagged as readable by tenant scripts
  (tenant schema table `script_readable_masters`). Design:
  `lib/letflow/design/gh2534-7b2a-script-policy.md` section 2.2.

  A row means "flagged"; clearing deletes the row (history lives in the audit chain). No FK to
  `entity_definitions` (definitions are versioned by name, as `entity_type_restrictions`).
  """

  use Ecto.Schema

  @primary_key {:entity_type, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "script_readable_masters" do
    field(:set_by, :binary_id)
    field(:set_at, :utc_datetime_usec)
    field(:reason, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}
end
