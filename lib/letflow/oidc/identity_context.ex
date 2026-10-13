defmodule Letflow.Oidc.IdentityContext do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Pure data shape holding the result of mapping verified OIDC claims onto
  Letflow-internal identity fields. Ported from `src/oidc/claim_mapping.zig`'s
  `IdentityContext` struct (lines 65-72) — see `Letflow.Oidc.ClaimMapping` for
  the mapping function that produces values of this type.

  Zig's `deinit/2` (manual memory release for the struct's owned string/slice
  fields) has no Elixir equivalent and is not ported — the BEAM's own garbage
  collector makes that function structurally inapplicable, not an omission.

  A plain `defstruct`, not an `Ecto.Schema` and not a bare map: this value is
  never persisted directly (it has no backing DB table — `Letflow.Oidc.ClaimMapping`
  never touches `Letflow.Repo`), and it has exactly seven fixed, always-present
  fields (never a variable/open key set), so a compile-time-checkable `defstruct`
  is the right fit rather than a bare map. See
  `lib/letflow/design/req017-claim-mapping.md` §6 for the full reasoning.

  All seven fields are enforced via `@enforce_keys` — every successfully
  constructed `IdentityContext` always has all seven fields present, even when
  a field's value is itself a default (`""`, `nil`, or `[]`).
  """

  @enforce_keys [
    :external_user_id,
    :tenant_id,
    :realm,
    :roles,
    :email,
    :preferred_username,
    :display_name
  ]
  defstruct [
    :external_user_id,
    :tenant_id,
    :realm,
    :roles,
    :email,
    :preferred_username,
    :display_name,
    # ISS-1030: true ONLY when the token's `email_verified` claim is the JSON
    # boolean `true`. Not enforced, default false: every constructor that does
    # not know about it means "not verified".
    email_verified: false
  ]

  @type t :: %__MODULE__{
          external_user_id: String.t(),
          tenant_id: String.t() | nil,
          realm: String.t(),
          roles: [String.t()],
          email: String.t(),
          preferred_username: String.t(),
          display_name: String.t() | nil,
          email_verified: boolean()
        }
end
