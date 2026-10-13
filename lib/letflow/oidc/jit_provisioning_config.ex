defmodule Letflow.Oidc.JitProvisioningConfig do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Per-realm configuration for `Letflow.Identity.provision_oidc_user/3` — whether
  JIT (just-in-time) user creation is enabled for a realm, the default `status`
  a newly-provisioned user gets, and the default role slugs to grant. Ported
  from `src/oidc/jit_provisioning.zig`'s `JitProvisioningConfig` struct (lines
  108-126) and its `DEFAULT_JIT_CONFIG` constant (lines 142-147).

  Sourced from application config (`config :letflow, :oidc_jit_provisioning`, a
  map keyed by realm string — see `config/dev.exs`/`config/test.exs`) for now.
  No DB-backed per-realm config table (Zig's `loadJitConfig`, an I/O-performing
  DB-query function) is built here — only the config *shape* and its
  `DEFAULT_JIT_CONFIG` fallback value are ported. This is a distinct config key
  from `config :letflow, :oidc` (REQ-016's provider-worker-startup config) and
  `config :letflow, :oidc_claim_mapping` (REQ-017's claim-path config) — kept
  separate deliberately, matching `Letflow.Oidc.ClaimMappingConfig`'s precedent
  of one top-level key per concern rather than nesting under `:oidc`.

  `for_realm/1` performs a config read (`Application.fetch_env!/2`), not I/O in
  the DB/network sense. It is not part of `Letflow.Identity.provision_oidc_user/3`'s
  own call graph — callers resolve a `JitProvisioningConfig` via `for_realm/1`
  (or build one directly, e.g. in tests) and pass the already-resolved struct
  in. See `lib/letflow/design/req018-jit-provisioning.md` §1.
  """

  @enforce_keys [:realm, :enabled, :default_status, :default_roles]
  defstruct [
    :realm,
    :enabled,
    :default_status,
    :default_roles,
    # ISS-1030: operator-set, server-side only, default OFF. When true, an
    # e-mail claim WITHOUT `email_verified=true` may bind a pending
    # administrator grant. Never read from a tenant setting, a claim or a request.
    accept_unverified_email_for_admin_bind: false
  ]

  @type t :: %__MODULE__{
          realm: String.t(),
          enabled: boolean(),
          default_status: :active | :inactive,
          default_roles: [String.t()],
          accept_unverified_email_for_admin_bind: boolean()
        }

  @doc """
  Looks up `realm` in `config :letflow, :oidc_jit_provisioning`. Returns a
  `JitProvisioningConfig` built from that realm's configured
  `enabled`/`default_status`/`default_roles` entry if present, otherwise falls
  back to `default/1`.

  ISS-1030: `accept_unverified_email_for_admin_bind` is true only for a realm
  named in `config :letflow, :oidc_admin_bind_unverified_realms`, which
  `config/runtime.exs` fills from `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS`
  (restart to change). No other source can set it.
  """
  @spec for_realm(realm :: String.t()) :: t()
  def for_realm(realm) when is_binary(realm) do
    config_by_realm = Application.fetch_env!(:letflow, :oidc_jit_provisioning)

    base =
      case Map.fetch(config_by_realm, realm) do
        {:ok, entry} ->
          %__MODULE__{
            realm: realm,
            enabled: entry.enabled,
            default_status: entry.default_status,
            default_roles: entry.default_roles
          }

        :error ->
          default(realm)
      end

    %{base | accept_unverified_email_for_admin_bind: unverified_bind_realm?(realm)}
  end

  defp unverified_bind_realm?(realm) do
    case Application.get_env(:letflow, :oidc_admin_bind_unverified_realms, []) do
      realms when is_list(realms) -> realm in realms
      _other -> false
    end
  end

  @doc """
  The hardcoded default JIT config, mirroring Zig's `DEFAULT_JIT_CONFIG` (lines
  142-147): `enabled: true`, `default_status: :active`, `default_roles: []`.
  Same deliberate deviation `Letflow.Oidc.ClaimMappingConfig.default/1` already
  established: `realm` is taken as an argument and threaded into the returned
  struct rather than hardcoded to Zig's literal `""`, since Elixir's caller
  (`for_realm/1`) always knows the realm being looked up.

  Pure — no config read, no I/O. Usable directly by tests and by `for_realm/1`'s
  fallback branch alike.
  """
  @spec default(realm :: String.t()) :: t()
  def default(realm) when is_binary(realm) do
    %__MODULE__{
      realm: realm,
      enabled: true,
      default_status: :active,
      default_roles: [],
      accept_unverified_email_for_admin_bind: false
    }
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  Returns `config.default_roles`, falling back to `["VIEWER"]` when it's empty.
  Mirrors `jit_provisioning.zig`'s own comment on the `default_roles` field:
  "If empty, the user gets no platform roles and defaults to VIEWER."

  Not called by `Letflow.Identity.provision_oidc_user/3` in this requirement —
  no role-binding row is written yet (REQ-020/REQ-02x's territory, see
  `lib/letflow/design/req018-jit-provisioning.md` §6). This accessor exists so
  the fallback *rule* is specified now, ready for whichever future requirement
  persists role bindings.
  """
  @spec default_roles(config :: t()) :: [String.t()]
  def default_roles(%__MODULE__{default_roles: []}), do: ["VIEWER"]
  def default_roles(%__MODULE__{default_roles: roles}), do: roles
end
