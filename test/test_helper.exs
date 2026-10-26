Letflow.TenantSchemaReaper.sweep_orphans()

# ISS-0414: suite-boundary safety net against leftover `service_catalog` rows -- see
# lib/letflow/design/iss0414-service-catalog-safety-net.md and
# Letflow.TenantSchemaReaper's own moduledoc ("ISS-0414" section) for the full
# rationale. Placed at the same two boundary points sweep_orphans/0 above already
# uses, since test/test_helper.exs is the one call site every invocation shape this
# project uses (plain `mix test`, `mix test <path>`, scripts/test_parallel.sh, `mix
# letflow.check.test`) already loads.
Letflow.TenantSchemaReaper.sweep_service_catalog_orphans(Letflow.Repo)

# ISS-0941: suite-boundary safety net against orphaned "Tenant Template Build
# (throwaway)" tenant_schemas/tenants row pairs that sweep_orphans/2 detects
# (logs "malformed schema_name") but can never reclaim -- see
# lib/letflow/design/iss0941-orphan-tenant-row-reaper.md and
# Letflow.TenantSchemaReaper's own moduledoc ("ISS-0941" section) for the full
# rationale. Placed at the same two boundary points, strictly before
# ensure_template!/0 below, so this sweep can never observe this invocation's own
# in-progress template build -- only a prior invocation's leftover state.
Letflow.TenantSchemaReaper.sweep_template_build_orphans(Letflow.Repo)

# REQ-134: excludes test/letflow/integration/keycloak_auth_pipeline_test.exs
# (@moduletag :keycloak) from every default invocation -- plain `mix test`, `mix test
# <path>`, and each scripts/test_parallel.sh partition alike, since all three load this
# same test_helper.exs. Deliberate inclusion: `mix test --include keycloak
# test/letflow/integration/keycloak_auth_pipeline_test.exs`. See
# lib/letflow/design/req134-real-keycloak-token-integration.md §2.
#
# ISS-0352: excludes every test tagged `@tag :wasm_hang` (a handful of tests in
# test/letflow/engine/wasm/call_timeout_test.exs and plugin_handler_test.exs that
# deliberately, genuinely hang a real wasmex NIF call to prove REQ-170's own
# live-verified finding -- no BEAM-side mechanism can reclaim that thread once
# hung, so it permanently occupies one slot of wasmex's shared, node-global
# native worker pool for the rest of the OS process). Left in the SAME process
# as every other WASM NIF test, these tests exhausted that shared pool on a
# busy/small CI runner and cascade-failed unrelated tests in the same run
# (first observed PR #691, recurred worse on PR #692 -- 18 cascading
# ExUnit.TimeoutErrors). `mix letflow.check.test` runs these excluded tests in
# their own dedicated, short-lived `mix test --only wasm_hang` subprocess
# afterward, so their permanent leaks die with that process instead of
# starving anything else. Deliberate inclusion for a plain local run:
# `mix test --include wasm_hang test/letflow/engine/wasm/`.
#
# ISS-0426: excludes every test tagged `@tag :lua_wallclock_race` (11 tests in
# test/letflow/engine/lua/executor_test.exs, REQ-155/156/162, plus X15/X16 in
# test/letflow/scripts/form_validation_run_test.exs, REQ-581) whose assertion
# depends on which of two racing wall-clock outcomes wins -- e.g. a shorter
# configured timeout terminating measurably sooner, or a wall-clock kill firing
# before a script's own instruction budget would otherwise let it continue. Under
# scripts/test_parallel.sh's N-way partitioning, BEAM scheduler contention across
# partitions can make Task.yield(timeout_ms) (or run_with_heap_limit/5's own
# `after` clause) observe scheduler unavailability rather than actual Lua
# execution time, producing a spurious {:error, {:wallclock_timeout, _}} the test
# doesn't expect (ISS-0426). Unlike :wasm_hang, these tests don't leak anything --
# they finish in milliseconds, they just need to not race for scheduler time
# against 30+ concurrent siblings -- so a distinct tag name is deliberate rather
# than reusing :wasm_hang's (see lib/letflow/design/iss426-wallclock-test-contention.md
# §2.2 for why conflating the two would mislead a future reader). `mix
# letflow.check.test` runs these excluded tests in their own isolated `mix test
# --only lua_wallclock_race` subprocess, same shape as the :wasm_hang subprocess
# above. Deliberate inclusion for a plain local run: `mix test --include
# lua_wallclock_race test/letflow/engine/lua/executor_test.exs`.
ExUnit.start(exclude: [:keycloak, :wasm_hang, :lua_wallclock_race])

# ISS-0515: structural pre-build of the "tenant_template" schema, synchronous,
# BEFORE any test in this partition process can run. See
# lib/letflow/design/iss0515-tenant-template-build-race-fix.md for the full
# rationale -- summary: ExUnit.start/1 above only REGISTERS the eventual test
# run via System.at_exit/1; it does not dispatch a single test inline. That
# means this call, placed anywhere in this file, is guaranteed to complete
# before any test process exists, so no test process can ever race another to
# be the first caller of `ensure_template!/0` within this partition again --
# the ONLY concurrent caller of its advisory-lock acquisition is now this one,
# uncontested, one-time call. This removes the race's own precondition (2+
# concurrent first-callers within one scripts/test_parallel.sh partition)
# rather than widening its timing margin (design §3's rejection of a bigger
# lock-acquisition timeout as the fix). Unconditional -- not gated behind any
# "does this run touch a tenant fixture" heuristic (design §7) -- EXCEPT for
# the one narrow, explicitly-flagged escape hatch immediately below.
#
# ISS-0515, fourth rework (2026-09-06): `LETFLOW_SKIP_TENANT_TEMPLATE_PREBUILD`
# skips this call when set. This is NOT a general opt-out (design §7's
# "unconditional" reasoning above still holds for every real invocation shape
# this project uses) -- it exists solely for one self-verifying nested
# subprocess: test/letflow/engine/lua/executor_test.exs's ISS-0426 self-check,
# which spawns `mix test --only lua_wallclock_race ...` via `System.cmd/3` and
# sets this env var on that one call only (see that test's own comment).
# That subprocess's 11 dispatched tests are, by this test module's own
# moduledoc, guaranteed DB-access-free and have no tenant-fixture dependency
# for `ensure_template!/0` to protect -- and the tenant_template schema this
# call would build was, in any case, already built moments earlier by the
# ENCLOSING partition's own test_helper.exs run (the nested subprocess only
# re-attempts it because its own fresh BEAM VM's `:persistent_term` cache is
# empty, not because the template is actually missing). Four consecutive CI
# failures (PR #1033, all identical DBConnection.ConnectionError signatures)
# were traced to this one call opening real Postgres connections inside that
# nested subprocess and contending for an already-scarce budget -- see
# docs/migration/decisions/0009-test-parallel-pool-sizing.md's fourth
# addendum for the full evidence, including the live CI Postgres logs
# confirming a prior attempt to raise the server-side connection ceiling
# instead did not actually work. Skipping the call here removes the
# contention at its source rather than trying to widen the budget it
# contends over.
if System.get_env("LETFLOW_SKIP_TENANT_TEMPLATE_PREBUILD") != "1" do
  Letflow.Test.TenantTemplate.ensure_template!()
end

# ISS-0917 §1.3 (lib/letflow/design/iss0917-test-parallel-template-contention.md):
# signals this partition's own template build/ready-check as complete, for
# scripts/test_parallel.sh's Step 1.8 capped-concurrency admission control
# to poll on. Deliberately placed HERE (the call site), not inside
# `ensure_template!/0` itself -- that function's own moduledoc scopes it as
# "not referenced from `lib/`, a plain module" with no CI-signaling
# responsibility of its own; this keeps that module's public contract
# unchanged and keeps the signal entirely a test-harness-level concern.
# Only set when TEST_PARALLEL_TEMPLATE_READY_DIR is exported, i.e. only
# under scripts/test_parallel.sh -- a bare `mix test` or `mix
# letflow.check.test` single-process run (no such var) is unaffected, and
# so is the ISS-0426 nested `mix test --only lua_wallclock_race`
# subprocess (it never sets this var either).
if ready_dir = System.get_env("TEST_PARALLEL_TEMPLATE_READY_DIR") do
  partition = System.get_env("MIX_TEST_PARTITION") || "0"
  File.write!(Path.join(ready_dir, "partition-#{partition}.ready"), "")
end

ExUnit.after_suite(fn _stats ->
  Letflow.TenantSchemaReaper.sweep_orphans()
  Letflow.TenantSchemaReaper.sweep_service_catalog_orphans(Letflow.Repo)
  # ISS-0941: see the comment above the pre-ExUnit.start() call site above.
  Letflow.TenantSchemaReaper.sweep_template_build_orphans(Letflow.Repo)
end)
