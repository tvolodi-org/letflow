import Config

# REQ-190 (docs/migration/decisions/0016-secrets-storage-backend.md §B):
# config/runtime.exs's LETFLOW_SECRETS_MASTER_KEY startup check runs in
# EVERY environment, including dev -- it must never be weakened. Unlike
# config/test.exs, dev intentionally does NOT inject a value here: a
# developer running `mix run`/`mix ecto.migrate` locally must set a real
# value themselves (in the environment, or the untracked .env at the repo
# root -- see .env.example), same as any other operator-supplied secret this
# codebase never defaults. This comment exists so a `raise` at dev boot is
# recognized as the intended behavior, not a bug in this migration.

# ISS-0015 (GH#71): MIX_TEST_PARTITION only takes effect under
# config/test.exs -- a bare `mix run` (MIX_ENV=dev by default) would
# silently ignore it and connect to the shared letflow_dev database below,
# defeating the isolation MIX_TEST_PARTITION exists for in this project's
# two-worktree setup. Fail loudly instead.
if System.get_env("MIX_TEST_PARTITION") do
  raise """
  MIX_TEST_PARTITION=#{System.get_env("MIX_TEST_PARTITION")} is set, but MIX_ENV is
  "dev" -- only config/test.exs reads this variable, so this run would silently
  target the shared letflow_dev database instead of a partitioned test database.

  If you meant to run tests: set MIX_ENV=test.
  If you're intentionally running dev tooling: unset MIX_TEST_PARTITION first.
  """
end

# HTTP listener: on by default (see lib/letflow/application.ex's http_child/0),
# port 4000. config/test.exs turns this off entirely (ISS-0015/GH#71); prod's
# port comes from config/runtime.exs's PORT env var instead of this file, per
# config/prod.exs's own comment that runtime-dependent values belong there.
config :letflow, start_http: true, http_port: 4000

# Deliberately not 5432 — R-Co's own docker-compose stack already uses 5432
# (dev) and 5433 (test), so Letflow gets its own ports and can run alongside
# R-Co without colliding. (Previously 5434, moved after that port turned out
# to already be in use; then a hardcoded 5462.) The port is now per-workspace
# local state resolved by config/db_port.exs — LETFLOW_DB_PORT from the
# environment or the untracked .env, defaulting to 5462 — because this repo is
# checked out into several workspaces at once and each runs its own
# `docker compose up` against docker-compose.yml's ${LETFLOW_DB_PORT:-5462}
# host-port mapping.
{db_port, _bindings} = Code.eval_file(Path.expand("db_port.exs", __DIR__))

config :letflow, Letflow.Repo,
  username: "letflow",
  password: "letflow",
  database: "letflow_dev",
  hostname: "localhost",
  port: db_port,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  # ISS-0786: 10 was thin against Letflow.Admission's derived global_cap
  # (pool_size - reserved_headroom, default headroom 2 -> cap 8), causing
  # intermittent {:error, :capacity} 503s under concurrent Playwright e2e
  # load in dev mode. Raised to 30 (-> cap 28) for real headroom; no
  # correctness dependency on the exact value elsewhere.
  pool_size: 30,
  # See Letflow.Repo.init/2 -- letflow_dev is shared across every
  # concurrent workspace/host, unlike the partitioned test database.
  # Absent (and therefore false) in config/test.exs and config/prod.exs,
  # so this guard only ever applies here.
  require_dev_db_confirmation: true

# REQ-128: real local Keycloak, replacing the "no real Keycloak instance
# exists yet" placeholder issuer. Realm import: priv/keycloak/realms/bpm-default.json
# (docker-compose.yml's keycloak service, `start-dev --import-realm`). Realm
# name stays "bpm-default" -- NOT renamed -- because it is a pinned domain
# invariant, not just an OIDC placeholder: Letflow.Identity.Tenant's
# @default_tenant_slug and its create_changeset/3 pinning both hardcode the
# literal "bpm-default" as the reserved default-tenant slug AND its required
# idp_realm_id (see that module, docs/migration/decisions and
# lib/letflow/design/req019-tenant-realm-binding.md), and dozens of tests
# (identity_test.exs, claim_mapping_test.exs, auth_pipeline_test.exs, et al.)
# hardcode "bpm-default" as the realm under test. Renaming the realm would
# have silently orphaned that whole fixture set from the config it needs.
# Port is per-workspace local state, same pattern as config/db_port.exs --
# see config/keycloak_port.exs.
#
# client_id: matches the realm file's `letflow-web` public client (REQ-021's
# OQ-2 placeholder resolved). It is only used to build an *unauthenticated*
# Oidcc.ClientContext (no client_secret), since this plug is a resource
# server that only verifies already-issued bearer tokens, never performs a
# token exchange. signing_algs: the JWT signing-algorithm allowlist required
# by Oidcc.Token.validate_jwt/3 (REQ-021's OQ-3) — RS256 matches Keycloak's
# default signing algorithm. token_verifier: which
# Letflow.Oidc.TokenVerifier implementation Letflow.Plugs.AuthPipeline calls
# — the real oidcc-backed adapter here, a test double in config/test.exs.
{keycloak_port, _bindings} = Code.eval_file(Path.expand("keycloak_port.exs", __DIR__))

config :letflow, :oidc,
  # REQ-370: keycloak_base_url replaces :issuer as the trust-resolution
  # source -- Letflow.Oidc.ProviderRegistry builds each realm's own issuer
  # as "#{keycloak_base_url}/realms/#{realm}". No /realms/... suffix here.
  keycloak_base_url: "http://localhost:#{keycloak_port}",
  client_id: "letflow-web",
  signing_algs: ["RS256"],
  token_verifier: Letflow.Oidc.TokenVerifier.Oidcc,
  # See lib/letflow/application.ex's provider_configuration_opts comment --
  # local dev Keycloak serves discovery over plain HTTP, so oidcc's default
  # https-only validation must be relaxed here. Not set in config/prod.exs.
  allow_unsafe_http: true

# ISS-0720 (design lib/letflow/design/iss0720-tenant-config-stale-issuer-key.md
# §2.2): opts dev into Letflow.Routers.TenantConfig's compiled-in
# localhost:8082 fallback, mirroring activation_test_hooks_enabled?'s
# dev/test-only-opt-in shape. Not set in config/prod.exs or
# config/runtime.exs, so the false default holds there and the router raises
# instead of silently serving a localhost URL.
config :letflow, :allow_localhost_idp_fallback, true

# Per-realm claim-path configuration for Letflow.Oidc.ClaimMapping — distinct
# from the :oidc key above (that one is REQ-016's provider-worker-startup
# config, consumed by Letflow.Application; this one is REQ-017's claim-mapping
# config, consumed by Letflow.Oidc.ClaimMappingConfig.for_realm/1). A realm
# with no entry here falls back to Letflow.Oidc.ClaimMappingConfig.default/1.
# Key unchanged (REQ-128 deliberately keeps the realm name "bpm-default" --
# see the :oidc issuer comment above): this key must match the realm name
# the token's issuer names.
config :letflow, :oidc_claim_mapping, %{
  "bpm-default" => %{
    tenant_id_claim: "tenant_id",
    roles_claim_paths: ["realm_access.roles", "roles"],
    email_claim: "email",
    preferred_username_claim: "preferred_username",
    display_name_claim: "name"
  }
}

# Per-realm JIT (just-in-time) user-provisioning configuration for
# Letflow.Identity.provision_oidc_user/3 — distinct from both keys above
# (REQ-016's provider-startup config and REQ-017's claim-mapping config).
# A realm with no entry here falls back to
# Letflow.Oidc.JitProvisioningConfig.default/1.
# Key unchanged (REQ-128), same reason as :oidc_claim_mapping above.
config :letflow, :oidc_jit_provisioning, %{
  "bpm-default" => %{
    enabled: true,
    default_status: :active,
    default_roles: []
  }
}

# Letflow.SandboxPool's hard concurrency ceiling (REQ-039). 5 is an arbitrary
# but reasonable operational default -- no functional correctness depends on
# the exact number, see lib/letflow/design/req039-sandbox-pool-fixture-loader.md
# §9/§11 OQ-4.
config :letflow, :sandbox_pool, max_concurrent_sandboxes: 5

# REQ-193: disable legacy :logger backends in dev (structured JSON via
# OTP default_handler only). Not set in config/test.exs so CaptureLog works.
config :logger, backends: []
config :logger, :default_handler, formatter: {Letflow.Obs.Logger, []}

# REQ-620 / GH #3463: lets CreateLedgerTables.down run (it drops append-only ledger tables). Dev/test
# only; not set in config/prod.exs or config/runtime.exs, so down refuses there.
config :letflow, :allow_ledger_migration_down, true
