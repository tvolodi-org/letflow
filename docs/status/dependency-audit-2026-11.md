# Dependency audit, 2026-11-11 (T-1742)

First full audit by hand. From now on `.github/workflows/dependency-audit.yml` (weekly, Monday 05:23 UTC, report
only, not a required check, no secrets, read-only token) posts the same raw output as a job summary and as the
artifact `dependency-audit`. This file holds the triage and the decisions; the weekly run holds the raw lists.

Commands (all run from the T-1742 worktree on 2026-11-11): `mix hex.audit`, `mix hex.outdated --all`,
`cd web && npm audit [--omit=dev]`, `npm outdated`, `cd apps/mobile && flutter pub outdated`, and a read of
`deploy/*`, `docker-compose.yml` and `.github/workflows/*.yml`. No host was logged into; QA/demo configuration was read
from the repo files only (D-117: nothing here is promoted to demo or production; the fixes go through QA/CD).

## Summary

| Area | Before | After this change | Left |
|---|---|---|---|
| Hex (`mix.lock`) | 25 advisories in 5 packages (bandit 14, jose 8, ecto 1, decimal 1, plug_crypto 1) | 15 on this branch's lock before T-1740 (bandit 14, ecto 1); bandit is fixed by T-1740 (lock now has 1.14.1) | ecto: needs its own task; bandit: **done in T-1740, not here** |
| npm, runtime (`npm audit --omit=dev`) | 3 (react-router high, react-router-dom moderate, zod high) | 1 (zod high) | zod: breaking major |
| npm, all (dev tools included) | 28 (1 low, 13 moderate, 11 high, 3 critical) | 16 (11 moderate, 2 high, 3 critical) | dev-tool majors, below |
| Flutter pub | no advisory tool exists in `dart pub` (checked `dart pub --help`); outdated list only | unchanged | majors, below |
| Base images | no known-advisory tool run (no scanner on the host, none added) | unchanged | tag review, below |

## Hex

Severity from the advisory text (EEF-CVE ids, source: hex.pm / OSV).

| Package | Locked | Advisory | Severity | Decision |
|---|---|---|---|---|
| bandit | 1.12.5 | 14 advisories (HTTP/2 flow control, request smuggling via chunk extensions, 1-byte DATA frame amplification, HPACK cookie crumbs, WebSocket fragments, ...), 11 high, 3 medium (counted from `mix hex.audit` output) | **high** | **Resolved by T-1740** (lock has 1.14.1), not by this change. Listed here for the record. |
| ecto | 3.14.1 | EEF-CVE-2026-118391 unbounded query cache growth from interpolated JSON paths and splice lists | high | **Bumped to 3.14.3 (T-1795).** 3.14.3 emits `WHERE (TRUE)` for an interpolated `dynamic(true)`; `Letflow.Entities.Query.Compiler` now adds no `where` when a request has no filter clauses, so the committed pre-change SQL pins (`QueryScopeTest` T-C1, T-C5) hold unchanged. ecto_sql 3.14.0 and postgrex 0.22.4 satisfy the constraints unchanged; no migration changed. `mix hex.audit`: no advisory packages. |
| jose | 1.11.12 | EEF-CVE-2026-65625..65632 (8, one high: 65629) | high | Bumped to 1.11.13 (patch). |
| decimal | 3.1.1 | EEF-CVE-2026-97853 unbounded allocation in `Decimal.round/3` (places argument) | medium | Bumped to 3.2.0 (minor). |
| plug_crypto | 2.2.0 | EEF-CVE-2026-105963 secret key base exposed in stack-trace arguments on wrong-typed arguments | medium | Bumped to 2.2.1 (patch). |
| pdf | 0.8.2 | none | - | Bumped to 0.8.3 (patch, outdated only). |

`mix hex.audit` on this branch's own bumps (before T-1740's bandit bump) listed 15 advisories: 14 bandit (since fixed by T-1740) and 1 ecto. **Remaining after both: ecto EEF-CVE-2026-118391 (high), which needs the separate task above.**

Not bumped (outdated, no advisory):

| Package | Locked | Latest | Why not |
|---|---|---|---|
| ueberauth_oidcc | 0.4.2 | 0.5.0 | 0.x minor is a breaking release for the sign-in path; needs its own task and the identity decisions read first. |
| wasmex | 0.15.1 | 0.16.0 | "Update not possible" under the current `mix.exs` requirement; runtime of the sandbox (INV-3), needs a reviewed change. |
| stream_data (test) | 0.6.0 | 1.4.0 | Requirement blocks it; test-only, low value. |

Tests run after the Hex bumps: 1417 passed, 0 failed in the files that reference JOSE, `Decimal.round`, Plug session or
crypto, plus all of `test/letflow/engine`; 40 passed in the print/PDF tests; `mix compile --warnings-as-errors` clean.
The full suite is the CI gate and was not run locally.

## npm (`web/`)

`npm audit fix` (semver-compatible only, no `--force`) changed `web/package-lock.json` only: react-router and
react-router-dom to 7.18.x, and the transitive fixes (@babel/core, brace-expansion, browserslist, form-data, js-yaml,
nanoid, postcss, source-map-js, ws, baseline-browser-mapping). Router tests run after it: 4 files, 39 passed. The
`npm run check` gate is the engine's and CI's.

What remains, all needing a major bump (`package.json` ranges: zod ^3, vite ^5, vitest ^2, @typescript-eslint 6):

| Package | Severity | Runtime or dev | Why it stays |
|---|---|---|---|
| zod (direct, ^3.22.4) | high: memory exhaustion validating oversized constrained collections | **runtime** | Fix is in zod 4.x, a major API change across every schema; needs its own task. Exposure: the SPA validates data it received from the Letflow API and user form input, so the practical risk is a hostile oversized payload making the user's own tab slow; no server side. **First candidate for a follow-up.** |
| vitest, @vitest/coverage-v8, tinypool, @vitest/mocker, vite-node | critical (vitest; tinypool prototype pollution gadget in worker/`run()` options leading to RCE, GHSA-5gmw-xhrv-c9v3, GHSA-85c8-ppgw-ccpr) | dev | Test runner only, never in the shipped bundle. The Tinypool advisory is **not** tied to the UI server: it needs an attacker to be able to pollute `Object.prototype` inside the test process (for example through a malicious dependency or a test input that reaches a vulnerable merge) and then have a worker started. We did not analyse whether our tests or dependencies offer such a pollution path, so this is **not** shown unreachable. Exposure is the developer and CI machines running tests. The vitest UI-server file read/exec advisory does need the UI server (`--ui`), which no script or CI step starts. Fix: major bump (2 to 4+/5) with the suite, as one toolchain-upgrade task. |
| vite, esbuild | high / moderate (dev-server path traversal and cross-site read) | dev | Dev server only; not in the production bundle. Major bump (5 to 8). |
| @typescript-eslint/* , minimatch, glob, test-exclude | moderate (minimatch DoS) | dev | Lint-time only. Major bump (6 to 8). |

None of the remaining dev findings is in the shipped bundle (they affect developer and CI machines). `npm outdated` also lists majors with no advisory:
react 18 to 19, react-intl 10 to 12, lucide-react 0.575 to 1.x, @tanstack/react-table 8 to 9,
@hookform/resolvers 5 to 7; not touched.

## Flutter (`apps/mobile`)

`dart pub` has no audit command, so there is no advisory check for pub; the report is the outdated list.
`flutter pub get` changed nothing in tracked files.

- Direct, minor/patch available: `crypto` 3.0.7 to 3.0.8, `web` 1.1.1 to 1.1.2, `sembast` 3.8.7 to 3.10.1 (a minor within 3.x; pub shows it as not resolvable under the current constraints), `sembast_web` 2.4.4+1 to 2.4.7. Not bumped:
  the mobile suite was not run in this step and the sign-in/crypto code deserves a mobile build around it. Follow-up,
  low risk.
- Direct, major: flutter_appauth 12 to 13, flutter_riverpod 2 to 3, go_router 17 to 18, record 6 to 7.
  Not safe without a task each (appauth carries the sign-in; riverpod 3 changes the provider API).
- 26 transitive packages have a newer Latest (23 transitive, 3 transitive dev); most are held back by the direct constraints. The
  4 that pub reports as locked lower than upgradable are `crypto` (direct), `jni`, `jni_flutter` and `vm_service`; they move
  with `flutter pub upgrade`, not done here.

## Base images and CI images (read from the repo files)

| Where | Image | Note |
|---|---|---|
| `deploy/Dockerfile` builder | `elixir:1.20.3-otp-29` | Matches `.tool-versions`. Tag is pinned to a minor, not a digest. |
| `deploy/Dockerfile` runtime | `debian:trixie-slim` | Debian 13 stable; no digest pin. **Patch-refresh gap:** `deploy/redeploy-qa.sh` builds without `--pull` and `deploy/Dockerfile` keeps the cached `apt-get update/install` layer, so a rebuild can reuse an outdated base image and outdated installed packages; OS patches are not guaranteed to arrive with the next QA build. No change made here (audit only). |
| `deploy/docker-compose.qa.yml` | `postgres:16-alpine` | Major 16 is supported upstream until 2028-11; floating minor. |
| `deploy/docker-compose.test.yml`, `docker-compose.yml` | `postgres:16` | Same major; the QA file uses the alpine variant, the others the Debian one: a difference to know, not a fault. |
| `docker-compose.yml` (local dev, not deployed) | `quay.io/keycloak/keycloak:26.2` | Pinned to 26.2; later 26.x releases exist upstream (not looked up from here). Dev only, but it is the realm template the tenants are built on: check the template against a current 26.x in an identity task. |
| `ci.yml` / `cd.yml` / others | `ubuntu-24.04` runners, service `postgres` | Runner pinned by T-1566. |
| Actions used | `actions/checkout@v4`, `cache@v4`, `setup-node@v4`, `setup-java@v4`, `upload-artifact@v4`, `erlef/setup-beam@v1`, `subosito/flutter-action@v2`, `dtolnay/rust-toolchain@stable`, `appleboy/ssh-action@v1` | All tag-pinned (movable tags), not SHA-pinned. `appleboy/ssh-action` runs with the deploy key, so it is the one worth a SHA pin. Finding, no change here (changing `cd.yml` is outside this task). |

No image vulnerability scanner (trivy, grype) is installed on the host or in CI, and none was added; image CVEs are therefore
**not audited**. To add it, the weekly workflow would need `aquasecurity/trivy-action` or a `docker scout` step; that is a new
third-party action and a decision for the operator.

## Findings, ranked

1. ~~ecto 3.14.1 (EEF-CVE-2026-118391)~~ fixed by T-1795 (3.14.3).
1b. bandit: 14 advisories fixed by T-1740 (not by this change).
2. ~~**high** zod 3.x in the SPA runtime~~ **Resolved by T-1794**: web upgraded to zod ^4.6.7; `npm audit --omit=dev` reports 0 vulnerabilities.
3. **medium** `appleboy/ssh-action@v1` tag-pinned in the deploy workflow.
4. **medium** images have no CVE scanning and no digest pins.
5. **medium (dev/CI machines)** vitest/tinypool/vite/eslint chain: critical on paper, not in the bundle; reachability of the Tinypool pollution gadget in our tests not analysed; one major-upgrade task for the toolchain.
6. **info** ueberauth_oidcc 0.5, wasmex 0.16, flutter_appauth 13 and riverpod 3 majors; Keycloak 26.2 dev image.

## Update 2026-11-12: web toolchain upgrade (T-1805, finding 5)

Done in `web/`: vitest 2 to 5.1.0, `@vitest/coverage-v8` 2 to 5, vite 5 to 8.3.8, `@vitejs/plugin-react` 4 to 6, `@typescript-eslint/*` 7 to 8
(eslint stays 8; `fast-glob`, used by two tests and formerly pulled in transitively, is now a declared devDependency). `npm audit` in
`web/` before: 15 vulnerabilities (11 moderate, 1 high, 3 critical); after: 6 moderate, all the one `minimatch` range (7.0.0 - 11.0.0)
reached through `@typescript-eslint/typescript-estree` 8.x (lint time only; the fix needs a newer typescript-eslint release, not available yet).
tinypool, vitest, vite and esbuild are no longer listed.

Reachability of the tinypool gadget (the audit's open question): superseded, not analysed. `tinypool` is no longer in the installed tree (vitest 5 does not depend on it), so no
vulnerable copy remains. Config change: vitest 5 has no `poolOptions`/`minForks`; `vite.config.ts` maps `VITEST_MAX_FORKS`
(the machine-wide cap) to `maxWorkers`. Two stock export tests clicked a button that is disabled while the refetch is pending; they now wait for it to be enabled.

## Weekly workflow

`.github/workflows/dependency-audit.yml`: `schedule` (Mondays) and `workflow_dispatch` only; `permissions: contents: read`;
no secrets; every audit step `continue-on-error`; steps: `mix hex.audit` and `hex.outdated`, `npm audit` (runtime and all) and
`outdated`, `flutter pub outdated`, a grep of image lines; output goes to `$GITHUB_STEP_SUMMARY` (each file in a
collapsible block, 20 KB each) and the artifact `dependency-audit` (30 days). It is not in the merge ruleset and runs only
on the default branch's schedule, so the first scheduled run proves it; `workflow_dispatch` runs it on demand.
Pinned by `test/letflow/dependency_audit_workflow_test.exs`.
