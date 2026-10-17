defmodule Letflow.Identity.User do
  @moduledoc """
  Ecto schema for the `users` table. Ported from R-Co
  `src/design/adp-04-user-tenant-binding.md` ("Data model and
  migration/backfill semantics", "Index and constraint guidance") and
  `src/design/adp-04a-external-identity-linkage-user.md` ("Data model and
  migration/backfill semantics", "Unique index semantics", "Key
  invariants").

  `tenant_id` was an intra-schema column per Decision B
  (`docs/migration/decisions/0003-ecto-schema-strategy.md`) until Decision
  0006 D2 (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`)
  dropped it — the per-tenant Postgres schema (Decision 0006 D1) already
  fully identifies which tenant this table's rows belong to, making the
  column redundant. See 0006 §R1-R3 for the full reasoning and the `users`
  per-tenant migration's own header for this table's specific history.

  `auth_source`-vs-external-fields consistency (adp-04a's rule 2:
  `auth_source: :oidc` requires both `external_id`/`external_realm`
  non-null; `auth_source: :internal` requires both null) is an
  application-level (changeset) invariant, implemented in REQ-018/REQ-019 —
  it is NOT enforced by this schema module or by a DB-level CHECK
  constraint in the migration.

  `jit_changeset/2` is REQ-018's JIT-provisioning insert changeset — the first
  changeset function defined on this schema. `create_changeset/2`,
  `profile_changeset/2`, and `status_changeset/2` (below) are REQ-073's
  additions for internally-created (non-OIDC) users and the user-CRUD routes —
  see `lib/letflow/design/req073-identity-user-routes.md` §7.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "users" do
    field(:username, :string)
    field(:display_name, :string)
    field(:email, :string)
    field(:password_hash, :string)
    field(:status, Ecto.Enum, values: [:active, :inactive], default: :active)
    field(:auth_source, Ecto.Enum, values: [:internal, :oidc], default: :internal)
    field(:external_id, :string)
    field(:external_realm, :string)
    field(:role_claims_synced_at, :utc_datetime_usec)
    # REQ-517: written ONLY by `Letflow.Identity.ServicePrincipal`; in no cast list.
    field(:admin_flagged_service_principal, :boolean, default: false)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Builds the insert changeset for a JIT-provisioned (OIDC) user, per
  `lib/letflow/design/req018-jit-provisioning.md` §4/§5. `external_realm`,
  `external_id`, `username`, `display_name`, and `email` are populated from
  the caller-supplied `attrs` map (built by
  `Letflow.Identity.provision_oidc_user/3` from its `IdentityContext`
  argument — never taken directly from raw external input by this
  function). `password_hash` and `auth_source` are fixed, changeset-internal
  values — set unconditionally below, never accepted from `attrs`, so no
  caller can override them.
  """
  @spec jit_changeset(t(), map()) :: Ecto.Changeset.t()
  def jit_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [
      :external_realm,
      :external_id,
      :username,
      :display_name,
      :email,
      :status
    ])
    |> validate_required([
      :external_realm,
      :external_id,
      :username,
      :display_name,
      :email,
      :status
    ])
    |> put_change(:password_hash, "__OIDC_ONLY__")
    |> put_change(:auth_source, :oidc)
    |> unique_constraint(:username)
    |> unique_constraint([:external_realm, :external_id],
      name: :users_external_identity_partial_index
    )
  end

  @doc """
  Builds the insert changeset for an internally-created (non-OIDC) user, per
  `lib/letflow/design/req073-identity-user-routes.md` §7 gap 1 —
  `Letflow.Identity.create_user/2`'s changeset. Casts `username`,
  `display_name`, `email`, and `status` (defaults to `"active"` when omitted)
  from caller-supplied `attrs`; `auth_source` and `password_hash` are fixed,
  changeset-internal values, never accepted from `attrs`.

  **OQ-3 (design §7/§Open questions), decided here:** an internally-created
  user has no password-setting endpoint in this requirement's scope, so
  `password_hash` is set to the sentinel `"__NO_PASSWORD_SET__"` —
  chosen to mirror `jit_changeset/2`'s own `"__OIDC_ONLY__"` sentinel pattern
  (a value that can never be a real bcrypt/argon2 hash, so it can't be
  mistaken for one, and a future password-set endpoint has an unambiguous
  "no password yet" value to detect and overwrite).
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = user, attrs) do
    attrs_with_default_status = Map.put_new(attrs, "status", "active")

    user
    |> cast(attrs_with_default_status, [:username, :display_name, :email, :status])
    |> validate_required([:username, :display_name, :email, :status])
    |> put_change(:password_hash, "__NO_PASSWORD_SET__")
    |> put_change(:auth_source, :internal)
    |> unique_constraint(:username)
  end

  @doc """
  Partial-update changeset for `Letflow.Identity.update_user_profile/3` (design
  §7 gap 4). All three fields optional — no `validate_required/2` — since a
  PATCH may omit any subset and `cast/3` already leaves an omitted key's
  existing value on `user` untouched.
  """
  @spec profile_changeset(t(), map()) :: Ecto.Changeset.t()
  def profile_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [:display_name, :email, :status])
    |> unique_constraint(:username)
  end

  @doc """
  Status-only changeset for `Letflow.Identity.update_user_status/3` (design §7
  gap 5, OQ-5 — kept as its own function rather than reusing
  `profile_changeset/2`, since `status` is `validate_required/2` here: this
  changeset's one caller always supplies a validated status and a missing
  value would be a defensive-only branch worth surfacing distinctly).
  """
  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [:status])
    |> validate_required([:status])
  end
end
