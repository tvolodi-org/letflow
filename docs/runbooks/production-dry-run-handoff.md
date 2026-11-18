# Production dry-run handoff for infra — stage 1

Slot: Sun 2026-11-22, 22:00–23:00 UTC (after the reboot window). Host: 2 CPU / 3 GB RAM,
loopback only, 60-minute cap. This document is for infra. It records what is known from the
repository; facts not found here are marked **UNKNOWN** with the owner of the answer.

Production is not approved. This dry run is on QA only (portfolio decision D-019,
`docs/runbooks/production-readiness.md` §Status). No DNS, no public access, no secrets
are in this file.

---

## 1. Compose shape, image tags and git SHA

**Services.** `deploy/docker-compose.qa.yml` names two services:

| Service | Image | Source |
|---------|-------|--------|
| `app` | `letflow-qa:latest` (built locally) | `deploy/Dockerfile`, two-stage: builder `elixir:1.20.3-otp-29`, runtime `debian:trixie-slim` |
| `db` | `postgres:16-alpine` | Docker Hub, pinned to the major version only |
| Keycloak | **UNKNOWN** | Keycloak is not in `deploy/docker-compose.qa.yml`; it is in the root `docker-compose.yml` as `quay.io/keycloak/keycloak:26.2` for local dev. Owner: **infra** — confirm how Keycloak is supplied for the production-shaped run (a separate compose project, a managed service, or a manual import). |

**How the image tag is chosen.** The build script `deploy/redeploy-qa.sh` builds with
`--build-arg GIT_SHA="$(git rev-parse HEAD)"`, which bakes the full 40-character commit SHA
into the image as `LETFLOW_BUILD_SHA`. The image name and rollback tag carry the UTC date
(`letflow-qa:rollback-${DATE}`), not the git SHA. To confirm the deployed commit, call
`GET /health`; the JSON body includes a `sha` field (may be a short SHA or null if the
arg was not passed).

**Example build command** (what `redeploy-qa.sh` runs):

```sh
docker build -f deploy/Dockerfile \
  --build-arg GIT_SHA="$(git rev-parse HEAD)" \
  --build-arg LETFLOW_INCLUDE_RUNTIME_DEMO=false \
  -t letflow-qa:latest .
```

The `app` service binds to `127.0.0.1:3201:4000`; `db` binds to `127.0.0.1:3202:5432`.
Both listen on loopback only — no public exposure by the compose file.

---

## 2. Environment variable names and how each value is generated

No value is shown. Every secret must be generated fresh for the dry run and discarded after.
All variables that the application reads are listed in `docs/runbooks/production-readiness.md`
§Settings; the table below names only the variables needed to boot and run the dry run, with
their generation method.

| Variable | Required to boot | How to generate the value |
|----------|-----------------|--------------------------|
| `DATABASE_URL` | yes | Standard Postgres URL: `ecto://user:password@host:port/dbname`. For the compose stack: host `db`, port `5432`, database `letflow_qa`, user and password from the `db` service's `env_file`. |
| `LETFLOW_SECRETS_MASTER_KEY` | yes (every env) | `openssl rand -hex 32` — a fresh 64 lower-hex-char string. Never reuse between environments. Keep separate from the database backup. |
| `LETFLOW_LOGIN_DIRECTORY_PEPPER` | yes (every env) | `openssl rand -hex 32` — 64 lower-hex chars, distinct from the master key. |
| `LETFLOW_LOGIN_DIRECTORY_PEPPER_ID` | yes (every env) | A short identifier string chosen by the operator (for example `v1`). |
| `OIDC_KEYCLOAK_BASE_URL` | yes in practice | The Keycloak base URL for the dry-run realm. **UNKNOWN** — owner: **infra** (depends on how Keycloak is supplied; see §1). |
| `OIDC_CLIENT_ID` | recommended | The OIDC client ID registered in the dry-run Keycloak realm. Default placeholder is set in the config; set a real one for a working sign-in test. **UNKNOWN** — owner: **infra**. |
| `LETFLOW_PLATFORM_TENANT_ID` | needed for platform-scope ops | The slug of the platform tenant provisioned in the dry-run database. **UNKNOWN** — owner: **operator**. |
| `POOL_SIZE` | no | Integer, default 30. For 2 CPU / 3 GB: set to `5`–`10` to avoid connection exhaustion. |
| `RESERVED_HEADROOM` | no | Integer, default 2. Leave at default for the dry run. |
| `PORT` | no | Default 4000 (the internal port). The compose file already maps it; leave unset. |
| `LETFLOW_MODULE_UPGRADE_ON_BOOT` | no | Set to `false` explicitly to prevent automatic tenant module upgrades at boot. Default is `false`; state it explicitly for safety. |
| `CORS_ALLOWED_ORIGINS` | no (but needed for browser access) | Comma-separated list of allowed origins. For loopback-only testing leave unset (no cross-origin caller). |
| `LOG_LEVEL` | no | Default `info`. Set to `debug` only if detailed tracing is needed; it is very verbose. |
| `LETFLOW_BUILD_SHA` | no | Set automatically via the Docker `--build-arg GIT_SHA` path in the Dockerfile; no manual set needed. |

All other variables in `docs/runbooks/production-readiness.md` §Settings can remain unset
for the dry run unless the specific feature is under test. Secrets go in the compose `env_file`
(mode 0600), never in a command line or a committed file.

---

## 3. Boot and migration sequence

The application runs only inside a compiled release (`deploy/Dockerfile` builds it with
`mix release`). `Ecto.Migrator` runs only when the `RELEASE_NAME` environment variable is set
(which the OTP release boot script exports automatically). It does not run in `mix run` or
`mix test`.

Boot sequence (from `lib/letflow/supervisor/infrastructure.ex`):

1. **`Letflow.Repo`** — connects to the database using `DATABASE_URL`.
2. **`Ecto.Migrator`** — runs all pending shared-schema (`public`) Postgres migrations.
   This is synchronous: no route is served until it completes. Idempotent; already-run
   migrations are skipped.
3. **`Letflow.TenantProvisioning.MigrationReplayBoot`** — replays tenant-scoped
   migrations against every already-provisioned tenant schema. One-shot, always returns
   `:ignore` (never fails boot).
4. **`Letflow.ModuleUpgrade.Boot`** — applies automatic (Class A) module upgrade plans
   for every tenant when `LETFLOW_MODULE_UPGRADE_ON_BOOT=true`. Default is `false`;
   set it to `false` for the dry run to avoid unintended data changes.
5. **`Letflow.Oidc.ProviderRegistry`** — connects to Keycloak for OIDC discovery.
   Boot continues if this times out; sign-in will not work.
6. Remaining infrastructure children (registry, rate limiters, sandbox pool, plugin
   engine, scheduler pollers).
7. **`Letflow.Supervisor.Http`** (Bandit) — starts accepting HTTP on port 4000.
   This is the last step; a successful `GET /health` means the full sequence is done.

**Expected boot time.** For a database with no tenants and no pending migrations:
**UNKNOWN** — owner: **operator**. Measure on the first boot with `time docker compose
up app` and record the elapsed time before `/health` answers `{"status":"ok"}`.

---

## 4. Checklist commands and pass criteria

Run each command in order. Abort the dry run if any check does not pass within the step's
timeout. All commands are on the loopback interface.

```sh
# A. Health check — pass: HTTP 200, body {"status":"ok","sha":"<40-char-hex>"}
curl -sf http://127.0.0.1:3201/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'], d.get('sha',''))"
# Expected: "ok <sha>"

# B. Migrations done — pass: no output (all migrations were run at boot)
docker compose -p letflow-dryrun exec db psql -U letflow -d letflow_qa \
  -c "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 5;"
# Expected: a table of the last 5 migration versions, no ERROR.

# C. Tenant-schema migrations replayed — pass: no "pending" rows in the shared schema
docker compose -p letflow-dryrun exec db psql -U letflow -d letflow_qa \
  -c "SELECT slug FROM tenants LIMIT 10;"
# Expected: a table (possibly empty if no tenants are provisioned yet), no ERROR.

# D. Sign-in check — requires a Keycloak realm and a registered user
# UNKNOWN — owner: infra (depends on Keycloak setup; see §1 and §2).
# Pass criterion: a valid JWT is returned from the token endpoint.

# E. One stock read — requires a provisioned tenant with the stock module installed
# UNKNOWN — owner: operator.
# Pass criterion: GET /api/v1/tenant/stock/items returns HTTP 200 (or 404 if no items).

# F. Rollback smoke test — confirm the previous image exists
docker images letflow-qa --format "{{.Tag}}" | grep rollback
# Expected: at least one "rollback-YYYYMMDD" tag.
# To roll back: docker tag letflow-qa:rollback-<DATE> letflow-qa:latest
# then docker compose -p letflow-dryrun up -d --force-recreate app
```

**Stop rule.** If any check from A through C does not pass within 5 minutes of the
`docker compose up` command, stop the dry run and record the failure (see §9).

---

## 5. Peak resource expectations

The measurements below are starting points; the operator measures the real values during
the dry run.

| Resource | Expected (dry run) | How to measure |
|----------|--------------------|----------------|
| CPU (app container) | **UNKNOWN** | `docker stats letflow-dryrun-app-1 --no-stream` during the boot migration phase and during a sign-in request |
| Memory (app container) | BEAM baseline ~200–400 MB; total heap depends on tenant count | `docker stats letflow-dryrun-app-1 --no-stream` after boot settles |
| Memory (db container) | Depends on `shared_buffers` (Postgres default for a small DB: ~128 MB) | `docker stats letflow-dryrun-db-1 --no-stream` |
| Disk (DB volume) | Depends on seed data; for a fresh empty DB: a few MB | `docker system df -v \| grep letflow` |
| Connection pool | Default 30 (`POOL_SIZE`). Reduce to 5–10 for 2 CPU / 3 GB to avoid memory pressure. | `docker compose exec db psql -U letflow -d letflow_qa -c "SELECT count(*) FROM pg_stat_activity WHERE datname='letflow_qa';"` |

A 2 CPU / 3 GB host has limited headroom. The `POOL_SIZE=5` and `RESERVED_HEADROOM=2`
settings are recommended for the dry run. Record all `docker stats` output in the operator
session log.

---

## 6. Background jobs and schedulers to disable on a dry run

The pollers below start automatically when the application boots in production. They are
controlled by **compile-time** config keys (not runtime environment variables), so they
cannot be disabled via `.env` without a new build. For the dry run, they will run.

| Job | Config key | Default | Effect on dry run |
|-----|-----------|---------|-------------------|
| `Letflow.Scheduler.Poller` | `:start_scheduler` | `true` | Runs the scheduler tick (task deadlines, scheduled jobs). Low CPU. |
| `Letflow.Engine.ServiceTaskDispatcher.Poller` | `:start_service_task_dispatcher` | `true` | Polls for service tasks. Requires webhook targets; calls will fail or no-op if none are configured. |
| `Letflow.Engine.ScriptTaskDispatcher.Poller` | `:start_script_task_dispatcher` | `true` | Polls for Lua/WASM script tasks. No-op if none are queued. |
| Record trigger worker | `:start_record_trigger_worker` | `true` | Processes record-change triggers. No-op if no triggers are configured. |
| `Letflow.TenantProvisioner.Sweep` | `:start_provisioner_sweep` | `true` | Sweeps for expired demo tenants. Set `LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES` large (e.g. `1440`) to push sweeps out of the dry-run window. |
| `Letflow.ModuleUpgrade.Boot` | `LETFLOW_MODULE_UPGRADE_ON_BOOT` (runtime) | `false` | Applies auto-upgrades at boot. **Set `LETFLOW_MODULE_UPGRADE_ON_BOOT=false` explicitly.** |

To reduce background noise without a new build, set `LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES=1440`
in the env file and `LETFLOW_MODULE_UPGRADE_ON_BOOT=false`. All other pollers will run but are
expected to have no-op ticks on an empty or synthetic dataset.

---

## 7. Teardown commands

Run teardown after the dry run regardless of success or failure.

```sh
# 1. Stop all containers (preserves the named volume for a post-run inspection)
docker compose -p letflow-dryrun -f deploy/docker-compose.qa.yml down

# 2. Remove the named volume (destroys all DB data — confirm before running)
docker volume rm letflow_qa_pg

# 3. Remove the built images (optional; free disk space)
docker rmi letflow-qa:latest
docker images letflow-qa --format "{{.Tag}}" | \
  xargs -I{} docker rmi letflow-qa:{}

# 4. Remove the env file holding secrets (mode 0600 file created for the dry run)
#    UNKNOWN — owner: operator. Confirm path and disposal method.
#    Example: shred -u /opt/apps/letflow-dryrun/.env
```

Confirm `docker volume ls | grep letflow_qa_pg` shows no entry after step 2.
Keycloak teardown: **UNKNOWN** — owner: **infra** (depends on how Keycloak was supplied; see §1).

---

## 8. Data permitted

**Synthetic data only** unless the owner explicitly says otherwise in writing before the
dry-run slot. No personal data, no production records, no customer data.

Synthetic data means:
- Tenants created with obviously fake names (e.g. `dry-run-tenant-01`).
- Users with no real names or e-mail addresses outside your own domain.
- Stock items and assets with clearly fictitious codes and descriptions.

The `LETFLOW_SECRETS_MASTER_KEY` used in the dry run must be generated fresh (see §2) and
must not be shared with any other environment. After teardown (§7), it is discarded.

If the dry run needs an imported realm or user list from a real environment:
**UNKNOWN — owner: owner**. The owner decides whether any real data may enter the dry-run
host and under what retention terms.

---

## 9. Who watches the window

**Operator session.** One operator session stays connected to the dry-run host for the full
60-minute window (22:00–23:00 UTC). The session logs all commands and their output to a
timestamped file on the host.

**Stop rule.** The dry run stops and teardown (§7) begins immediately if:
- Any checklist item in §4 (checks A, B or C) fails to pass within 5 minutes of `docker compose up`.
- The host runs out of memory (OOM kill of any container).
- The 23:00 UTC deadline is reached, regardless of progress.
- Any unexpected error writes to the application log that cannot be explained within 2 minutes.

**After the window.** The operator records the result (pass / stop + reason) and notifies
the owner. The host is left in the teardown state (§7) by 23:05 UTC at the latest.

**UNKNOWN — owner: operator.** Confirm the name and contact of the operator who takes the
window, and the channel for the result report.
