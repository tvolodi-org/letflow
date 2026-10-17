import Config

config :letflow, ecto_repos: [Letflow.Repo]

# REQ-352 (design lib/letflow/design/req352-unauthenticated-read-platform.md §8):
# the unauthenticated-read kind registry -- a map of
# %{kind_string => projection_module}, read at request time via
# Application.fetch_env!/2 by Letflow.PublicRead.fetch_kind/1. config/test.exs
# adds the one test-only fixture kind on top of this.
#
# REQ-357 (design lib/letflow/design/req357-certificate-public-projection.md
# §4) registers this stage's first real kind, "certificate" --
# Letflow.Exam.CertificatePublicProjection. Do not add a further vertical
# kind here without its own design/registration entry.
config :letflow, :public_read_kinds, %{
  "certificate" => Letflow.Modules.Exam.CertificatePublicProjection
}

# REQ-154: default instruction budget for tenant-supplied Lua scripts.
# The 2-arity execute_with_manifest/2 reads this value; the 3-arity overload
# accepts :max_instructions per call and does not use this config.
config :letflow, lua_max_instructions: 100_000

# REQ-155: default host-enforced wall-clock timeout (milliseconds) for tenant-supplied
# Lua scripts (LUA-10 layer 2). No existing timeout constant in lib/letflow/ to cite as
# precedent for this specific value (design doc §11 OQ-1); chosen consistent with
# expected Letflow flow-step script latencies -- comfortably above normal script
# execution time, short enough that a hung/looping script cannot stall a workflow
# instance indefinitely. The 2-arity execute_with_manifest/2 reads this value; the
# 3-arity overload requires :timeout_ms per call and does not use this config.
config :letflow, lua_wallclock_timeout_ms: 5_000

# REQ-156: default per-process heap word limit (LUA-09 restated) for tenant-supplied
# Lua scripts. `nil` = unconstrained -- production default, since no operational data
# yet justifies a specific tuned value (design doc req156-lua-memory-limit-impl.md §10
# OQ-1, mirroring REQ-154 §11 OQ-2 / REQ-155 §11 OQ-1's identical open questions about
# their own defaults). The 2-arity execute_with_manifest/2 reads this value; the
# 3-arity overload requires :max_heap_words per call (tests always drive an explicit
# small value there, per AC-1/AC-2) and does not use this config.
config :letflow, lua_max_heap_words: nil

# REQ-152: production/dev default time source for Letflow.Engine.Lua.Platform.now/0 —
# set explicitly here (rather than relying solely on Application.get_env/3's inline
# default) so the configured implementation is legible by reading config, not only by
# reading platform.ex's source. Tests override this per-test via Application.put_env/3
# to inject an exact, pre-set timestamp.
config :letflow, :lua_platform_time_source, Letflow.Engine.Lua.Platform.SystemClock

# REQ-193: Letflow.Obs.Logger is configured as the OTP default-handler formatter
# in config/dev.exs and config/prod.exs. Neither that nor backends: [] is set here
# so ExUnit.CaptureLog keeps working in the test environment (capture_log relies on
# the standard Elixir console formatter to produce [level]-prefixed output).

# REQ-400 (docs/migration/decisions/0039-platform-module-solution-layering.md
# D4; design lib/letflow/design/req400-module-behaviour-catalog.md §5):
# the compiled list of registered platform modules, read once via
# Application.compile_env/3 by Letflow.Modules.Catalog. The first real
# module shipped in P2 is Letflow.Modules.Exam; config/test.exs appends the
# test-only fixture module on top of that list.
config :letflow, :modules, [Letflow.Modules.Exam]

# GH #2682 / REQ-511 (design lib/letflow/design/req511-exam-content-snapshot.md section 10 and
# 18.3): fail-closed gate for the exam managed-type stamp. While this is not `true`, a real
# `Letflow.Entities.ManagedTypes.Stamp` run is refused (dry runs are not). Set ONLY here (`false`)
# and in config/test.exs (`true`); never from the environment or runtime.exs. The flip to `true`
# is a single-line diff in a later PR (b).
config :letflow, :exam_snapshot_complete, false

# REQ-439 (design lib/letflow/design/req439-trusted-proxy-client-ip.md s4): keys
# exist in every environment before config/runtime.exs overrides them from
# LETFLOW_TRUSTED_PROXIES / LETFLOW_LOGIN_DISCOVERY_ENABLED. The mount switch
# defaults to off in prod and on in dev/test; the trust list defaults to empty
# (no forwarded header is ever honoured).
config :letflow, Letflow.Plugs.ClientIp, trusted_proxies: []
config :letflow, Letflow.Routers.LoginDiscovery, enabled: config_env() != :prod

# REQ-437 (design lib/letflow/design/req434-email-first-login-directory.md s7, s13,
# D21): login-discovery disclosure mode and body bound live under a key DISTINCT from
# the mount switch above (REQ-439's runtime-config test asserts the whole
# Letflow.Routers.LoginDiscovery env is exactly [enabled: boolean]). The optional env
# LETFLOW_LOGIN_DISCOVERY_MODE overrides `mode` in config/runtime.exs. The notifier
# adapter key is the one REQ-441 (mail adapter) and REQ-444 (enablement gate) read.
config :letflow, Letflow.LoginDiscovery, mode: :redirect_single, max_body_bytes: 2048

# ISS-0993 / ISS-0994 (design lib/letflow/design/iss0993-platform-scope-separation.md
# section 3): the single configuration-pinned platform tenant id. nil in every
# environment (test included) = nobody holds platform scope (fail closed).
# config/runtime.exs fills it from the optional LETFLOW_PLATFORM_TENANT_ID.
config :letflow, Letflow.PlatformTenant, tenant_id: nil

config :letflow, Letflow.LoginDiscovery.Notifier,
  adapter: Letflow.LoginDiscovery.Notifier.Noop,
  timeout_ms: 5_000,
  max_concurrent: 100

# REQ-441: LETFLOW_MAIL_ADAPTER=smtp (config/runtime.exs) switches `adapter:` to
# Letflow.LoginDiscovery.Notifier.Smtp, sets `timeout_ms:` from LETFLOW_MAIL_TIMEOUT_MS
# (default 15000) and writes the non-secret settings under
# `config :letflow, Letflow.LoginDiscovery.Notifier.Smtp`. Defaults here are unchanged.

# GH 2552 (decision 0051 M2, advisor condition 2): a token carrying PLATFORM_ADMIN minted
# over HTTP (Letflow.Identity.mint_token/4) must expire within this many days. Read at
# call time; the code default is also 90.
config :letflow, :platform_admin_token_max_ttl_days, 90

# GH 2534 PR 7c-1 (design lib/letflow/design/gh2534-7c-script-handler.md 5.1): the script
# SERVICE_TASK dispatcher, read fresh per tick. max_dispatches_per_cycle is the PER-TENANT cap
# per tick; tick_budget_ms bounds a tick (checked between rows, round-robin across tenants).
config :letflow, :script_task_dispatcher,
  poll_interval_ms: 1_000,
  tick_budget_ms: 10_000,
  max_dispatches_per_cycle: 16,
  sweep_limit: 64,
  sweep_failure_limit: 5,
  lease_margin_ms: 23_000,
  busy_retry_limit: 10,
  busy_backoff_base_ms: 500,
  busy_backoff_cap_ms: 30_000

# GH 2587 PR A3 (0054 D2, open point 8; subsumes GH 2534 PR 7c-2's :script_read_port): the one
# implementation of the engine-defined Letflow.Engine.EntityPort behaviour. It is resolved
# through Letflow.Engine.EntityPort.impl/0, so no engine file names an entity module
# (mix letflow.check_boundaries Rule 6).
config :letflow, :entity_port, Letflow.Entities.EntityPortImpl

# GH 2534 PR 7c-1 SECURITY note: the build environment, read by Letflow.Application.start/2's
# boot guard (Letflow.Scripts.Runtime.boot_check/2 refuses :scripts_test_hooks in :prod).
config :letflow, :config_env, config_env()

import_config "#{config_env()}.exs"
