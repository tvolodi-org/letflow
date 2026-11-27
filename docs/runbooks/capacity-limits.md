# Capacity limits: how the admission gates are sized

Why this exists: QA answered `503 server at capacity, retry shortly` when two UAT runner runs
overlapped (T-2923 BP-07 s7, T-2918 SEC-ID-03 s21). This runbook says what each limit counts, how to
size it, which settings change it, and what a user sees. It documents the current behaviour only;
no default is changed here.

## What each limit counts

Two counting semaphores live in one `GenServer`, `Letflow.Admission` (`lib/letflow/admission.ex`).
A slot is held for the whole HTTP request and released when the response is sent (or the request
process dies). There is no wait queue: a request that finds no slot is refused at once.

| Limit | Value | Counts | Refusal |
|---|---|---|---|
| Global cap | `POOL_SIZE - RESERVED_HEADROOM` (defaults 30 - 2 = **28**) | requests in flight, all tenants together | 503 `server at capacity, retry shortly` (`Letflow.Plugs.Admission`, mount `pool: :global`) |
| Per-tenant cap | `max(div(global_cap, tracked_tenants), 1)` | requests in flight for one tenant | 503 `tenant at capacity, retry shortly` (mount `pool: :tenant`) |

Where the numbers come from: `POOL_SIZE` default 30 is set in `config/runtime.exs` (prod only, ISS-0908,
GH-2032), `RESERVED_HEADROOM` default 2 in the same file. The global cap is derived once when
`Letflow.Admission` starts; changing either variable needs a restart of the app container.

Points that are easy to get wrong:

- The global cap is shared by every tenant and also by the `Letflow.Scheduler.Poller` sweeps, which
  use the same budget (`lib/letflow/admission.ex`, ISS-0421). The sweeps hold at most
  `min(4, cap div 4)` units at once (4 at cap 28), never above `cap - cap div 2`; the key is
  `config :letflow, Letflow.Scheduler.Poller, sweep_concurrency: N` and the boot log line
  "scheduler sweep concurrency bound" shows the effective value (T-3055).
- **"Tracked tenants", not "active tenants".** The divisor is the number of tenants that have made at
  least one admitted-or-refused request since the app last started (an entry is created lazily on the
  first request of a tenant). It is dropped only when a tenant is deactivated
  (`forget_tenant/2`). An idle tenant keeps counting until restart. A host that served 7 tenants
  today gives each of them `div(28, 7) = 4` slots, even if only one is busy now.
- The per-tenant cap is recomputed at every request. A cap that shrinks does not cancel requests
  already admitted; the tenant simply cannot start new ones until it falls below the new cap.
- The two gates are independent refusals: the tenant gate can refuse while the global gate is nearly
  empty (one tenant, many parallel requests).

| Tracked tenants | Per-tenant cap (global cap 28) |
|---|---|
| 1 | 28 |
| 2 | 14 |
| 4 | 7 |
| 7 | 4 |
| 10 | 2 |
| 28 or more | 1 |

## How to size it for N users

Rule of thumb from ISS-0908: one SPA page load is **3-5 parallel requests**, and each one holds a slot
only for its own duration (tens of milliseconds for most reads). So the number that matters is the
number of requests *in flight at the same instant*, not the number of users.

- Burst estimate for one tenant: `simultaneous page loads x 5`. Ten people opening a screen in the
  same second is about 50 requests at the same moment, which exceeds 28 and any per-tenant share.
  Real users spread over time, so a tenant with 10-20 occasional users rarely sees more than 10
  requests at once.
- Clients that fire many requests together (the UAT runner's barrier steps,
  `scripts/uat/runner.py`, fire N requests at once; bulk imports; the mobile app syncing) can exceed the
  per-tenant share on their own. Two runner runs against different tenants at the same time also share
  the global 28.
- Per-tenant cap needed for a tenant with `B` peak simultaneous requests: global cap `>= B x
  tracked_tenants`. With 4 tenants and a peak of 10 for the biggest one, the cap must be at least
  `10 x 4 = 40`, which means `POOL_SIZE` of about 42.

`POOL_SIZE` is also the Ecto database pool: every admitted request may need a connection, so the pool
must not exceed what PostgreSQL can give. Raise `POOL_SIZE` only together with the database limits
below.

## Settings (`deploy/.env.example`)

| Variable | Default | Effect |
|---|---|---|
| `POOL_SIZE` | 30 | Ecto pool size, and the base of the global cap |
| `RESERVED_HEADROOM` | 2 | slots taken off `POOL_SIZE` for work that is not admission-gated (health, background); global cap = `POOL_SIZE - RESERVED_HEADROOM` |
| `MAX_INFLIGHT_AGE_MS` | 120000 | age bound of an in-flight admission: an admission held longer than this is logged once with its route class and its age (never released). `0` switches the sweep off |
| `STALE_SWEEP_INTERVAL_MS` | 1000 | how often the node looks for an over-age in-flight admission |

There is no separate setting for the per-tenant cap; it is always the division above. Never set
`RESERVED_HEADROOM` to `POOL_SIZE` or more.

## Reading the state of the gates (T-3034)

The node publishes its admission counters, so a refusal can be explained without guessing.

| Where | What it answers | Who may read it |
|---|---|---|
| `GET /health` -> `admission` | the budget that is applied (`pool_size`, `reserved_headroom`, `cap`), the units in use (`in_use`), the fair-share divisor (`tracked_tenants`) and the refusals since the node started (`rejections.global` / `rejections.tenant`) | anyone: the figures are aggregate ones of the node, with no tenant identifier in them |
| `GET /api/v1/platform-status/admission` | the same, plus `tenants` (the top five tenants by in-flight admissions, each with its route class and the age of its oldest admission) and `oldest` (the oldest in-flight admission of the node) | the platform operator only (`PLATFORM_ADMIN` of the platform tenant); the tenant names are hashed, never raw |
| the log line `admission_rejected` | one line per refusal: the budget in use, the refused request's route class, its tenant as a pseudonym and the oldest in-flight admission (route class and age) | the node's own log; at most one line per second, the withheld ones counted in `suppressed=` |
| the log line `admission_stale` | one line per admission held longer than `MAX_INFLIGHT_AGE_MS`: its route class and its age | the node's own log |

The route class is the route PATTERN (`/api/v1/instances`), never the request path: the counters and
the lines name the class of a request, not its ids. The UAT runner saves the counters of the node in
the run dir (`admission_counter_start.json` at the start of every tenant's leg -- a further tenant of
the run gets `admission_counter_start_2.json` -- and `admission_counter_503_<n>.json` at every 503
whose body says capacity) and prints the paths in `summary.md`. A read that fails is a note in the
summary; it never changes the verdict of the run.

A request whose PROCESS dies releases its slot: the admission server monitors the holder of every
admission (the request process), so a closed connection cannot leak the budget. The node therefore
does not need a restart to get its slots back.

There is no long-poll and no SSE route in the product (`grep -rniE "event-stream|long-poll" lib/`
finds none): every admission is an ordinary request/response, so a slot is held for the length of
one request and never across a stream. The age bound therefore catches the slow ordinary request
(a heavy import or export, a long script run), not a streaming consumer.

## Environments (infra numbers, 2026-11-26, PM relay of the infra discovery)

QA (runs/2026-11-26-qa-capacity-numbers-001/step-06-discovery.md):

- `POOL_SIZE` and `RESERVED_HEADROOM` unset, so 30 / 2 and a global cap of **28**.
- No container limits. Host: 8 CPU, 15.6 GB RAM.
- PostgreSQL `max_connections` 100, of which 30 are held by the app pool.
- nginx has no `limit_req` / `limit_conn` on the QA virtual hosts, so nothing in front of the app
  smooths a burst.

Production plan (not yet deployed): app container 1.5 GiB / 2 CPU, database 1 GiB. Infra was asked to
raise the database to 2 GiB and to write the pool and connection numbers into the plan. Until that is
written, this runbook gives no production `POOL_SIZE`; the value to put there comes from the
sizing rule above plus the answer to the open owner question (Client 1 users, phones, simultaneous
use).

Headroom check for a larger pool: `POOL_SIZE` plus any other client of the database (migrations,
operator sessions, a second app instance) must stay below `max_connections` (100 on QA). A `POOL_SIZE`
of 60 on QA would still fit; two app instances at 60 would not.

## Client 1 on a host with other tenants

The division is by tracked tenants on the same app instance. On a shared host with several tenants,
Client 1 gets `div(28, tenants)` slots. With 7 tracked tenants that is 4, below one SPA page load of
5 requests, so Client 1 can get a 503 `tenant at capacity` on a plain page load even when the server is
idle. Open points, to settle when the owner answers the Client 1 question:

- Client 1 on its own instance (one tracked tenant) gets the whole global cap.
- Otherwise raise `POOL_SIZE` (and the database limits) so that `div(global_cap, tenants) >= 10`.
- If that is too costly, the per-tenant division itself is the thing to change (for example a floor,
  a weight per tenant, or eviction of idle tenants). That is a code change and is proposed as a
  separate p1 task, not made here; defaults stay as they are.

## What the user sees

- The API answers HTTP 503, an error body whose detail is `server at capacity, retry shortly` (global)
  or `tenant at capacity, retry shortly` (tenant), and the header `Retry-After: 1`
  (`@default_retry_after_seconds` in `lib/letflow/plugs/admission.ex`).
- **The SPA does not retry on its own.** `web/src/api/client.ts` special-cases 401, 429 (reads
  `Retry-After`, code `RATE_LIMITED`) and 409; a 503 falls into the generic error branch and is thrown
  as an error. React Query is configured with `retry: 0` (`web/src/main.tsx`). So the screen shows its
  load-error banner with the retry action (`QueryStateBoundary`), and the user presses it; a write
  that was refused shows its form error. `Retry-After` is not honoured by the SPA.
- Scripts and the UAT runner see a plain 503; a runner step that expects 2xx fails. Re-run the step
  when no other run is using the host, or lower the barrier width.

## Diagnosis

1. Read the detail string: `server at capacity` = global gate, `tenant at capacity` = per-tenant gate.
2. Read `GET /health` -> `admission`: `in_use` and `cap` say whether the budget is really full,
   `tracked_tenants` is the divisor of the per-tenant cap (the table above), `pool_size` and
   `reserved_headroom` say what the node actually applied (a `POOL_SIZE` that is not what the
   deployment believes shows up here), and `rejections` says how many refusals of each kind the node
   has seen since it started.
3. The platform operator reads `GET /api/v1/platform-status/admission` for the WHO holds the slots:
   the top five tenants by in-flight admissions, each with its route class and the age of its oldest
   admission. The `admission_rejected` line in the log names the same thing at the moment of the
   refusal.
4. Count tracked tenants since the last restart (any tenant that sent a request); compute the table
   above.
5. Check for a concurrent heavy client (a second UAT run, an import, the Poller).
6. Only then change `POOL_SIZE` / `RESERVED_HEADROOM`, restart the app, and confirm
   the PostgreSQL `max_connections` still has room.
