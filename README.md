# Letflow

Letflow is an Elixir/OTP multi-tenant BPM platform. The name plays on
the double meaning of "let it flow" — a workflow engine, and one meant
to run itself via AI agents rather than needing a human to drive each
step. Letflow began as a full, staged migration of a predecessor
system, [R-Co](../R-Co) (Robotized Company); that migration is now
essentially complete (see "Migration status" below), and R-Co's design
and source now serve as historical provenance for why Letflow behaves
the way it does, not as the reason to keep building it that way.

> The project directory on disk is still `ro-co` (a live session had
> it open and couldn't rename it); the code, mix app, and modules are
> all `Letflow` / `:letflow`. Rename the folder to `letflow` when
> convenient — nothing inside depends on the directory name.

## Migration status

The R-Co migration that originally shaped this project is effectively
complete — the large majority of `docs/requirements.yaml`'s
requirements are `status: done`, with only a small pending tail and a
handful formally cancelled. `docs/migration/` is retained as the
historical build record: it explains why Letflow's stages (S0–S9) and
much of its design look the way they do, including the R-Co source
paths each stage ported from, but it is documentation of how Letflow
was built, not live instructions for how it should be shaped from
here. `docs/requirements.yaml`'s `stages:` list and
`docs/migration/README.md` have the full breakdown. This section
intentionally doesn't restate a snapshot count here, since that's
exactly the kind of number that goes stale (see `ISS-0022`) — check
`docs/requirements.yaml` for the next `pending` requirement before
starting unscoped work, same as always.

## The frontend and the mobile tier

As of 2026-08-21 this repository also holds **`web/`** — Letflow's React
18 + TypeScript + Vite SPA, migrated out of R-Co along with its
specification (`docs/frontend/`). Letflow owns it; it is no longer
"R-Co's frontend that we point at our API." See
[`web/README.md`](web/README.md) for how to run it, what was and wasn't
carried over, and the drift it arrived with, and
`docs/migration/decisions/0011-frontend-ownership.md` for why. It
type-checks, lints, and passes 178 unit + 47 guard tests on its own; it
does **not** yet work end-to-end against Letflow, because the API
surface it needs (S4) is still being built. That integration is S8.
`npm run check` (run from `web/`) is the frontend's counterpart to
`mix letflow.check` below — type-check, lint, test, and guards in that
order, fail-fast (REQ-115); see `web/README.md`'s script table. Not yet
wired into CI (no `.github/workflows/` exists in this repository yet —
that's REQ-138).

The same migration brought over the **mobile tier specification**
(`docs/mobile/`) as stage S9 — a Flutter app that is a generic
interpreter of server-delivered definitions, on the same principle as
the SPA. `apps/mobile/` now exists: `REQ-419` (MOB-1) scaffolded it,
`REQ-420` wired a path-filtered Mobile gate into CI, `REQ-421`
(MOB-2) added tenant bootstrap — slug/deep-link →
unauthenticated `GET /api/mobile/tenant-config` → OIDC Auth-Code+PKCE
in the system browser → secure token store → memberships and installed
modules, with four dedicated error screens — and `REQ-422` (MOB-5)
added on-device security hardening: secure-storage-only tokens, log
redaction, Android cleartext/backup lockdown, an app-level transport
check ahead of any socket, a static iOS ATS check, tenant-scoped token
audience, and a masked-reveal-once secrets widget. Certificate pinning
and root/jailbreak detection remain required-before-corporate-tier and
are explicitly not implemented in v1 (`docs/mobile/architecture.md`
§7). `REQ-423` (MOB-3 part 1) added a per-tenant local definition
cache keyed by `(type, id, version)`, background delta sync against
`GET /api/v1/definitions/delta` (persisting the server's opaque
cursor, never a client-derived timestamp), archived-status removal,
and airplane-mode launch straight from cache onto a minimal tenant
home screen listing the cached definitions — the attachment point for
the renderers `REQ-426..428` build later. `REQ-424` (MOB-3 part 2)
added pinned form version resolution: a dedicated Sembast-backed
`PinnedFormCacheRepository` (a separate store from `REQ-423`'s
definition cache, since `form_version` is a string key, not an int)
and a `PinnedFormResolver` that resolves a task's exact
`{form_id, form_version}` from cache or a single
`GET /api/v1/tasks/:id` fetch on a miss — never an active/latest-
version lookup — falling back to an explicit pinned-version-
unavailable result when offline or when `form_version` is null.
Wired into `navigation_bootstrap.dart`'s four existing tenant-
partition lifecycle points, additive only. `REQ-425` (MOB-6) hardened
`lib/api/api_client.dart` into the single sanctioned API client:
bearer attach, exactly-one silent refresh on 401 then retry with
concurrent-401 coalescing, exponential backoff on 5xx for idempotent
GETs only (POST is never auto-retried), a 9-variant sealed `ApiError`
type — including a 404 on `/api/v1/modules/<id>/` distinguished as
module-not-available rather than a plain not-found, and a 429 carrying
its `Retry-After` seconds as backpressure — and a static single-client
guard (`apps/mobile/test/guards/`) rejecting any file outside
`lib/api/` that imports `package:dio`/`package:http` or uses
`dart:io`'s `HttpClient`, the mobile counterpart of the SPA's
raw-fetch-outside-client guard. `REQ-426` (MOB-4 part 1) added the
shared renderer state framework — the six mandatory states (loading,
fetch-failure, permission-denied, stale-version, validation-error,
429-backpressure with a live retry-after countdown) every renderer
under `lib/renderers/` wraps itself in — and the first renderer built
on it, the list renderer, querying entity records via
`POST /api/v1/entities/query` with filters and keyset pagination on
`next_cursor`. `REQ-294` (0020 D1a step 12) added a Dart evaluator for
the `Letflow.Engine.Expr` grammar under `apps/mobile/lib/expr/`,
passing the same conformance corpus REQ-289 pins and REQ-293's
TypeScript evaluator already passes — the third of the three
implementations record 0020 D1a's argument requires. It powers
`computed` and `visible_when` evaluation against cached form data with
no server reachable, the offline-population case that motivated D1a;
it does not make forms submittable offline (MOB-8 is unchanged) and
does not extend the grammar itself. `REQ-427` (MOB-4 part 2) replaced
the form renderer placeholder with the real renderer, composing
REQ-294's evaluator and REQ-426's six-state wrapper over the SPA's
actual 7-type field union (`text, number, boolean, date, select,
computed, hidden`) plus one mobile-only addition, `file`; see
[`docs/mobile/requirements.md`](docs/mobile/requirements.md)'s MOB-4
entry for the full reconciliation against MOB-4's original,
now-corrected eleven-name list. S9's three backend gaps
closed earlier (`REQ-124`/`125`/`126`) and
`REQ-418` added the mobile tier's own PKCE-S256 Keycloak client
(`letflow-mobile`) plus its `client_id` on
`GET /api/mobile/tenant-config` — see
[`docs/migration/stage-9-mobile.md`](docs/migration/stage-9-mobile.md)
for the current gap/progress table.

## What's here today

The original pilot slice (`Letflow.ProcessInstance`, a hand-rolled
4-state `:gen_statem` workflow, plus a second parallel-approval state
machine) was retired as of REQ-046 — superseded by the real,
definition-driven instance engine landing across Stage 3
(`Letflow.Engine.create/2`; see `docs/migration/stage-3-instance-engine.md`).
`Letflow.Router` (Plug + Bandit, no Phoenix — see
`docs/migration/decisions/0001-web-framework.md`) serves `GET /health`,
the unauthenticated `GET /api/tenant-config` (REQ-078, web-SPA
login-bootstrap) and `GET /api/mobile/tenant-config` (REQ-124, the
MOB-2 mobile-tier bootstrap gate — see `docs/mobile/build-order.md`
phase M-0), plus `Letflow.Plugs.Cors` (REQ-118) mounted ahead of all of
them; see `Letflow.Router`'s own moduledoc for the full route table.
The real tenant-scoped instance-management HTTP API is deferred to S4
(api-surface) and will be built against `Letflow.Engine.create/2`, not
a revival of the old pilot contract's three routes. `Letflow.InstanceSupervisor`
is retained, with `start_instance/1` removed, reserved for REQ-056/057.

Check `docs/requirements.yaml` for the current per-requirement status
of the Stage 3 engine build-out.

## Running it

```
docker compose up -d
mix deps.get
LETFLOW_DEV_DB_CONFIRMED=1 mix ecto.setup
LETFLOW_DEV_DB_CONFIRMED=1 mix run --no-halt
```

`LETFLOW_DEV_DB_CONFIRMED=1` is required for anything that connects to
`letflow_dev` — see `Letflow.Repo.init/2`. Unlike the test database
(isolated per workspace via `MIX_TEST_PARTITION`), `letflow_dev` is a
single database shared across every concurrent workspace/host in this
project's multi-workspace setup; the confirmation requirement exists so a
bare/accidental `mix ecto.migrate` or `mix run` from one workspace can't
silently write to state another workspace is relying on. For
throwaway/scratch verification (provisioning a tenant, checking a
migration by hand), use the already-isolated test database instead:
`MIX_ENV=test MIX_TEST_PARTITION=<N> mix ecto.migrate` /
`MIX_ENV=test MIX_TEST_PARTITION=<N> mix run -e '...'`.

```
LETFLOW_DEV_DB_CONFIRMED=1 mix letflow.seed
```

Provisions the `bpm-default` tenant (slug and `idp_realm_id` both
`bpm-default`) that authenticated requests bearing a
`bpm-default`-realm token resolve against
(`Letflow.Identity.resolve_tenant_by_realm/1`, used by `AuthPipeline`'s
tenant-resolution step). Required once per fresh `letflow_dev`
database (a fresh `docker compose up -d` volume, or after a `mix
ecto.reset`); safe to re-run.

```
curl -s localhost:4000/health
# {"sha": null, "status": "ok"}   (sha = the git commit baked into a Docker image, GH #2384)
```

This is the only working HTTP endpoint today — see "What's here today"
above. Any other path currently 404s, as an RFC 9457 problem document
(`Content-Type: application/problem+json`) rather than an ad-hoc error
body; the real instance-management API lands in S4.

```
curl -s -i localhost:4000/nope
# HTTP/1.1 404 Not Found
# content-type: application/problem+json
# {"type":"https://bpm.example.com/problems/not-found","title":"Not Found",
#  "status":404,"detail":"the requested resource was not found","trace_id":""}
```

Every error body in the application goes through the one
`Letflow.Api.Error`/`Letflow.Api.Response` contract (REQ-066); the
`type` base URI is configurable via `config :letflow, :problems_base_uri`.

```
mix test
```

`mix test`/`scripts/test_parallel.sh` exclude one deliberately-tagged suite by default:
`test/letflow/integration/keycloak_auth_pipeline_test.exs` (`@moduletag :keycloak`)
drives a genuine token from the running Keycloak through `Letflow.Plugs.AuthPipeline`
end to end (REQ-134) and needs `docker compose up -d keycloak` first. Run it
deliberately with:

```
mix test --include keycloak test/letflow/integration/keycloak_auth_pipeline_test.exs
```

To run format-check + compile-with-warnings-as-errors + test as a
single fail-fast gate (equivalent to R-Co's `zig build check`):

```
mix letflow.check
```

`mix letflow.check` runs clean end-to-end as of 2026-08-17 (ISS-0012). Two
prior caveats recorded here no longer apply: the formatting failure
(`ISS-0008`) was resolved 2026-08-15, and a since-fixed test-isolation flake
in `test/letflow/plugs/tenant_status_test.exs` (`ISS-0011`, a global
`:telemetry.attach` racing other concurrently running `async: true` tests)
could occasionally fail an unrelated run — both are `status: resolved`, and
running the full suite four times in a row while verifying this note showed
zero flakes.

To also capture compile/test timing, run the suite via the timing
script instead — it appends one row to `docs/eval/dev-loop-timings.csv`
per run:

```
sh scripts/timed_test.sh
```

This is a plain shell script, not a `mix` task, on purpose — see the
comment at the top of `scripts/timed_test.sh` for why a `mix`-prefixed
command structurally can't time this project's own compile step.

To run the suite across parallel OS processes instead (Elixir's native
`mix test --partitions N`, one `Repo` pool per process — much faster
than the single-process `mix test` above on multi-core hosts):

```
sh scripts/test_parallel.sh
```

`N` defaults to `nproc` (override with `TEST_PARALLEL_N`). If the
`nproc`-derived `N` exceeds this host's Postgres/CPU capacity, every
partition can crash outright during `ecto.create`/`ecto.migrate`
before any test result is produced (ISS-0219) — if that happens, set
`TEST_PARALLEL_N` explicitly to a smaller value (`4` is known-good on
at least one dev host) rather than assuming a code regression. The
script
pre-compiles `MIX_ENV=test` exactly once before launching any
partition, then aggregates each partition's own reported pass/fail
counts into one combined total and exits non-zero if any partition
failed. This is now the full-suite mechanism `TEST-RUNNER` and
`RELEASE-VALIDATOR` invoke in their own workflow steps (REQ-114),
replacing the plain `mix test` full-suite invocations they used
before.

Postgres runs on port 5462 by default, not 5432 — R-Co's own
docker-compose already uses 5432 (dev) and 5433 (test), so this can run
alongside it without colliding.

That default is per-workspace, not fixed. This repo is routinely checked
out into more than one workspace at a time (`letflow`, `letflow-2`, plus
git worktrees), each running its own `docker compose up`; a hardcoded
host port makes the second one fail to bind (or, worse, silently come up
with no port mapping at all — see `docs/anti-patterns.md`). To give a
workspace its own PostgreSQL instance, create an untracked `.env` at the
project root:

```
LETFLOW_DB_PORT=5472
```

Both `docker-compose.yml` (host-port mapping) and `config/dev.exs` /
`config/test.exs` (via `config/db_port.exs`) read that one file, so the
container and Ecto can't drift apart. An environment variable of the same
name takes precedence over `.env`; with neither set, the port is 5462 and
behaviour is unchanged. `.env` is gitignored on purpose — the port is
local state of a checkout, not of the project.

### After a reboot

After a reboot: `docker ps`; start the workspace DB containers; check ports
5462 / 5472 / 5482.

The `postgres` service sets `restart: unless-stopped`, so containers created
from this file come back on their own. A container created before that key
existed keeps `RestartPolicy=no` until it is changed. Either recreate it from
its own checkout (`docker compose up -d postgres`; the named volume keeps the
data) or update the policy in place, per container:

```
docker update --restart unless-stopped letflow-postgres-1
docker update --restart unless-stopped letflow-3-postgres-1
docker update --restart unless-stopped letflow-wt1012-postgres-1
```

Only run these for containers of your own workspace.

## QA deployment

A live QA instance runs at [https://qa.bizdala.com](https://qa.bizdala.com)
(host `ubuntu-16gb-nbg1-1`, deploy infra tracked in the sibling
`ai-dala-infra` repo — see that repo's `shared/app-registry.md` "Letflow"
section for the full deploy detail). Sign in via the login screen, which
redirects to a real Keycloak instance at
[https://auth.qa.bizdala.com](https://auth.qa.bizdala.com), realm
`bpm-default`.

Four seeded test users are available, one per role (matching
`priv/keycloak/realms/bpm-default.json`'s fixture — see
[decision 0013](docs/migration/decisions/0013-authorization-role-set.md)
for why `operator-user` holds `PROCESS_OPERATOR`, not `PLATFORM_ADMIN`):

| Username | Role |
|---|---|
| `admin-user` | `PLATFORM_ADMIN` |
| `designer-user` | `PROCESS_DESIGNER` |
| `operator-user` | `PROCESS_OPERATOR` |
| `worker-user` | `TASK_WORKER` |

**Passwords are not in this file, or in any committed file** — per this
project's secrets convention, they're host-only. If you have SSH access to
`ubuntu-16gb-nbg1-1`, fetch one on demand (prints to your terminal, never
written to a local file):

```powershell
# Windows / PowerShell
ai-dala-infra\scripts\qa-login.ps1 operator-user
```

```bash
# macOS / Linux / Git Bash / WSL
ai-dala-infra/scripts/qa-login.sh operator-user
```

Values live at `/opt/apps/letflow-qa-keycloak/deploy/seeded-users.env` on
that host (mode 600); the secret *names* (not values) are recorded in
`ai-dala-infra/landscape/secrets-inventory.md`
(`letflow-qa-keycloak-user-<username>-password`).

## Notes

- Elixir 1.20.3 / OTP 29 is the pinned toolchain for this repo (see
  `docs/migration/decisions/0005-pin-formatting-toolchain.md`) — install
  it via `asdf install` after `asdf plugin add elixir` /
  `asdf plugin add erlang` if you don't already have those plugins; the
  root `.tool-versions` file selects the exact version automatically on
  `cd` into this repo. `mix.exs`'s `elixir: "~> 1.18"` requirement is a
  compile-time backstop only, and it is deliberately **wider** than the
  pin: `~> 1.18` means `>= 1.18.0 and < 2.0.0`, so it admits 1.19, 1.20
  and 1.21. That width is the point — an off-pin host is *warned, never
  blocked*: it still compiles, still runs the full gate, and still gets
  an exit code that reflects the code rather than the toolchain.
  Narrowing this line is not a consistency cleanup and needs REVIEWER
  sign-off. Because the requirement can't catch formatter drift on its
  own, `mix letflow.check` now runs `letflow.check_toolchain` as its
  first step, which warns on stderr when the running Elixir/OTP differs
  from `.tool-versions`. That warning is advisory: it never changes an
  exit code. Running `mix format` (and `mix letflow.check`) under the
  `.tool-versions`-selected toolchain is what actually keeps formatting
  deterministic across hosts.
- `mix deps.get` needs network access to hex.pm, which this sandbox
  doesn't have — dependencies are declared in `mix.exs` but not
  fetched. Run it locally.
