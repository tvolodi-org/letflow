# Rolling deploy without a user-visible stop: two backend nodes, one database

Task T-1826. Asked by the owner on 2026-11-12 ("upgrades without stopping the server").
Written 2026-11-12 by the business analyst. **Draft and design only.** No code, no requirement,
no QA or production change, no DNS, secrets, demo promotion or public repository is touched by this page.

Decision for UAT only; the process owner configures production. Anything below that touches
production behaviour, money, access or other tenants' data is a recommendation or an open
owner question. A rule I could not trace to a source is marked **guess** or
**UAT assumption, to be confirmed by the process owner**.

Legend used in every table: **V** = verified in code or a file on `origin/main` (4767b8a62,
2026-11-12), I opened it. **G** = guess / not verified, with what would verify it.
**INFRA** = infra's to do (outside this repository, not touched here).

## 0. Short answer

1. The build is global, the tenant upgrade is per tenant. A new build needs a node restart.
   A tenant upgrade does not. With **two nodes behind one proxy** the restarts happen one node
   at a time, so users see no stop. (V: `docs/runbooks/deploy-rules.md` section 1; the
   source design is `ai-dala-portfolio/proposals/letflow-runtime-updates-design-T-1519.md`.)
2. This only works if build N and build N+1 can run on **the same database at the same
   time**. That is the expand/contract rule (section 3). Today nothing in CI enforces it for
   migrations (section 3.3).
3. Two things do **not** exist yet and are the real work: a **second node and a proxy that
   can take a node out** (infra, section 7), and a **redeploy script that takes a commit SHA**
   and does one node at a time (infra, section 7). Today's QA redeploy script does
   `git pull`, builds `letflow-qa:latest`, and runs `up -d --force-recreate app` on a single
   container: that is a stop of a few seconds to minutes by construction (V: `deploy/redeploy-qa.sh`
   steps 1, 3, 5).
4. Application side is mostly ready: `/health`, `/ready`, boot-time migrations, per-tenant
   advisory locks, `SKIP LOCKED` job claims, the `min_data_version` gate and
   `module_version_ahead` refusal (built since the T-1519 note) all exist. Gaps: no graceful
   drain code, public-schema migration at boot is not an explicit step, and no migration
   lint (section 3.3).
5. Not decided here: whether "no downtime" is a promise for production (owner question O2 in
   the T-1519 note, still open). This page designs it for **QA first**.

## 1. Target picture (ask 1)

```
 clients ──► proxy (nginx) ──┬──► node A  (letflow container, port 4000)
                             └──► node B  (letflow container, port 4000)
                                    │            │
                                    └────┬───────┘
                                         ▼
                                   one PostgreSQL
 static web bundle: served by the proxy from a directory, not by the nodes (V: redeploy-qa.sh step 6/7)
```

### 1.1 What each part must do

| Part | Needed behaviour | Today | Status |
|---|---|---|---|
| Liveness | Public `GET /health` answers 200 `{"status":"ok","sha":...}`, no auth, no DB. | exists, `lib/letflow/router.ex` `get "/health"`; `sha` is the build commit (`Letflow.BuildInfo`) | V |
| Readiness | Public `GET /ready`: 200 when `database`, `migrations`, `secrets_key`, `identity` are ok, else 503 with names. Cached 5 s per node. | exists (`Letflow.Readiness`) | V |
| "Up" means "boot work is finished" | The HTTP listener starts only after the migrator, tenant replay and upgrade boot child have run. | The supervisor order puts `Ecto.Migrator`, then `TenantProvisioning.MigrationReplayBoot`, then `ModuleUpgrade.Boot` in the infrastructure layer, the HTTP layer (`Bandit`) after it. I read the moduledocs in `lib/letflow/supervisor/infrastructure.ex` and `http.ex`; I did not run a boot and watch the port. | V (docs), G (behaviour; test T3 checks it) |
| Second node | Same image, same env file, different host port, own container name. | one `app` service only, port `127.0.0.1:3201:4000` | **INFRA** |
| Proxy upstream | Two servers in one upstream; a node can be marked `down` without dropping connections to the other. | none in repo; the only vhost sample proxies one backend (`deploy/nginx/letflow-test.conf`); the QA vhost is outside this repository | **INFRA** |
| Active health check | Proxy stops sending to a node that fails `/ready`. | nginx open source has passive checks only (`max_fails`, `fail_timeout`) **(G: from nginx documentation, not tested here)** | **INFRA** (decide: script-driven `down` flag, see 1.2) |
| Drain | Node gets no new requests, in-flight requests finish, then stop. | No application drain code found: `grep -rniE "drain|graceful" lib/letflow/supervisor lib/letflow/application.ex config` found nothing. So drain is done **by the proxy** and a wait, then SIGTERM. | V (absence), G (what Bandit does on SIGTERM; test T5 measures it) |

### 1.2 Order of steps for one release (build N → N+1)

The script drives this; infra writes it (section 7). Steps A to H.

| # | Step | Who | Stop condition (abort and roll back, section 5) |
|---|---|---|---|
| A | Preflight: tag of N is kept; N+1 image is **already built** from the given SHA; the migration lint (3.3) passed; `/ready` of both nodes is 200; `LETFLOW_MODULE_UPGRADE_ON_BOOT=false` on both nodes. | script | any check fails: nothing changed yet |
| B | Back up the database (hard step). | INFRA | no backup: stop |
| C | Take node A out of the proxy (`down`, reload). Wait until its in-flight requests are gone (fixed wait, **G: 30 s** starting value, a setting not a rule; measured by test T5). | script | node B not `/ready`: do not take A out |
| D | Stop A, start A on image N+1. At boot A runs the **public-schema migrations** (`Ecto.Migrator`), then the **tenant replay**, then opens the port. Wait for `/ready` 200 **and** `/health.sha` equal to the target SHA. | script | `/ready` not 200 in 5 min **(G: size of the timeout; depends on tenant count, because the replay is blocking, see 4.4)**, or sha differs: restore A on N, put it back, stop. The expand-only rule is what makes N-on-migrated-schema safe. |
| E | Put A back in the proxy. Run the probe (section 6) for a settle time, **G: 2 min**. Compare error rate with the earlier window. | script | probe sees errors from A: take A out again, roll back |
| F | Repeat C to E for node B. | script | as above |
| G | Both nodes on N+1. **Now** (and not before) per-tenant upgrade (section 3.4): the fleet driver, tenant admins, or, for QA, `scripts/demo_upgrade_chain.sh`. | operator | a plan that does not end `up_to_date`: see the breakage list in `docs/runbooks/demo-upgrade-notes.md` |
| H | Smoke: `scripts/demo/demo_upgrade_check.sh verify` (V: exists, read-only), `/health.sha` on both nodes through the proxy. Keep image N tagged for one more release. | script | any difference: roll back (section 5) |

Why one node at a time and the upgrade last: while A is on N+1 and B on N, a tenant that has
already been upgraded to a version B does not know would be served by B. Nothing reads the
tenant version on non-HTTP paths (3.4), so tenants are upgraded only after the last old node is gone.
(V: `docs/runbooks/deploy-rules.md` section 3, same rule.)

## 2. Where this fits with what exists

| Subject | Source (opened) | Status |
|---|---|---|
| Design of "updates at runtime" (rolling recommended, hot-load rejected) | `ai-dala-portfolio/proposals/letflow-runtime-updates-design-T-1519.md` sections 2, 3 | V (read in full) |
| Build / restart / tenant-upgrade table, expand/contract checklist, rolling preconditions, rollback table | `docs/runbooks/deploy-rules.md` (204 lines) | V. This page **does not replace it**: it designs the topology, the enforcement, the sequence and the test; the runbook stays the checklist. |
| Demo promote and smoke | `docs/runbooks/demo-upgrade-notes.md`; `scripts/demo_upgrade_chain.sh`; `scripts/demo/demo_upgrade_check.sh` | V (read; scripts exist; I did not run them) |
| T-1519 slices S1, S3, S5 done; S2 (this page's subject), S4 part 2, S6 partly, S7 open | `deploy-rules.md` section 6 and 1a | V. Note: the runbook's section 1a says a fleet driver at `/platform-module-rollouts` exists; the T-1519 note (older) says "not built". Take the newer: runbook 1a. The route exists in `lib/letflow/api/authorization.ex` (policy key `ModuleRolloutsManage`), so the fleet driver is **V (exists)**; its behaviour is G. |

## 3. Expand/contract rules for database migrations (ask 2)

### 3.1 The rule

During a rolling deploy N and N+1 run at once on one schema. So **a release may only expand;
contract is a later release, after N is out of rollback range.**

| One release MAY | One release MAY NOT |
|---|---|
| Add a table. | Drop a table. |
| Add a column that is nullable, or NOT NULL with a default. | Drop or rename a column. |
| Add an index (built `CONCURRENTLY` on a big table, see 3.2) or a new non-validated constraint. | Change a column type. |
| Add an enum value or a permission, route, entity type, optional field, definition version. | Make a nullable column NOT NULL without a default; add or tighten a constraint that the old build can still violate; add a unique index over data the old build can duplicate. |
| Backfill into a **new** column in batches, new code writing both. | Backfill in one long transaction that locks a hot table. |
| Make new code read-tolerant of old data (default for a missing field). | Make new code require data that only the upgrade writes, on a non-HTTP path. |

A contract release (drop, rename, tighten) is allowed only when **all** hold: the previous
release shipped the expand; every tenant was upgraded (the fleet driver can show this, see
section 2); `min_data_version` is raised in the same release; image N-1 is no longer a rollback target.
This repeats `deploy-rules.md` section 2 and 0055 D5, D8.1; no new rule is invented here.
`deploy-rules.md` says today that **no contract release is allowed yet** because it was written
before the fleet driver; keep that until the owner says otherwise.

### 3.2 Locks: what an "expand" can still break

| Statement | Problem on a live system | Rule |
|---|---|---|
| `CREATE INDEX` on a large table | blocks writes for the duration | use `CONCURRENTLY` with `@disable_ddl_transaction true` and `@disable_migration_lock true` in the migration. **G**: not checked whether any current migration does this. |
| `ALTER TABLE ... ADD COLUMN ... DEFAULT x` | Postgres 16 (the QA image is `postgres:16-alpine`, V: `deploy/docker-compose.qa.yml`) does not rewrite the table for a constant default. | allowed; a volatile default is not. |
| `ALTER TABLE` of any kind | takes an `ACCESS EXCLUSIVE` lock for a moment; queued behind a long query it blocks everything behind it. | set `lock_timeout` in the migration (the module upgrade apply already uses 10 s, V: `apply.ex` `@lock_timeout`); retry the deploy rather than wait. |

### 3.3 How the existing checks can enforce it (and what is missing)

| Existing check | What it checks | Enough? |
|---|---|---|
| `mix letflow.check_boundaries` | module-boundary edges by `mix xref` (REQ-405). | No. Not about migrations (V: moduledoc). |
| `Letflow.Readiness` part `migrations` | no `:down` (unapplied) migration of the **global** schema on this node. | No. A runtime check, not about the content (V). |
| CI `ecto.migrate` before tests | the migrations apply on an empty database. | No: says nothing about old code on the new schema (V: `.github/workflows/ci.yml` lines 11, 20, 612 mention it). |
| `scripts/ci_changed_paths.sh` | which gates a change needs. | Can route a "migration changed" signal (G: not read in detail). |
| `mix letflow.check.static` steps | list in `mix.exs` `@check_static_steps`; a new task is one more line. | The place to wire a new lint (V). |

**Gap (V):** `ls lib/mix/tasks` has no task that reads the content of `priv/repo/migrations`. 194
files exist; 35 contain one of `drop `, `remove `, `modify `, `rename ` (count by `grep -rlE`; some
are `drop_if_exists` of an index, or a `down` function, so 35 is an upper bound, **G**).

**Proposal (a later requirement, not built here): `mix letflow.check_migration_expand_only`.**

- Input: the migration files **added or changed since the base commit** (the last deployed SHA on
  main; in CI `git diff --name-only origin/main...HEAD -- priv/repo/migrations`), plus the entries in
  `@tenant_scoped_migration_manifest` of `lib/letflow/tenant_provisioning.ex` (V: tenant migrations are a
  manifest of `{version, module, filename}`, so a tenant migration is a migration file **and** a manifest line).
- Reads only the `up` part (and `change`). Refuses: `drop`, `remove`, `rename`, `modify`, `alter ... type`,
  `add ... null: false` without `default:`, a unique index or `NOT NULL` set by `execute` with raw SQL
  that matches the same words, `create index` without `concurrently` on a table in a short list of big tables.
- Escape hatch: a first-line comment `# contract-release: <issue number>` is accepted only if the same
  diff raises a `min_data_version` in a module manifest (V: the key exists, `Installs.version_verdict/2`), so
  a contract cannot be merged by accident.
- A scan test pins the allowed patterns, like the other scan tests in this repository.
- Size: one change. Security review not needed (no tenant data path). **Open decision for the owner:
  does the lint block the merge, or warn?** Recommendation: block.
- **Compatibility test of the previous build** (0055 D5 asks for one for module data): a CI job that checks out
  the base SHA's code against a database migrated by the head's migrations is the real test but costs a full
  second build. Cheaper first step: the compose test in section 6 (T2) does exactly this with two real images,
  run before each QA release and not in every CI run. Recommendation: do T2, skip the CI job.

### 3.4 Module and tenant upgrade in the sequence (ask 3)

| Thing | What it does | Where it sits | Status |
|---|---|---|---|
| Plan route | read-only report of what an upgrade would change, with `plan_hash` | step G | V (`docs/runbooks/demo-upgrade-notes.md`; REQ-768) |
| Apply route | one transaction per tenant and module, advisory lock `pg_try_advisory_xact_lock`, `lock_timeout` 10 s; a second caller gets `upgrade_running`. | step G | V (`lib/letflow/module_upgrade/apply.ex` lines 53, 196, 201) |
| 409 `upgrade_required` | a module write by a tenant whose installed manifest hash differs from this build's is refused, the task stays pending. | applies between D and G for the **new** node | V (`Error.module_upgrade_required`, `lib/letflow/api/error.ex` 302) |
| `min_data_version` gate | a manifest key; the module mount answers **503** `module_data_version_too_old` if the tenant's stored version is below it (unparsable: fail closed). | a contract release only; never in an expand release | V (`Installs.version_verdict/2`, `lib/letflow/routers/modules.ex` 151, `Error` 314) |
| `module_version_ahead` | the module mount answers **503** `module_version_ahead` if the stored version is above this build. This is what a **rolled-back or old node** answers for an already-upgraded tenant. | protects the mixed window and a code rollback, **only for builds that contain it** | V (`modules.ex` 117, `Error` 333) |
| Upgrade on boot | `LETFLOW_MODULE_UPGRADE_ON_BOOT`, default off, class A only. | must be `false` on both nodes through steps C to F | V (`deploy-rules.md` section 3, `boot.ex`). If it is `true`, node A applies upgrades at D while node B (old) still serves. |
| Fleet driver | `/platform-module-rollouts`, halts after N failures, honours a tenant window. | step G, many tenants | V for existence: route policy keys in `lib/letflow/api/authorization.ex` 999 to 1001; G for behaviour (halt, window) per `deploy-rules.md` 1a |
| Demo chain | `scripts/demo_upgrade_chain.sh` | step G on QA | V (exists, read) |

**Sequence rule (one line):** *new build everywhere, then upgrade tenants, then smoke.* An old
node never serves a tenant that is ahead of it, except through a path the gate does not cover.
**Known hole (V: `deploy-rules.md` section 2 repeats it):** the skew gate is **HTTP only**
(0055 D5 open point 8). Pollers, service tasks, webhook delivery and the engine read tenant
data without the gate. So tenants are upgraded only after the last old node is gone; this is
a rule, not a guarantee.

## 4. Websockets, sessions, background jobs, boot replay during the overlap (ask 4)

### 4.1 Websockets and long-lived connections

| Fact | Status |
|---|---|
| No WebSocket or server-sent events in `lib/`. `grep -rniE "websocket\|websock\|text/event-stream\|Phoenix.PubSub\|Phoenix.Socket" lib mix.exs` finds only two design notes (`lib/letflow/design/req194-prometheus-metrics.md`, `req148-lua-runtime-spike.md`), no `.ex` file. | V |
| The sample vhost says "JSON API only — no WebSocket upgrade headers", and the SPA is a static bundle. | V (`deploy/nginx/letflow-test.conf` line 7) |
| Consequence: nothing to hand over between nodes. Each request is one HTTP exchange. A request in flight on a node that is stopped is lost: the client sees a 502 from the proxy, or a reset. | V (absence); the loss itself is **G**, measured in T5 |
| If a websocket or SSE feature is added later it needs its own drain and reconnect design. Not in scope; say so in that feature's requirement. | open point |

Mitigation for the lost in-flight request: the drain wait of step C (the node gets no new
requests first). A **POST** in flight at the moment of a hard stop can still fail. Records
writes carry idempotency (`event_idempotency` table, V: `lib/letflow/event_store.ex` moduledoc line 25; I did not trace which routes pass a key), so the client may retry. A client that does not retry shows one error.

### 4.2 Sessions and tokens

| Fact | Status |
|---|---|
| Browser sessions are OIDC tokens (Keycloak realms), checked on each request through `Letflow.Oidc.ProviderRegistry`, a per-node `DynamicSupervisor` of realm workers. A fresh node rebuilds them at boot. | V (infrastructure moduledoc, child 4) |
| API tokens are checked against the database (decision-record reading; not opened in this task). | **G** |
| No server-side session store was found, so no sticky session is needed and a request may go to either node. | **G**: I did not enumerate every auth path; test T1 (a signed-in probe through both nodes) verifies it |
| Per-node in-memory state: rate-limit buckets (`auth_attempt_limit`, `login_discovery_rate_limit`, `public_read_rate_limit`, `provisioner_auth/rate_limiter`), `Readiness` caches, `authz_deny_log`, scope shadow log, plugin registry, metrics registry (V: `grep -rln ":ets.new\|:persistent_term.put" lib`). Effect: during the overlap the limits are per node (a client could get 2x the allowance) and a restarted node's counters and in-memory logs start empty. Prometheus counters reset on restart (normal for counters). | V (list); the effects are **G** by reasoning |
| A sign-in flow that spans two requests and keeps state in node memory would break if the two requests hit different nodes. | **G**: not found, not exhaustively searched; T1 includes a full sign-in through the proxy with the two nodes alternating |

Recommendation: **no sticky sessions.** If T1 finds a state that needs them, fix the state, not the proxy.

### 4.3 Background jobs (pollers, sweeps)

Every node runs its own pollers (`Letflow.Supervisor.Pollers`: scheduler poller, service-task
dispatcher, script-task dispatcher, record-trigger worker, provisioner sweep; each gated by
its own `:start_*` config key, default on, V: `lib/letflow/supervisor/pollers.ex`). So during
the overlap **old and new code both claim jobs**.

| Job path | How a second node is made safe | Status |
|---|---|---|
| Scheduled jobs | claim with `FOR UPDATE SKIP LOCKED`, `next_run_at` moved in the claim transaction | V (`lib/letflow/scheduler/scheduled_job_sweep.ex` 25, 107) |
| Record deadline sweep | `FOR UPDATE SKIP LOCKED` in the same transaction | V (`record_deadline_sweep.ex` 72) |
| Script task dispatcher | `FOR UPDATE SKIP LOCKED`, sets `running`, `attempt + 1`, `claimed_at` and a lease | V (`engine/script_task_dispatcher.ex` 335, 367) |
| Service task dispatcher | `FOR UPDATE SKIP LOCKED` | V (`engine/service_task_dispatcher.ex` 492) |
| Provisioner sweep, record-trigger worker, webhook delivery | not read | **G**: the design for a rolling deploy must not assume them safe; test T4 runs a scheduled job and a service task through the whole roll and counts duplicates |

Specific overlap risks:

1. **A job claimed by the old node runs old code** against data that the new node's replay has
   migrated. Expand-only (3.1) is what makes this safe. The "non-HTTP paths tolerate version-N data" box in
   `deploy-rules.md` section 2 is the same rule.
2. **A node stopped in the middle of a job.** The script dispatcher has a lease, so another claim
   is possible after the lease ends (V: `script_task_dispatcher.ex` 335 text; lease length not read, **G**).
   A service task is at-least-once by that design **(G: confirm with the dispatcher's moduledoc before T4)**.
   So drain (step C) gives running jobs time to end before SIGTERM; the wait must be at least as long as the longest
   job the poller can hold, or the lease takes over. The wait is a setting; its starting value is G.
3. **Do not stop the pollers separately.** Taking a node out of the proxy does not stop its pollers; the node keeps
   working jobs until it is stopped. That is acceptable (they are claim-safe), and it means "drained" = no
   HTTP requests, not "no work".

### 4.4 Migration replay at boot during the overlap

| Fact | Status |
|---|---|
| Public-schema migrations run in the node's own boot by `{Ecto.Migrator, ...}` in the infrastructure supervisor, **only inside a release** (`skip_migrations?/0` checks `RELEASE_NAME`). | V (`infrastructure.ex` 226, `application.ex` moduledoc; the Dockerfile comment says the same) |
| Ecto takes a migration lock by default so two nodes migrating at once serialise; the second finds nothing to do. The repository does not override it for the boot migrator. The lock is library behaviour (`ecto_sql` 3.14.0 in `mix.lock`), **not tested here.** | V (no override found), **G** (library behaviour) |
| Tenant replay: `replay_all_pending/0` calls `Ecto.Migrator.run(Repo, migrations, :up, all: true, prefix: schema)` per tenant, with default options; a failing tenant is logged and recorded (`list_replay_failures/0`), the boot continues. | V (`tenant_provisioning.ex` 389 to 456) |
| The replay is **blocking** (a "one-shot" child that returns `:ignore` after it finishes) and not gated by `skip_migrations?()`. So boot time grows with the tenant count, and the port opens only after it. | V (`migration_replay_boot.ex` moduledoc) |
| The replay being idempotent when two nodes start within seconds is **stated** in the module and **assumed** by `deploy-rules.md`; no test with two real nodes exists. | **G**; test T3 is this check |
| The `migrations` readiness part would fail on a node with an unapplied global migration. | V (`readiness.ex` moduledoc) |

Consequences for the sequence: (a) **never start both nodes on N+1 at the same time**; the first one migrates
and finishes, the second starts after it is `/ready` (step F). This makes T3's double-start a worst case
we test, not a case we plan. (b) A migration that takes minutes holds step D for minutes; node B keeps
serving, so users see nothing. That is the benefit of the order. (c) A failing tenant replay does **not**
stop the boot: `/ready` can be 200 while one tenant's migration failed. Add `list_replay_failures()` to the
step D check (INFRA: `bin/letflow rpc "Letflow.TenantProvisioning.list_replay_failures()"`, V: named in the
function doc). Open point: it is not in `/ready` today; adding it would be a requirement (one change).

## 5. Rollback (part of the sequence)

| Situation | Action | Safe if |
|---|---|---|
| New node A fails `/ready` or sha is wrong at step D | stop A, start A on image N, put it back | the migrations of N+1 were expand-only: the old build then runs on the newer schema. Ecto lists the extra applied versions without a file; **G**: harmless, test T6 shows it. |
| Probe sees errors after E or F | take the node out; node on N+1 goes back to N; second node untouched | same |
| After G (tenants upgraded), a bad release | roll tenants back first with `POST /api/v1/tenant/modules/:id/rollback`, then redeploy N. The reverse order is refused: `module_version_ahead`. | V (`demo-upgrade-notes.md`, "Rolling back an upgrade"). Only for tenants whose last upgrade is recorded and reversible; refusals are listed there. |
| Public-schema migration was a contract | **no rollback**; roll forward with a corrective release, restore the backup only as the last resort (data loss since the backup). | V (`deploy-rules.md` section 4) |

Image N must stay tagged until N+1 has passed step H and the next release has started.
Today the QA script only tags `rollback-<date>` (V: `redeploy-qa.sh` step 2); a SHA-tagged image is better (section 7).

## 6. Test plan (ask 5)

All tests run on **a local compose with two nodes** first, then once on QA after infra provides
the pieces in section 7. A **probe client** is a small loop that, every 100 ms, sends
`GET /health` and one authenticated read through the proxy and one idempotent write, and logs the
time, node (from `/health.sha` and a header if infra adds one) and result. Zero failed requests
in the window is the pass criterion for T1 to T3. No test touches production data; the compose uses its
own database (never `letflow_dev`, never QA's).

Two real images are needed: **build N** (an older commit) and **build N+1** (head). That is the
only way to see an old build on a new schema (`demo-upgrade-notes.md` says the same: one checkout holds
one build, so a unit test cannot show it).

| ID | Test | Method | Pass when |
|---|---|---|---|
| T1 | Baseline: two nodes on N, probe through the proxy, sign-in flow alternating nodes. | Compose with `app-a`, `app-b`, one nginx, one Postgres. | 0 errors in 5 min; every request answered by either node; no sticky-session need found. |
| T2 | **Roll N to N+1** with an expand-only migration added between N and N+1. | Steps A to H with the probe running. | Probe: 0 failed requests except those the drain wait does not cover; node sha changes A then B; `verify` exit 0; both nodes `/ready`. |
| T3 | **Double start**: start A and B on N+1 at the same moment against a database at N, with one new public and one new tenant migration. | Compose `up` of both at once. | Both reach `/ready`; each migration recorded once (`schema_migrations`, tenant schema); `list_replay_failures()` is `[]`; no crash loop. This is the test for the "assumed" lines in 4.4. |
| T4 | Jobs during the roll: one scheduled job every 10 s, one service task, one script task; roll as T2. | seed a tenant process on the compose database; count executions per job id. | No job lost; no job run twice beyond the documented at-least-once case; counts reported. |
| T5 | **Drain and in-flight loss**: a slow request (a deliberately slow read, a script task) running while node A is taken out and stopped, with the drain wait at 0 s, 10 s, 30 s. | Probe plus a slow request. | Measure and write down: the wait at which 0 requests fail. This sets the setting; the 30 s of step C is a guess until this runs. |
| T6 | **Rollback case 1**: N+1 build whose boot fails (a test image with a bad migration or a `/ready` that stays 503), put in node A. | Step D abort path. | A is put back on N and `/ready`; users saw only node B; no data change; probe 0 errors. |
| T7 | **Rollback case 2**: a roll that completes, tenants upgraded (`demo_upgrade_chain.sh`), then rolled back: tenants first (rollback route, `dry_run` first), then image N. | on the compose database with the stock demo tenant. | Plan reads the older version; N serves; `verify` exit 0. Also check the **reverse order** answers 503 `module_version_ahead`. |
| T8 | **Skew**: node A on N+1 and node B on N, a tenant upgraded in between. | manual hold at step D, run the plan/apply on a demo tenant, hit both nodes. | The old node refuses with 503 `module_version_ahead` if it contains the gate (it does if N is recent) **and** the probe shows which paths answer wrongly (non-HTTP). This is the check of the known hole in 3.4; the result goes into `deploy-rules.md`. |
| T9 | **Lint**: a branch that adds `drop column`, a rename, a NOT NULL without default. | once `check_migration_expand_only` exists. | All three refused; a `contract-release` marker without a raised `min_data_version` refused. |
| T10 | **QA run**: the same as T2 once on QA, off working hours, with infra's script. Only after T1 to T8 pass locally. | one release. | As T2 on QA, measured with the probe from a machine outside the host. |

Who runs what: T1 to T8 can be done by the operator or the team on the compose (no QA touch). T9 is a
later requirement. T10 needs infra and the owner's OK; **I do not run it and I do not touch the QA deploy.**
Local compose limits: the host is shared; keep two nodes plus one Postgres within the machine-load rules
(2 to 3 containers, no stress tools).

## 7. Exact asks for infra (ask 6) — all INFRA's to do, nothing done here

| # | Ask | Detail | Why |
|---|---|---|---|
| I1 | **A redeploy script that takes a commit SHA**, e.g. `redeploy-qa.sh <sha>` | builds (or pulls) the image **tagged with the SHA** (`letflow-qa:<sha>`, with `--build-arg GIT_SHA=<sha>` as today), checks out **that** SHA instead of `git pull` of the branch head, refuses a SHA that is not on `main`, refuses to run if the working tree is dirty. | Today `git pull` takes whatever main is. A SHA makes the deploy repeatable and the rollback target (an earlier SHA) exact. Also lets `/health.sha` be compared with the target. |
| I2 | **Do one node at a time** inside that script | steps A to H of 1.2: preflight, backup, take out, drain wait, replace, wait for `/ready` and sha, put back, settle, next node. Abort rules as written. | replaces `up -d --force-recreate app`, which stops the only node |
| I3 | **A second backend node** | a second service in `deploy/docker-compose.qa.yml` (this file is in this repository; infra owns the host copy) with the same image, same `env_file`, another host port (e.g. `127.0.0.1:3203:4000`), own restart policy. Do not start both at the same time on a release. **The memory of the QA host (16 GB per the script header) must be checked: one more BEAM node is G, unmeasured.** | needed so one node always serves |
| I4 | **Proxy upstream with two nodes** | in the QA vhost (outside this repository): an `upstream` with both ports, `proxy_next_upstream` limited to connection errors and timeouts, no retry of POST (nginx default; keep it), a way to mark one node `down` and reload (`nginx -s reload` is graceful: it finishes in-flight requests of old workers). Passive checks (`max_fails`, `fail_timeout`) as a second line. **Decision for infra:** script-driven `down` (simple) or a proxy with active checks (more to build). Recommendation: script-driven. | take a node out without dropping connections |
| I5 | **Health gate in the script** | wait for `GET /ready` 200 (not only `/health`) and compare `sha`. The current script checks `/health` `status == ok` only (V: step 8). | `/health` does not see the database |
| I6 | **Public-schema migration step stated** | keep boot-time migration (current behaviour) **or** run a separate "migrate once" step before node A. Recommendation: keep boot-time, node A first, B after it is ready (4.4). The decision and the exact command go in `docs/runbooks/deploy-rules.md` by a later change. | one defined place for the migration |
| I7 | **Drain wait setting** | `DRAIN_WAIT_SECONDS`, default from T5. Plus `stop_grace_period` in compose at least that long (the compose files set none, V: `grep -n "stop_grace" deploy/* docker-compose.yml` is empty), so SIGTERM is not followed by SIGKILL after 10 s. | the default Docker stop is 10 s |
| I8 | **Env flags on both nodes** | `LETFLOW_MODULE_UPGRADE_ON_BOOT=false` during the roll; the same env file for both nodes; a per-node flag change only with a node restart. | 3.4 |
| I9 | **Web bundle** | the bundle swap (V: atomic `mv`, no reload) happens **after** both nodes are on N+1 (the API stays compatible with the previous bundle for one release; the old bundle in an open tab keeps working), not before. Keep one previous bundle. | a new bundle against an old node could call a route the old node lacks |
| I10 | **Backup before step D** | a tested database dump and its restore (V: `docs/runbooks/backup-restore.md` named in `release.ex`; not read here). | rollback of a contract or data change |
| I11 | **Probe from outside** | a small script or monitor that hits the public URL during a roll and writes errors with timestamps (T10). | the proof of "no stop seen" |
| I12 | **Keep image N** | tag by SHA, keep the last 3. | rollback target |

Out of scope and untouched: production, the QA deploy itself, DNS, secrets, the demo promote, the public repository.
`promote-demo.sh` is infra's and was not read (outside this repository).

## 8. What is verified and what is a guess (summary)

| Verified in code or file (V) | Guess / not verified (G) |
|---|---|
| `/health` and `/ready` exist and what they check. | Boot order seen as listening port (moduledocs read, no boot run). |
| Boot runs public migrations, then tenant replay (blocking), then the upgrade child, then HTTP. | Two nodes migrating at once is safe (Ecto lock, not tested here). |
| Pollers claim with `SKIP LOCKED` (4 of the paths). | Provisioner sweep, record-trigger worker, webhook delivery safe with two nodes. |
| No websocket / SSE in `lib/`. | Every auth path is stateless across nodes. |
| `min_data_version` gate and `module_version_ahead` refusal exist (HTTP only). | Non-HTTP paths tolerate a tenant ahead of the node. |
| Rollback route exists and its order rule. | Fleet driver router exists as the runbook says. |
| QA redeploy is single-node, `git pull`, `force-recreate`. | Drain wait of 30 s, boot timeout 5 min, settle 2 min (starting values). |
| No migration-content lint exists. | Number of current migrations that are not expand-only (35 files match a word grep, upper bound). |

## 9. Open questions (owner)

| # | Question | Recommendation |
|---|---|---|
| O2 (from T-1519, still open) | Is "no downtime" a promise for production, or only demo/QA? | QA first; production after T10 and a second look. |
| Q1 | Does the migration lint block the merge or only warn? | Block. |
| Q2 | May a contract release ever ship before the fleet driver proves every tenant upgraded? | No (current rule). |
| Q3 | Is a short window of per-node rate limits (2x allowance) acceptable during a roll? | Yes, for QA. |
| Q4 | Who may run T10 and when (off hours)? | Operator with infra, off hours, owner informed. |

## 10. Next tasks (not queued, for the operator to decide)

| Slice | What | Size | Needs |
|---|---|---|---|
| R1 | `mix letflow.check_migration_expand_only` plus scan test, added to `@check_static_steps` (3.3). A `requirement` first. | S to M | nothing |
| R2 | Add `list_replay_failures` to the readiness result (or a second endpoint) (4.4). A `requirement` first; touches a public route, so a security look. | S | R-decision on fixed vocabulary |
| R3 | Two-node compose file for local tests and the probe script (T1 to T8). Lives in `deploy/` or `scripts/`. | M | none (no QA) |
| R4 | Infra asks I1 to I12. | M | infra |
| R5 | Update `docs/runbooks/deploy-rules.md` with T3, T5, T8 results when measured. | S | R3 done |

## 11. Sources opened

- `ai-dala-portfolio/proposals/letflow-runtime-updates-design-T-1519.md` (all 248 lines).
- `docs/runbooks/demo-upgrade-notes.md` (all), `docs/runbooks/deploy-rules.md` (all).
- `deploy/redeploy-qa.sh` (all), `deploy/Dockerfile` (lines 55 to 82), `deploy/docker-compose.qa.yml` (all), `deploy/nginx/letflow-test.conf` (top).
- `lib/letflow/router.ex` (health, ready), `lib/letflow/readiness.ex` (moduledoc), `lib/letflow/application.ex`, `lib/letflow/supervisor/infrastructure.ex`, `http.ex`, `pollers.ex` (moduledocs and children), `lib/letflow/tenant_provisioning.ex` (`replay_migrations`, `replay_all_pending`, `tenant_scoped_migrations`), `lib/letflow/tenant_provisioning/migration_replay_boot.ex` (moduledoc), `lib/letflow/modules/installs.ex` (`version_verdict`), `lib/letflow/routers/modules.ex` (gate lines), `lib/letflow/api/error.ex`, `lib/letflow/module_upgrade/apply.ex` (lock lines), `lib/letflow/scheduler/scheduled_job_sweep.ex`, `lib/letflow/engine/script_task_dispatcher.ex`, `service_task_dispatcher.ex` (locking lines), `lib/mix/tasks/` (listing), `mix.exs` (aliases), `.github/workflows/` (listing).
- Searched, found nothing: WebSocket/SSE in `lib/` (grep in 4.1); drain or graceful-stop code (grep in 1.1); `stop_grace_period` in `deploy/` and `docker-compose.yml`; a task that reads the content of migrations (`ls lib/mix/tasks`).
- Not opened: infra's repository and `promote-demo.sh`; the QA vhost and host state; the handler of `/platform-module-rollouts` (only its policy keys); `ci.yml` beyond the migration lines; `scripts/ci_changed_paths.sh`; `docs/runbooks/backup-restore.md`; decision records 0055 and 0080 (cited through the runbook and T-1519 note, which quote them: **a pointer, not re-read**).
