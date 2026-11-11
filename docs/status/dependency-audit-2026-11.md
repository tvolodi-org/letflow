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
| Hex (`mix.lock`) | 25 advisories in 6 packages (bandit 14, jose 8, ecto 1, decimal 1, plug_crypto 1) | 14 (bandit only) | bandit: **T-1740** |
| npm, runtime (`npm audit --omit=dev`) | 3 (react-router high, react-router-dom moderate, zod high) | 1 (zod high) | zod: breaking major |
| npm, all (dev tools included) | 28 (1 low, 13 moderate, 11 high, 3 critical) | 16 (11 moderate, 2 high, 3 critical) | dev-tool majors, below |
| Flutter pub | no advisory tool exists in `dart pub` (checked `dart pub --help`); outdated list only | unchanged | majors, below |
| Base images | no known-advisory tool run (no scanner on the host, none added) | unchanged | tag review, below |

## Hex

Severity from the advisory text (EEF-CVE ids, source: hex.pm / OSV).

| Package | Locked | Advisory | Severity | Decision |
|---|---|---|---|---|
| bandit | 1.12.5 | 14 advisories (HTTP/2 flow control, request smuggling via chunk extensions, 1-byte DATA frame amplification, HPACK cookie crumbs, WebSocket fragments, ...), 9 high, 5 medium | **high** | Not touched here: T-1740 bumps it (1.14.1 is the latest). Listed as done there. |
| ecto | 3.14.1 | EEF-CVE-2026-118391 unbounded query cache growth from interpolated JSON paths and splice lists | high | **Not bumped**: 3.14.3 makes every `:all` query emit `WHERE (TRUE)`, which fails `Letflow.Entities.QueryScopeTest` (T-C1 and T-C5, pre-change SQL equality). Needs its own task: adapt the query-scope pins or the compile, then bump. |
| jose | 1.11.12 | EEF-CVE-2026-65625..65632 (8, one high: 65629) | high | Bumped to 1.11.13 (patch). |
| decimal | 3.1.1 | EEF-CVE-2026-97853 unbounded allocation in `Decimal.round/3` (places argument) | medium | Bumped to 3.2.0 (minor). |
| plug_crypto | 2.2.0 | EEF-CVE-2026-105963 secret key base exposed in stack-trace arguments on wrong-typed arguments | medium | Bumped to 2.2.1 (patch). |
| pdf | 0.8.2 | none | - | Bumped to 0.8.3 (patch, outdated only). |

`mix hex.audit` after the bumps lists 14 advisories, all bandit.

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
| vitest, @vitest/coverage-v8, tinypool, @vitest/mocker, vite-node | critical (Vitest UI server file read/exec; tinypool prototype pollution to RCE) | dev | Test runner only. Exploitable only while the Vitest UI server listens, which CI and the scripts never start. Major bump (2 to 4+) with the suite. |
| vite, esbuild | high / moderate (dev-server path traversal and cross-site read) | dev | Dev server only; not in the production bundle. Major bump (5 to 8). |
| @typescript-eslint/* , minimatch, glob, test-exclude | moderate (minimatch DoS) | dev | Lint-time only. Major bump (6 to 8). |

None of the remaining dev findings reaches the shipped bundle. `npm outdated` also lists majors with no advisory:
react 18 to 19, react-intl 10 to 12, lucide-react 0.575 to 1.x, @tanstack/react-table 8 to 9,
@hookform/resolvers 5 to 7; not touched.

## Flutter (`apps/mobile`)

`dart pub` has no audit command, so there is no advisory check for pub; the report is the outdated list.
`flutter pub get` changed nothing in tracked files.

- Direct, minor/patch available: `crypto` 3.0.7 to 3.0.8, `web` 1.1.1 to 1.1.2, `sembast_web` 2.4.4+1 to 2.4.7. Not bumped:
  the mobile suite was not run in this step and the sign-in/crypto code deserves a mobile build around it. Follow-up,
  low risk.
- Direct, major: flutter_appauth 12 to 13, flutter_riverpod 2 to 3, go_router 17 to 18, record 6 to 7, sembast 3.8 to 3.10.
  Not safe without a task each (appauth carries the sign-in; riverpod 3 changes the provider API).
- 34 transitive packages have newer versions outside the constraints; the 4 that are only locked low
  (`jni`, `jni_flutter`, `vm_service`, ...) move with `flutter pub upgrade`, not done here.

## Base images and CI images (read from the repo files)

| Where | Image | Note |
|---|---|---|
| `deploy/Dockerfile` builder | `elixir:1.20.3-otp-29` | Matches `.tool-versions`. Tag is pinned to a minor, not a digest. |
| `deploy/Dockerfile` runtime | `debian:trixie-slim` | Debian 13 stable; rebuilt on every deploy, so OS patches arrive with the next QA build; no digest pin. |
| `deploy/docker-compose.qa.yml` | `postgres:16-alpine` | Major 16 is supported upstream until 2028-11; floating minor. |
| `deploy/docker-compose.test.yml`, `docker-compose.yml` | `postgres:16` | Same major; the QA file uses the alpine variant, the others the Debian one: a difference to know, not a fault. |
| `docker-compose.yml` (local dev, not deployed) | `quay.io/keycloak/keycloak:26.2` | Pinned to 26.2; later 26.x releases exist upstream (not looked up from here). Dev only, but it is the realm template the tenants are built on: check the template against a current 26.x in an identity task. |
| `ci.yml` / `cd.yml` / others | `ubuntu-24.04` runners, service `postgres` | Runner pinned by T-1566. |
| Actions used | `actions/checkout@v4`, `cache@v4`, `setup-node@v4`, `setup-java@v4`, `upload-artifact@v4`, `erlef/setup-beam@v1`, `subosito/flutter-action@v2`, `dtolnay/rust-toolchain@stable`, `appleboy/ssh-action@v1` | All tag-pinned (movable tags), not SHA-pinned. `appleboy/ssh-action` runs with the deploy key, so it is the one worth a SHA pin. Finding, no change here (changing `cd.yml` is outside this task). |

No image vulnerability scanner (trivy, grype) is installed on the host or in CI, and none was added; image CVEs are therefore
**not audited**. To add it, the weekly workflow would need `aquasecurity/trivy-action` or a `docker scout` step; that is a new
third-party action and a decision for the operator.

## Findings, ranked

1. **high** bandit 1.12.5, 9 high and 5 medium advisories on the public HTTP listener: T-1740 (not here).
2. **high** zod 3.x in the SPA runtime: needs the zod 4 migration task.
3. **medium** `appleboy/ssh-action@v1` tag-pinned in the deploy workflow.
4. **medium** images have no CVE scanning and no digest pins.
5. **low/dev** vitest/vite/eslint chain: critical on paper, not reachable in CI; one major-upgrade task for the toolchain.
6. **info** ueberauth_oidcc 0.5, wasmex 0.16, flutter_appauth 13 and riverpod 3 majors; Keycloak 26.2 dev image.

## Weekly workflow

`.github/workflows/dependency-audit.yml`: `schedule` (Mondays) and `workflow_dispatch` only; `permissions: contents: read`;
no secrets; every audit step `continue-on-error`; steps: `mix hex.audit` and `hex.outdated`, `npm audit` (runtime and all) and
`outdated`, `flutter pub outdated`, a grep of image lines; output goes to `$GITHUB_STEP_SUMMARY` (each file in a
collapsible block, 20 KB each) and the artifact `dependency-audit` (30 days). It is not in the merge ruleset and runs only
on the default branch's schedule, so the first scheduled run proves it; `workflow_dispatch` runs it on demand.
Pinned by `test/letflow/dependency_audit_workflow_test.exs`.
