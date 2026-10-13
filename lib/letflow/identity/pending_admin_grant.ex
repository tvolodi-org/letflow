defmodule Letflow.Identity.PendingAdminGrant do
  @moduledoc """
  ISS-1030 (design `lib/letflow/design/iss1030-onboarding-administrator.md` §4.1):
  Ecto schema for the tenant-schema table `pending_tenant_admin_grants` -- one
  row per administrator the platform operator named when onboarding a tenant.

  The grant confers `TENANT_ADMIN` and nothing else; that is enforced by CHECK
  constraints in the table, not only by code. `role_name` and `created_via` are
  therefore never cast: the column defaults are the only values the database
  accepts.

  `email_key` holds the normalised address (trim + lower-case, ASCII only) ONLY
  while the grant is open. It is NULL once the grant is bound (the bound user's
  row holds the address) or revoked. The creator's identity is deliberately NOT
  stored here: it lives in the platform tenant's audit chain, reachable by the
  grant id (design section 7a).

  Row lifecycle (`state/1`): `:open` -> `:bound` or `:revoked`; never back.
  Transitions are conditional updates inside
  `Letflow.Identity.PendingAdminGrants`, so there is no update changeset.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type state :: :open | :bound | :revoked

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "pending_tenant_admin_grants" do
    field(:email_key, :string)
    field(:role_name, :string, default: "TENANT_ADMIN")
    field(:created_via, :string, default: "onboarding")
    field(:consumed_at, :utc_datetime_usec)
    field(:consumed_by_user_id, Ecto.UUID)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Insert changeset. Casts ONLY `email_key`, which the caller has already
  normalised with `Letflow.Identity.PendingAdminGrants.normalize_email/1`.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = grant, attrs) do
    grant
    |> cast(attrs, [:email_key])
    |> validate_required([:email_key])
    |> unique_constraint(:email_key, name: :pending_tenant_admin_grants_email_key_idx)
    |> check_constraint(:email_key, name: :pending_tenant_admin_grants_state_chk)
  end

  @doc "The lifecycle state of a grant row, derived from its two marker columns."
  @spec state(t()) :: state()
  def state(%__MODULE__{consumed_at: %DateTime{}}), do: :bound
  def state(%__MODULE__{revoked_at: %DateTime{}}), do: :revoked
  def state(%__MODULE__{}), do: :open
end
