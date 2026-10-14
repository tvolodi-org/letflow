defmodule Letflow.Scripts.ScriptPolicy do
  @moduledoc """
  GH 2534 PR 7b-2a (decision 0053 D7 "Kill switch"): the tenant's script policy, exactly one row
  (`id = 1`) in the tenant schema table `script_policy`. Design:
  `lib/letflow/design/gh2534-7b2a-script-policy.md` section 2.1.

  Two latches (P1): `tenant_kill_switch` (a tenant-wide TENANT_ADMIN) and
  `platform_kill_switch` (the platform operator). The effective switch is either latch on.
  Each writer has its OWN changeset casting only its own columns (SEC F4), so neither path can
  touch the other's latch; there is no other changeset. Attributes are built by
  `Letflow.Scripts.Policy`, never taken from a request body.

  The row is created by the migration and never deleted; the `script_policy_guard` trigger
  refuses a DELETE and any change of `id` or `inserted_at` (SQLSTATE `LF001`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @tenant_latch_fields [
    :tenant_kill_switch,
    :tenant_kill_switch_set_by,
    :tenant_kill_switch_set_at,
    :tenant_kill_switch_reason
  ]

  @platform_latch_fields [
    :platform_kill_switch,
    :platform_kill_switch_set_at,
    :platform_kill_switch_reason
  ]

  schema "script_policy" do
    field(:tenant_kill_switch, :boolean, default: false)
    field(:tenant_kill_switch_set_by, :binary_id)
    field(:tenant_kill_switch_set_at, :utc_datetime_usec)
    field(:tenant_kill_switch_reason, :string)
    field(:platform_kill_switch, :boolean, default: false)
    field(:platform_kill_switch_set_at, :utc_datetime_usec)
    field(:platform_kill_switch_reason, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The tenant latch: casts only the four `tenant_kill_switch*` columns (SEC F4)."
  @spec tenant_latch_changeset(t(), map()) :: Ecto.Changeset.t()
  def tenant_latch_changeset(%__MODULE__{} = policy, attrs) do
    policy
    |> cast(attrs, @tenant_latch_fields)
    |> validate_required([:tenant_kill_switch])
  end

  @doc "The platform latch: casts only the three `platform_kill_switch*` columns (SEC F4)."
  @spec platform_latch_changeset(t(), map()) :: Ecto.Changeset.t()
  def platform_latch_changeset(%__MODULE__{} = policy, attrs) do
    policy
    |> cast(attrs, @platform_latch_fields)
    |> validate_required([:platform_kill_switch])
  end

  @doc "The effective switch: either latch on (P1)."
  @spec effective?(t()) :: boolean()
  def effective?(%__MODULE__{tenant_kill_switch: tenant, platform_kill_switch: platform}),
    do: tenant == true or platform == true
end
