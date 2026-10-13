import Config

# REQ-190 (docs/migration/decisions/0016-secrets-storage-backend.md §B):
# config/runtime.exs's LETFLOW_SECRETS_MASTER_KEY startup check runs in
# EVERY environment, including test/CI -- it must never be weakened to make
# tests pass. config/test.exs runs (as part of config/config.exs's
# import_config chain) before config/runtime.exs at boot, so System.put_env/2
# here is what supplies a real, valid, test-only 64-hex-char value ahead of
# that check -- one of the two mechanisms the design doc leaves open
# (config/test.exs vs. a System.put_env/2 call in test/test_helper.exs);
# config/test.exs is chosen since it runs strictly before runtime.exs is
# evaluated, which test_helper.exs (loaded only after the application has
# already started) cannot guarantee. Only set if not already present in the
# real environment, so a host that deliberately exports its own value (e.g.
# CI secrets) is not silently overridden. Non-all-zeros, non-all-f's (an
# arbitrary real 32-byte value, hex-encoded) so it also passes the
# literal-value rejection check.
System.get_env("LETFLOW_SECRETS_MASTER_KEY") ||
  System.put_env(
    "LETFLOW_SECRETS_MASTER_KEY",
    "3f1c9a2e7b4d6081f5a3c8e2b7d4f6091a3c5e7b9d2f4a6c8e1b3d5f7a9c2e4b"
  )

# REQ-435: test-only login-directory pepper + key id (never a previous pair; distinct from the master key; not
# all-zero/all-F). Same inject-if-unset pattern as the master key above.
System.get_env("LETFLOW_LOGIN_DIRECTORY_PEPPER") ||
  System.put_env(
    "LETFLOW_LOGIN_DIRECTORY_PEPPER",
    "9d4b1e6a2c8f3705b1d7e9a4c6f20813e5a7b9c1d3f5a70924c6e8b0d2f4a6c8"
  )

System.get_env("LETFLOW_LOGIN_DIRECTORY_PEPPER_ID") ||
  System.put_env("LETFLOW_LOGIN_DIRECTORY_PEPPER_ID", "test-a")

# ISS-0015 (GH#71): don't start the HTTP listener under test at all -- no
# test drives Letflow.Router over a real socket (it's exercised via
# Plug.Test conn structs throughout this suite), so there is nothing to
# gain from binding a port here and a real collision risk to lose: two
# concurrent `mix test` runs (this project's two-worktree setup) previously
# both tried to bind the same hardcoded port 4000. Sidesteps the collision
# entirely rather than just relocating it (e.g. deriving a per-partition
# port), and shaves the listener's startup cost off every run. See
# lib/letflow/application.ex's http_child/0.
config :letflow, start_http: false

# REQ-186: don't start Letflow.Scheduler.Poller under test at all -- its
# very first tick runs with zero delay and queries Letflow.Repo from a
# process no test process is an ancestor of, which under
# Ecto.Adapters.SQL.Sandbox's default :manual mode raises
# DBConnection.OwnershipError repeatedly until Letflow.Supervisor's own
# restart intensity is exceeded and the whole application (Letflow.Repo
# included) shuts down. See lib/letflow/application.ex's
# scheduler_children/0. Letflow.Scheduler's own tests call
# poll_and_fire/1 directly; a test of the Poller GenServer itself starts
# its own instance explicitly.
config :letflow, start_scheduler: false

# REQ-214: don't start Letflow.Engine.ServiceTaskDispatcher.Poller under
# test either -- identical DBConnection.OwnershipError hazard as
# start_scheduler above (its own first tick runs with zero delay and
# queries Letflow.Repo from a process no test process is an ancestor of).
# A distinct, independent config key from :start_scheduler -- see
# lib/letflow/application.ex's service_task_dispatcher_children/0.
# Letflow.Engine.ServiceTaskDispatcher's own tests call poll_and_dispatch/1
# directly; a test of the Poller GenServer itself starts its own instance
# explicitly.
config :letflow, start_service_task_dispatcher: false

# Same per-workspace host port as config/dev.exs (this repo's config files
# don't cascade — each env file loads independently). See config/db_port.exs.
{db_port, _bindings} = Code.eval_file(Path.expand("db_port.exs", __DIR__))

config :letflow, Letflow.Repo,
  username: "letflow",
  password: "letflow",
  database: "letflow_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: "localhost",
  port: db_port,
  pool: Ecto.Adapters.SQL.Sandbox,
  # ISS-0194: scripts/test_parallel.sh computes and exports TEST_POOL_SIZE so
  # N concurrently-launched partitions don't jointly exceed Postgres
  # max_connections (schedulers_online()*2 per partition, multiplied by N,
  # regularly did). A plain `mix test` (no test_parallel.sh, TEST_POOL_SIZE
  # unset) keeps the original sizing unchanged. See
  # docs/migration/decisions/0009-test-parallel-pool-sizing.md.
  pool_size:
    (case System.get_env("TEST_POOL_SIZE") do
       nil -> System.schedulers_online() * 2
       value -> String.to_integer(value)
     end),
  # ISS-0110: tags every Postgres connection this `mix test` invocation opens with
  # this invocation's own OS pid, so Letflow.TenantSchemaReaper.sweep_orphans/2 can
  # tell "another mix test invocation is currently connected to this database" from
  # pg_stat_activity alone, with no new table/column and no change to any of the
  # existing tenant-provisioning call sites. A nested invocation (ISS-0107) gets its
  # own distinct OS pid (Port.open spawns a new OS process), so this tag reliably
  # distinguishes invocations even when they share one database. See
  # test/support/tenant_schema_reaper.ex's moduledoc for how the tag is used.
  #
  # ISS-0217: scripts/test_parallel.sh's own N sibling partitions are each a
  # distinct OS pid too, so ISS-0110's tag alone made every partition look like an
  # unrelated external invocation to every OTHER partition, deferring the reaper's
  # sweep unconditionally for the whole run. TEST_PARALLEL_GROUP, when set, is one
  # value shared by every partition a single test_parallel.sh invocation launches
  # (exported once before forking them) -- folding it into the tag lets the reaper
  # recognise same-group connections as expected siblings rather than external
  # hazards, while a connection with no matching group (a genuinely separate
  # invocation, nested or otherwise) still reads as external exactly as before.
  parameters: [
    application_name:
      "letflow_mixtest_#{System.pid()}" <>
        case System.get_env("TEST_PARALLEL_GROUP") do
          nil -> ""
          group -> "_grp#{group}"
        end
  ]

# REQ-128: real local Keycloak issuer, same as config/dev.exs (see that
# file's comment for the full rationale and docker-compose.yml's keycloak
# service). Duplicated from config/dev.exs: this repo's config files don't
# cascade (each env file loads independently via config.exs's
# import_config "#{config_env()}.exs"), so the :oidc key must be set here
# too or it's absent under MIX_ENV=test.
#
# token_verifier is overridden here (unlike dev/prod's real
# Letflow.Oidc.TokenVerifier.Oidcc adapter) to Letflow.Oidc.TokenVerifierDouble
# — mix test/scripts/test_parallel.sh runs do not depend on a real Keycloak
# being up (see lib/letflow/design/req021-auth-plug-pipeline.md §3.2); the
# issuer string is still updated to the real local one (rather than left as
# the old placeholder) purely so Oidcc.ProviderConfiguration.Worker has a
# real host to resolve discovery against on the rare run where Keycloak
# happens to be reachable, and so dev/test stay in sync.
{keycloak_port, _bindings} = Code.eval_file(Path.expand("keycloak_port.exs", __DIR__))

config :letflow, :oidc,
  # REQ-370: keycloak_base_url replaces :issuer as the trust-resolution
  # source -- see config/dev.exs's comment for the same key.
  keycloak_base_url: "http://localhost:#{keycloak_port}",
  client_id: "letflow-web",
  signing_algs: ["RS256"],
  token_verifier: Letflow.Oidc.TokenVerifierDouble,
  # Same as config/dev.exs -- see lib/letflow/application.ex's
  # provider_configuration_opts comment. Not set in config/prod.exs.
  allow_unsafe_http: true

# ISS-0720 (design lib/letflow/design/iss0720-tenant-config-stale-issuer-key.md
# §2.2): same as config/dev.exs -- opts test into
# Letflow.Routers.TenantConfig's compiled-in localhost:8082 fallback so
# existing tests keep passing unchanged. Not set in config/prod.exs or
# config/runtime.exs.
config :letflow, :allow_localhost_idp_fallback, true

# Duplicated from config/dev.exs (this repo's config files don't cascade —
# see the :oidc key's comment above for the same note). Per-realm
# claim-path configuration for Letflow.Oidc.ClaimMapping, distinct from the
# :oidc key. A realm with no entry here falls back to
# Letflow.Oidc.ClaimMappingConfig.default/1.
# Key unchanged (REQ-128 deliberately keeps the realm name "bpm-default" --
# see the :oidc issuer comment in config/dev.exs).
config :letflow, :oidc_claim_mapping, %{
  "bpm-default" => %{
    tenant_id_claim: "tenant_id",
    roles_claim_paths: ["realm_access.roles", "roles"],
    email_claim: "email",
    preferred_username_claim: "preferred_username",
    display_name_claim: "name"
  }
}

# ISS-1030: deterministic realm-existence double for POST /onboarding's
# idp_realm_id check (test/support/realm_probe_double.ex). dev/prod use the
# default Letflow.Oidc.RealmProbe.Httpc adapter.
config :letflow, :oidc_realm_probe, Letflow.Oidc.RealmProbeDouble

# Duplicated from config/dev.exs (this repo's config files don't cascade —
# see the :oidc key's comment above for the same note). Per-realm JIT
# user-provisioning configuration for Letflow.Identity.provision_oidc_user/3,
# distinct from the :oidc and :oidc_claim_mapping keys. A realm with no entry
# here falls back to Letflow.Oidc.JitProvisioningConfig.default/1.
#
# "jit-disabled-test-realm" is a REQ-021 test-only fixture entry (see
# test/specs/REQ-021.md's "JIT-disabled realm fixture" section) — the only
# way test/letflow/plugs/auth_pipeline_test.exs can exercise the
# :jit_disabled -> 403 branch without mutating this file's config at
# runtime (unsafe under async: true). Not used by any other test.
# Key unchanged (REQ-128), same reason as :oidc_claim_mapping above.
config :letflow, :oidc_jit_provisioning, %{
  "bpm-default" => %{
    enabled: true,
    default_status: :active,
    default_roles: []
  },
  "jit-disabled-test-realm" => %{
    enabled: false,
    default_status: :active,
    default_roles: []
  }
}

# Small on purpose (REQ-039): fast, deterministic exercising of the
# quota-exhausted/blocking-wait acceptance criterion against the application's
# own singleton pool. A test needing its own independent quota starts a
# separately-named Letflow.SandboxPool instance instead (design doc §4.7
# INV-SP-7) rather than mutating this global default.
config :letflow, :sandbox_pool, max_concurrent_sandboxes: 1

# REQ-155: shorter-than-production default so a test exercising the 2-arity
# execute_with_manifest/2 default path (rather than /3's explicit :timeout_ms) does
# not wait out the full production default on a timeout. Tests that need a specific
# timeout value use the 3-arity overload directly rather than mutating this global.
#
# REQ-155 rework 1 (RELEASE-VALIDATOR step-05 FAIL): 200ms had no headroom under
# scripts/test_parallel.sh's 8-way parallel load and intermittently timed out
# unrelated 2-arity tests that do real (if small) Lua work -- e.g. "manifest hash
# correctness ... returns the SHA-256 of the script source on success" -- not just
# the near-zero-work mismatch-error path RELEASE-VALIDATOR originally reproduced.
# 1500ms still measured a timeout under real 8-way parallel load (elixir-dev rework
# 1, observed run), so raised further to 5000ms for real headroom against BEAM
# scheduler contention across 8 concurrent partitions. REQ-155's own timing tests
# (T1/T2/T4/T5) already pass an explicit :timeout_ms via the 3-arity overload and
# are unaffected by this default.
config :letflow, lua_wallclock_timeout_ms: 5000

# REQ-203 Step 2d rework2 (REVIEWER recheck1 FAIL item 1): compile-time kill
# switch for Letflow.Repository.Activation's test-only pause seam
# (`maybe_add_test_pause_step/4`, see that module's `@typep test_opts` doc).
# Resolved via `Application.compile_env/3` (this codebase's own established
# pattern for a test-only production seam -- see
# lib/letflow/design/req021-auth-plug-pipeline.md's OQ-5), defaulting to
# `false` everywhere this key is absent (config/dev.exs, config/prod.exs).
# Only set to `true` here, so the pause step can execute only under
# MIX_ENV=test.
config :letflow, activation_test_hooks_enabled?: true

# REQ-352 (design lib/letflow/design/req352-unauthenticated-read-platform.md
# §10): the one test-only fixture kind, registered ONLY here -- never in
# config/config.exs or config/runtime.exs, so it does not exist in any
# non-test environment. Proves Letflow.Routers.PublicRead's dispatch works
# and that an unregistered kind 404s, without naming any vertical or adding
# a real resource type. Letflow.PublicReadFixtureSupport.Projection lives
# under test/support/ (TEST-DESIGNER's fixture, per the design's §10) --
# this entry only registers the kind string against it; it is not invoked
# until a test actually issues/resolves a handle for it.
#
# TEST-DESIGNER (REQ-352 Step 3) adds a SECOND kind string here,
# "public-read-fixture-mismatch", registered against the same fixture
# projection -- solely so AC-4's kind-mismatch refusal case (design §7 case
# 5) can be exercised through a real HTTP request whose path `kind` is
# registered but differs from the handle's own stored `kind` field, rather
# than only through a direct Letflow.PublicRead.resolve/2 call. See
# test/support/public_read_fixture_support.ex's `mismatched_kind/0`.
#
# TEST-DESIGNER (REQ-357 Step 3) adds a THIRD entry, "certificate" =>
# Letflow.Exam.CertificatePublicProjection, matching config/config.exs's own
# registration. This whole map REPLACES config/config.exs's map rather than
# merging with it (plain `import Config` + `config/2` semantics), so without
# this entry "certificate" is unregistered in :test and no HTTP-level test
# could ever exercise real resolution through this kind -- ELIXIR-DEV's own
# flagged finding at REQ-357 close-out, acted on here.
config :letflow, :public_read_kinds, %{
  "public-read-fixture" => Letflow.PublicReadFixtureSupport.Projection,
  "public-read-fixture-mismatch" => Letflow.PublicReadFixtureSupport.Projection,
  "certificate" => Letflow.Modules.Exam.CertificatePublicProjection
}

# REQ-400 (design lib/letflow/design/req400-module-behaviour-catalog.md §4.3):
# the test-only fixture module, registered ONLY here -- never in
# config/config.exs (which registers [] in P1) or config/runtime.exs, so it
# does not exist in any non-test environment. Letflow.Modules.Fixture lives
# under test/support/modules/fixture/ (already compiled in :test via
# mix.exs's existing elixirc_paths(:test), no mix.exs change needed).
# REQ-401..404 prove the module mechanism (authorization wiring, persistence,
# HTTP mounting) against it; REQ-400 itself only registers it and validates
# its manifest.
#
# REQ-402 (design lib/letflow/design/req402-tenant-modules-install-context.md
# §4/§9) appends two more test-only fixtures: FixtureDependent
# (test/support/modules/fixture_dependent/, depends_on: ["fixture"], proves
# Installs.install/3's depends_on rejection) and FixtureFailingInstall
# (test/support/modules/fixture_failing_install/, on_install/2 always
# {:error, :boom}, proves Installs.install/3's AC6 whole-transaction
# rollback -- design §9 open question 1, option (a), its own recommendation).
config :letflow, :modules, [
  Letflow.Modules.Exam,
  Letflow.Modules.Fixture,
  Letflow.Modules.FixtureDependent,
  Letflow.Modules.FixtureFailingInstall
]

# REQ-439: explicit test default -- no proxy is trusted, so Letflow.Plugs.ClientIp
# never honours X-Real-IP unless a test passes :trusted_proxies as plug opts.
config :letflow, Letflow.Plugs.ClientIp, trusted_proxies: []

# REQ-437: the notifier port's test double (records calls to an owner pid and can
# raise/exit/sleep); the shipped default in config/config.exs is the Noop adapter.
config :letflow, Letflow.LoginDiscovery.Notifier,
  adapter: Letflow.LoginDiscoveryNotifierDouble,
  timeout_ms: 1_000,
  max_concurrent: 100

# REQ-441 (design s3.4): compile-time gate for the SMTP transport's TEST-ONLY trust
# override (a DER CA list replacing the OS store). Set to true here and nowhere else;
# in every other build the override branch is not compiled.
config :letflow, Letflow.LoginDiscovery.Notifier.Smtp, allow_test_cacerts: true
