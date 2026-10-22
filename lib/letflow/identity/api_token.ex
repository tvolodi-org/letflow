defmodule Letflow.Identity.ApiToken do
  @moduledoc """
  Ecto schema for the `api_tokens` table (REQ-076). Tenant-scoped — lives in each
  tenant's own Postgres schema, alongside `users`/`groups`/`tenant_role` (Decision
  0006). See `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §2 for
  the full design.

  **`token_hash` is the ONLY on-disk representation of an issued token — this
  struct, and this table, never carry the plaintext value anywhere (INV-4).** The
  plaintext is generated and returned exactly once, by
  `Letflow.Identity.create_token/3`'s own return tuple — it is never assigned to any
  field on this schema, never passed to `Ecto.Changeset.cast/3`, and no changeset
  function defined below accepts a `"token"`/`"plaintext"` key even if a caller
  supplied one (neither `insert_changeset/2`'s cast list below names such a field).

  Roles are snapshotted at issuance, not live-referenced — a later change to the
  role registry does not affect an already-issued token's own `roles` list. No
  live role-lookup join exists on this table by design (see
  `Letflow.Identity.create_token/3`'s own @doc).

  **`issuer_user_id`** (GH 2552, decision 0051 M2): the principal that minted the token
  over HTTP (`Letflow.Identity.mint_token/4`), set by the server from the authenticated
  caller, never from a request body. NULL means legacy: a row from before GH 2552, or
  one from the trusted non-HTTP path `Letflow.Identity.create_token/3` ("issuer not
  recorded"). The issuer is ATTRIBUTION ONLY: a token always acts as its OWNER,
  `user_id` (`Letflow.Identity.verify_api_token/2`), so any separation-of-duties check
  (0053 D6) must compare owners, never `issuer_user_id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "api_tokens" do
    field(:user_id, :binary_id)
    field(:name, :string)
    field(:token_hash, :string)
    field(:roles, {:array, :string})
    field(:expires_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)
    field(:last_used_at, :utc_datetime)
    field(:issuer_user_id, :binary_id)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc """
  Insert changeset for `Letflow.Identity.create_token/3` and `mint_token/4`. `attrs`
  carries only `user_id`/`name`/`token_hash`/`roles`/`expires_at`/`issuer_user_id` —
  every field this changeset's own `cast/3` list names, and NOT a `"token"`/`"plaintext"`
  key (see moduledoc). `issuer_user_id` is optional (NULL = legacy, GH 2552) and comes
  only from the server-built attrs in `Letflow.Identity`; no other changeset casts it.
  """
  @spec insert_changeset(t(), map()) :: Ecto.Changeset.t()
  def insert_changeset(%__MODULE__{} = token, attrs) do
    token
    |> cast(attrs, [:user_id, :name, :token_hash, :roles, :expires_at, :issuer_user_id])
    |> validate_required([:user_id, :name, :token_hash, :roles])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:issuer_user_id)
  end

  @doc """
  True for a PLATFORM_ADMIN token with no expiry (GH 2579, the legacy standing credential the
  inventory lists and the token list flags). Pure: it ignores revocation, like
  `Letflow.Identity.TokenPreconditions`, which uses this predicate.
  """
  @spec non_expiring_platform_admin?(t()) :: boolean()
  def non_expiring_platform_admin?(%__MODULE__{roles: roles, expires_at: expires_at}) do
    "PLATFORM_ADMIN" in (roles || []) and is_nil(expires_at)
  end

  @doc "Revocation changeset — sets `revoked_at` only. See `Letflow.Identity.revoke_token/2`."
  @spec revoke_changeset(t(), map()) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{} = token, attrs) do
    cast(token, attrs, [:revoked_at])
  end

  @doc """
  REQ-447: narrow changeset for `Letflow.Identity.TenantAdminMigration` that casts
  ONLY `roles` -- the token hash, expiry, revocation and name stay untouched, so the
  plaintext token keeps working after its stored role strings are rewritten.
  """
  @spec roles_rewrite_changeset(t(), [String.t()]) :: Ecto.Changeset.t()
  def roles_rewrite_changeset(%__MODULE__{} = token, roles) when is_list(roles) do
    token
    |> cast(%{roles: roles}, [:roles])
    |> validate_required([:roles])
  end

  @doc "Best-effort `last_used_at` touch. See `Letflow.Identity.verify_api_token/2`."
  @spec touch_last_used_changeset(t(), map()) :: Ecto.Changeset.t()
  def touch_last_used_changeset(%__MODULE__{} = token, attrs) do
    cast(token, attrs, [:last_used_at])
  end
end
