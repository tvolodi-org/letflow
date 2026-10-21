defmodule Letflow.Scripts.ScriptPolicy do
  @moduledoc """
  GH 2534 PR 7b-2a (decision 0053 D7 "Kill switch"): the tenant's script policy, exactly one row
  (`id = 1`) in the tenant schema table `script_policy`. Design:
  `lib/letflow/design/gh2534-7b2a-script-policy.md` section 2.1.

  Two latches (P1): `tenant_kill_switch` (a tenant-wide TENANT_ADMIN) and
  `platform_kill_switch` (the platform operator). The effective switch is either latch on.
  Each writer has its OWN changeset casting only its own columns (SEC F4), so neither path can
  touch the other's latch. Attributes are built by `Letflow.Scripts.Policy`, never taken from a
  request body.

  GH 2534 PR 7b-2b (`lib/letflow/design/gh2534-7b2b-script-sod.md` 3.1): the declared
  `sod` (`strict | solo_audited`) with its writer, and the platform flag
  `platform_solo_audited_allowed`; `sod_changeset/2` and `platform_solo_changeset/2` cast
  only those columns, never a kill-switch column. A DB CHECK refuses a declared
  `solo_audited` while the platform forbids it.

  `sod` is an `Ecto.Enum` over the `:string` column (GH 2603): its atoms equal the DB CHECK set
  (`strict | solo_audited`), which stays the backstop, so an invalid value is a changeset error
  from `cast/3`; external forms (JSON, audit entries) render it via `Atom.to_string/1`.

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

  @sod_fields [:sod, :sod_set_by, :sod_set_by_class, :sod_set_at, :sod_reason]

  @platform_solo_fields [
    :platform_solo_audited_allowed,
    :platform_solo_audited_set_at,
    :platform_solo_audited_reason
  ]

  schema "script_policy" do
    field(:tenant_kill_switch, :boolean, default: false)
    field(:tenant_kill_switch_set_by, :binary_id)
    field(:tenant_kill_switch_set_at, :utc_datetime_usec)
    field(:tenant_kill_switch_reason, :string)
    field(:platform_kill_switch, :boolean, default: false)
    field(:platform_kill_switch_set_at, :utc_datetime_usec)
    field(:platform_kill_switch_reason, :string)
    # GH 2534 PR 7b-2b (design gh2534-7b2b-script-sod.md 3.1): the DECLARED sod policy and the
    # platform flag allowing `solo_audited` (default forbidden, S2).
    field(:sod, Ecto.Enum, values: [:strict, :solo_audited], default: :strict)
    field(:sod_set_by, :binary_id)
    field(:sod_set_by_class, :string)
    field(:sod_set_at, :utc_datetime_usec)
    field(:sod_reason, :string)
    field(:platform_solo_audited_allowed, :boolean, default: false)
    field(:platform_solo_audited_set_at, :utc_datetime_usec)
    field(:platform_solo_audited_reason, :string)

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

  @doc """
  7b-2b: the declared sod (tenant decision, the auto-strict system write, or the S3 reset):
  casts only the five `sod*` columns.
  """
  @spec sod_changeset(t(), map()) :: Ecto.Changeset.t()
  def sod_changeset(%__MODULE__{} = policy, attrs) do
    policy
    |> cast(attrs, @sod_fields)
    |> validate_required([:sod, :sod_set_by_class, :sod_set_at])
  end

  @doc """
  7b-2b: the platform solo flag: casts the three `platform_solo_audited*` columns plus, for the
  S3 reset that is part of the operator's act, the five `sod*` columns. No kill-switch column.
  """
  @spec platform_solo_changeset(t(), map()) :: Ecto.Changeset.t()
  def platform_solo_changeset(%__MODULE__{} = policy, attrs) do
    policy
    |> cast(attrs, @platform_solo_fields ++ @sod_fields)
    |> validate_required([:platform_solo_audited_allowed, :sod])
  end

  @doc "The effective switch: either latch on (P1)."
  @spec effective?(t()) :: boolean()
  def effective?(%__MODULE__{tenant_kill_switch: tenant, platform_kill_switch: platform}),
    do: tenant == true or platform == true
end
