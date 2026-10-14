# GH #2550 — client idempotency keys get their own namespace

Status: design, rework 1 (validator B1-B4, N1-N4; supervisor ruling on legacy keys). Base:
origin/main 1465df2a (contains #2543). Gates: SECURITY-REVIEWER (INV-1, INV-5), REVIEWER.

## 0. Problem, verified

`event_idempotency.idempotency_key` is unique per tenant schema, with no origin column
(`priv/repo/migrations/20260816120006_create_event_idempotency.exs:59,66-69`). Every append
claims it (`event_store.ex:649-690`), and a duplicate returns the original (`:689`).

## 1. Inventory

### 1a. Caller-supplied keys that reach an append

| # | Entry point | Source | Read today | Reaches |
|---|---|---|---|---|
| C1 | `POST /entities/records/:type` | body `idempotency_key` | `routers/entities.ex:956,1090-1095` | `Records.create_record/2` |
| C2 | `PUT /entities/records/:type/:id` | body (same `idempotency_key/1`) | `entities.ex:1008` | `Records.update_record/2` |
| C3 | `POST /instances` | header `idempotency-key` | `routers/instances.ex:549,1653-1658` | `Engine.create/2` |
| C4 | `POST /instances/:id/cancel` | header (same `idempotency_key/1`) | `instances.ex:638` | `Engine.cancel_instance/3` |
| C5 | `POST /instances/:id/rebind-pins` | header (same) | `instances.ex:345,470` | `PinRebind.rebind_pins/3` |
| C6 | Lua `platform.emit_event(t, p, key)` | 3rd script argument | `engine/lua/platform.ex:805-826` | `EventStore.append/2` |

C6 is **unreachable in production** (empty grant set via `Platform.install/1`,
`engine/lua/sandbox.ex:276`, `platform.ex:85-87,392`; script VMs skip `Platform`,
`sandbox.ex:285`). It is namespaced defensively; tests use `install/3` with `event:emit`
(`test/letflow/engine/lua/platform_test.exs:1551+`).

Server-minted UUID, not caller-keyed: entity DELETE (`entities.ex:1051`), tasks
(`routers/tasks.ex:331`), exam (`session.ex:1070,1269,1333`, `anti_cheat.ex:268`), deadline
sweep (`record_deadline_sweep.ex:260`); onboarding/promotions ignore the header
(`onboarding.ex:118`, `promotions.ex:133`). No first-party client sends a key
(`web/src/api/instances.ts:59-60`, `apps/mobile`, `scripts/seed_vortex_entities.sh:37-38`).

### 1b. Server-built key families (exactly `server_prefixes/0`)

| Prefix | Site |
|---|---|
| `timer_fired:` | `engine.ex:2918`, `scheduler.ex:416` |
| `escalation_timer_fired:` | `engine.ex:3278` |
| `service_task_dispatch:` | `engine.ex:3869,3927` |
| `service_task:` | `engine/service_task.ex:495-499` (used by `service_task_dispatcher.ex:1265`) |
| `certificate:issue:` | `modules/exam/certificate.ex:340` |
| `entities-record-import:` | `routers/entities.ex:1263-1265` |
| `attachment_attached:`, `attachment_removed:` | `repository/attachments.ex:371,409` |
| `effect_applied:` | `ordering/consumer.ex:159` |
| `ordering_lag_exceeded:` | `ordering/metrics.ex:127-128` |
| `definition_promoted:`, `definition_version_rolled_back:`, `promotion_assertion_teardown_failed:` | `event_store/platform_events.ex:94,128,171` |
| `req345-seed-` | `lib/mix/tasks/letflow.seed.exam_fixtures.ex:286-412`ff, written via `Records.create_record/2` at `:577-582` |

Not listed: `promotion_rerun:` (`definitions.ex:2784`) keys another table,
`promotion_assertion_runs` (`:2843-2850`). Derived `<base>::sub_process_*::<uuid>` keys
(`engine/sub_process.ex:115-117,261-263`) keep the base first, so take the base's namespace.

**Certificate finding: another writer can block a candidate's certificate (not forgery).**
The issuer writes as `candidate_id` with `idempotency_match: :target`
(`certificate.ex:335-342`). `match_original/3` checks the actor first
(`entities/records.ex:803-814`), and `:CANDIDATE` holds no core permission
(`api/authorization.ex:1560`), so the candidate cannot forge one. Any other
`EntitiesRecordsWrite` holder (TENANT_ADMIN, PROCESS_OPERATOR) who knows a session id
(readable via EntitiesQuery) can POST a record keyed `certificate:issue:<sid>`. The
issuer's write then fails the actor check and gets `idempotency_key_reuse`, so that
certificate can never be issued.

## 2. Design

### D1. New module `Letflow.Idempotency` (`lib/letflow/idempotency.ex`)

This is the **only** reader and shaper of caller keys. Everything is pure except
`legacy_original/4`.

| Element | Shape |
|---|---|
| `@type route :: :rec \| :inst_start \| :inst_cancel \| :inst_rebind` | tokens `"rec"`, `"inst_start"`, `"inst_cancel"`, `"inst_rebind"` |
| `@spec raw_max(route() \| :script) :: 199 \| 162` | per route (ORCH): `rec`, `inst_start`, `:script` → 199; `inst_cancel`, `inst_rebind` → 162 = 255 - 93 (`"client:inst_cancel:"` 19 + actor 36 + `:` + instance 36 + `:`). The others' overhead is ≤ 56, so 199 fits. |
| `@spec client_key(route(), actor_id :: Ecto.UUID.t(), instance_id :: Ecto.UUID.t() \| nil, raw :: String.t()) :: String.t()` | `rec`/`inst_start` (instance nil): `"client:" <> token <> ":" <> actor <> ":" <> raw`. `inst_cancel`/`inst_rebind` (instance required): `"client:" <> token <> ":" <> actor <> ":" <> instance_id <> ":" <> raw`. `FunctionClauseError` on a wrong instance arity, a non-36-byte uuid, or an empty raw value or one over `raw_max/1`. |
| `@type resolved :: %{key: String.t(), legacy_raw: String.t() \| nil}` | `key` is stored; `legacy_raw` is K if supplied and not excluded by D3 (iv), else nil |
| `@spec from_body(map(), route(), Ecto.UUID.t()) :: {:ok, resolved()} \| {:error, :idempotency_key_too_long}` | reads `attrs["idempotency_key"]`: absent gives `key: Ecto.UUID.generate()` (bare), `legacy_raw: nil`; ≤ `raw_max(:rec)` bytes gives `client_key(:rec, actor, nil, raw)`; more gives the error |
| `@spec from_header(Plug.Conn.t(), route(), Ecto.UUID.t(), Ecto.UUID.t() \| nil) :: {:ok, resolved()} \| {:error, :idempotency_key_too_long}` | first `idempotency-key` value; absent or `""` gives a bare UUID (today's rule, `instances.ex:1656`); otherwise limited by `raw_max(route)` and built by `client_key/4`. **No truncation** (N1). |
| `@spec script_key(term(), Ecto.UUID.t()) :: {:ok, String.t()} \| {:error, :invalid_idempotency_key}` | a non-empty binary of ≤ 199 bytes gives `"script:" <> actor_id <> ":" <> raw` |
| `@spec legacy_original(resolved(), route(), Ecto.UUID.t(), [prefix: String.t(), instance_id: Ecto.UUID.t()]) :: {:ok, Event.t()} \| :none` | D3 |
| `@spec legacy_cutoff() :: DateTime.t()` | D3 (i) |
| `@spec too_long_error(String.t()) :: Letflow.Api.Validation.FieldError.t()` | the stable 422: `Validation.problem/1` with `field` = `"idempotency_key"` (body) or `"idempotency-key"` (header), `constraint: "max_length"`, no `received` echo (`api/validation.ex:50`) |
| `@spec caller_prefixes() :: [String.t()]` / `server_prefixes() :: [String.t()]` | `["client:", "script:"]` / §1b verbatim |

The limit is counted in **bytes**. Since bytes ≥ codepoints ≥ graphemes and the overhead
is ASCII, a stored caller key never exceeds `varchar(255)` or `EventStore`'s check
(`event_store.ex:446-458`).

### D2. Boundaries call D1 (at the router, not in EventStore)

`EventStore.append/2`, `append_multi/3` and `append_platform_event/2` serve every writer.
`Records.create_record/2` is also called with server keys by `certificate.ex:335`,
`session.ex:1328`, `anti_cheat.ex:258`, the import (`entities.ex:1254`) and the seed task
(`:577`). The store cannot tell origin, so namespacing happens where caller input enters.

Order at each boundary: actor, then D1 key (too long gives a 422 via
`Validation.problem([too_long_error(field)])`), then `legacy_original/4`, then the D3 hit
path or the domain call with `resolved.key`.

- **C1/C2** `entities.ex`: delete `idempotency_key/1` (`:1090-1095`). Both handlers' `with`
  gains `{:ok, resolved} <- Idempotency.from_body(attrs, :rec, conn.assigns.auth_context.user_id)`.
  The `FieldConstraint` (`:939-944`) keeps its type and `reject_empty_string` checks, with
  no `max_length`.
- **C3/C4/C5** `instances.ex`: delete `idempotency_key/1`, `truncate/2`,
  `trim_to_codepoint_boundary/1`, `@idempotency_key_header` and
  `@max_idempotency_key_bytes` (`:328-329,1653-1695`). Create uses
  `from_header(conn, :inst_start, auth_context.user_id, nil)`. Cancel uses `:inst_cancel`
  with the instance id from `cast_instance_id/1` (`:636-637`). Its `case` becomes a
  `with`. Rebind uses `:inst_rebind` with `instance_id` (`:461`), after `actor_id(conn)`
  (`:465`). The moduledoc convention (`:84-92`) is rewritten to "refuse over 199 bytes
  (162 on cancel/rebind), namespaced by route, actor and, for cancel/rebind, instance".
- **C6** `platform.ex:805-826`: `script_key(idempotency_key, execution_context.actor_id)`
  runs first, and an error gives `encode_error(lua, "invalid_arguments")`. `""` used to
  give `missing_idempotency_key`. There is no legacy lookup. The moduledoc must not quote
  `prefix: idempotency_key`, which `platform_test.exs:1624` greps for.

### D3. Compatibility: constrained legacy lookup for one release (supervisor ruling)

An unconstrained lookup of bare K is rejected, because server keys are stored bare.
`legacy_original/4` returns a hit **only if all** of these hold, checked in this order:
- **(iv)** K starts with no `server_prefixes/0` entry. This is checked inside
  `from_body`/`from_header` with no I/O, and a match sets `legacy_raw: nil`. The prefixes
  are public source, so this leaks nothing.
- **Lookup**: one query through the new
  `@spec EventStore.get_by_idempotency_key(String.t(), [prefix: String.t()]) :: {:ok, Event.t()} | {:error, :not_found}`.
  It is a single join of `event_idempotency` to `events` on `(event_id, event_created_at)`,
  the shape of `resolve_duplicate/3` (`event_store.ex:678-692`). One round-trip whether or
  not a row exists means no timing signal. Archived events give `:not_found`.
- **(i)** `event.created_at < legacy_cutoff()`.
- **(ii)** `event.actor_id == actor_id`.
- **(iii)** `event.event_type` is one the route produces:
  - `rec`: `ENTITY_RECORD_CREATED` or `ENTITY_RECORD_UPDATED`
  - `inst_start`: `INSTANCE_STARTED` (`engine.ex:2108`)
  - `inst_cancel`: `INSTANCE_CANCELLED` (`:6201`)
  - `inst_rebind`: `INSTANCE_PINS_REBOUND` (`pin_rebind.ex:470`)
- **(v)** cancel/rebind: `event.instance_id == opts[:instance_id]`. It is kept because bare
  legacy keys, unlike namespaced ones, carry no instance.

On `:none`, the request is a first write under `resolved.key`.

**Hit paths (pre-deploy semantics):**
- **C1/C2**: Records gets a new optional attr, `optional(:legacy_original) => Event.t()`,
  in `create_attrs`/`update_attrs` (`records.ex:155,178`). In `run_command/2`, right after
  `request_fingerprint/2` (`:377`), where a namespaced duplicate would surface, a present
  `legacy_original` skips the append and returns `match_original/3` (`:803-814`) mapped as
  in `interpret_result/3` (`:727-737`). The #2543 binding applies unchanged.
- **C3**: `Instances.get_by_id(event.instance_id, opts)` (`instances.ex:55`), then 201
  `{instance_id, status_string(status), created_at: event.created_at}`.
- **C4**: 200 `{instance_id, "CANCELLED"}`.
- **C5**: 200 via the `rebind_result_map/1` shape (`routers/instances.ex:1697-1713`):
  `changes` = `payload["entries"]` limited to `"kind"`, `"ref"`, `"prior_version"` and
  `"new_version"` (the payload's own four keys, `pin_rebind.ex:461-463`), and
  `rebound_at` = `event.created_at`.

**(i) Cutoff: a compile-time constant** `@legacy_cutoff`. ELIXIR-DEV sets it to 00:00 UTC
on the day after the merge (for example `~U[2026-10-17 00:00:00.000000Z]`) and states it in
the PR. It must be ≥ the deploy time.
Erring later is safe: after deploy no bare caller key is written, and later bare server
keys are excluded by (iv) or are minted UUIDs the caller never sees (`entities.ex:1051`,
`tasks.ex:331`, absent header). Rejected: app-env (drifts per environment, fails silently);
migration timestamp (this change has none, and it records authoring, not deploy, time).

**Transaction and race.** The lookup runs before the domain call, outside the append
transaction. Legacy rows are immutable after deploy, so there is no check-then-act race;
`uq_event_idempotency_key` still arbitrates the namespaced claim. Concurrent replays hit the
same original. A row moved by `archive/1` (`event_store.ex:1215`) mid-request gives a first write.

**Cost.** One indexed lookup, only when a supplied K passes (iv).

**Removal.** After one release, delete `legacy_original/4`, `legacy_cutoff/0`,
`get_by_idempotency_key/2`, the Records attr and the hit paths. ORCH files the follow-up
"GH #2550 follow-up: remove the legacy idempotency-key lookup after one release". The test
`"legacy cutoff is pinned"` asserts the exact literal.

### D4. #2543 binding

The fingerprint (`records.ex:783-791`) excludes the key; a same-actor replay maps to the
same `client:rec:<actor>:K` and takes the duplicate path. Create-then-update with one K
still gives 422 reuse (C1 and C2 share `rec` for this). Another actor's K is a separate
write. Import, certificate `:target` and seed are unchanged. The only Records change is D3's attr.

### D5. Length budget

| Layer | Before | After |
|---|---|---|
| Column, changeset, EventStore | 255 | unchanged |
| C1/C2 body (`rec`) | none; > 255 gave a 500 via `entities.ex:1435-1438` | > 199 bytes: 422 `max_length` |
| C3 header (`inst_start`) | truncated to 255 bytes | > 199 bytes: 422 `max_length` (N1) |
| C4/C5 header (`inst_cancel`, `inst_rebind`) | truncated to 255 bytes | > 162 bytes: 422 `max_length` (N1) |
| C6 | 255 at EventStore | > 199 bytes: `invalid_arguments` |

### D6. Collision and oracle (INV-5)

Keys are `client:<route>:<actor>:<K>`, `client:<inst_cancel|inst_rebind>:<actor>:<instance>:<K>`
or `script:<actor>:<K>`, so a collision needs the same actor, route and K, plus the same
instance on cancel/rebind. A caller cannot name a server key (nor an import key, whose UUID
is minted per call, `entities.ex:1125`, never returned), cannot probe another user's keys,
and instance routes cannot collide with each other, with records, or across instances.
That matters because C3-C5 have no binding: the engine ignores `is_duplicate`, and cancel
cancels the projection even when its append was a duplicate (`engine.ex:6186-6224`). D3 only returns same-actor
rows of the route's own types, never server families, in one constant query.

## 3. AC map and tests

Files: `test/letflow/idempotency_test.exs` (unit, scan); `test/letflow/client_key_namespace_test.exs` (real Postgres, `async: false`).

| AC | Design | Test |
|---|---|---|
| AC1 timer | D2 | `"squat timer_fired:"`: POST a record with K = `timer_fired:<timer.id>`, fire via `Scheduler` (`scheduler.ex:410-419`). Assert a `TIMER_FIRED` event keyed `timer_fired:<id>` and the instance advanced. Repeat via the `POST /instances` header and via `emit_event`. |
| AC1 escalation | D2 | same shape, using the fixture from `engine/human_task_escalation_test.exs` |
| AC1 dispatch | D2 | squat `service_task_dispatch:<id>` and `service_task:` (attempt 0), run the dispatcher, assert completion |
| AC1 certificate | §1b | `"another writer squats certificate:issue:<sid>, issuance still succeeds"`: a PROCESS_OPERATOR POSTs first; the candidate then gets 200 with server-computed values and a different record |
| AC1 import | D6 | StreamData: `client_key/4` never starts with a `server_prefixes/0` entry. Then import an entry and POST its stored key as K: 201, new record. |
| AC1 attachment (N3) | D2 | squat `attachment_removed:<id>`, remove the attachment, assert an `ATTACHMENT_REMOVED` event |
| AC2 | D4 | POST twice with K: same `record_id`, +0 events. Cancel twice: second is 409 (`:661`), +0 events. `emit_event` twice: 1 event. |
| AC3 | D2 | stay green: `scheduler_test`, `engine/timer_wiring_test`, `engine/human_task_escalation_test`, `engine/*escalation_timer_test`, `engine/service_task_dispatcher_test`, `engine/service_task_test`, `modules/exam/certificate_test`, `routers/entities_test` (`:2309`, `:3534`), `entities/records_test`, `repository/attachments_test`, `engine/pin_rebind_test`, `routers/instances_test`, `engine/lua/platform_test`, `engine_cancel_instance_test`, `simulation/seed_idempotency_test` |
| AC4 hit | D3 | `"legacy key, same actor, in window → duplicate"`: insert with bare `legacy-k` (`created_at` before the cutoff), POST `legacy-k`: same `record_id`, +0 events. Likewise cancel → 200 with +0 events, and rebind → 200 with the original `changes`. |
| AC4 server | D3 (iv) | `"legacy server key from a client is not a duplicate"`: a server `timer_fired:<id>` event exists; a client POSTs that K and gets 201 with a new record. The `event_idempotency` row for `timer_fired:<id>` is unchanged. |
| AC4 actor | D3 (ii) | `"legacy key from a different actor → not a duplicate"`: 201, +1 event |
| AC4 cutoff | D3 (i) | `"legacy row after the cutoff → ignored"`: row `created_at` ≥ cutoff, so 201, +1 event. Plus `"cutoff on another instance → ignored"` (v) and `"legacy cutoff is pinned"` |
| AC5 per entry | D2 | one test each, asserting the stored key exactly: C1/C2 `client:rec:<actor>:K`, C3 `client:inst_start:<actor>:K`, C4 `client:inst_cancel:<actor>:<instance>:K`, C5 `client:inst_rebind:<actor>:<instance>:K`, C6 `script:<actor>:K` |
| cross-instance | D6 | `"same actor, same K, different instance on cancel → both cancels write INSTANCE_CANCELLED"`: cancel A then B with one K; each has its own `INSTANCE_CANCELLED` event and both return 200. Same shape for rebind: two `INSTANCE_PINS_REBOUND` events. |
| AC5 scan | D1 | `"caller key is read only in Idempotency"`: scan `lib/**/*.ex` except `idempotency.ex` and `lib/letflow/design/`. Fail on `"idempotency-key"` except `plugs/cors.ex:78`. Fail on `Map.get(`/`Map.fetch(`/`[` reads of `"idempotency_key"` and on `get_req_header(`. A `FieldConstraint name:` is allowed. Each failure reports `file:line`. |
| AC5 prefixes | D1 | caller and server prefixes don't overlap in either direction; every §1b literal is still present in its file and is listed |
| D5 | D5 | body 200 bytes → 422; 199-byte multibyte → 201 (stored ≤ 255 bytes). Start header 200 → 422. Cancel/rebind header 163 → 422 and 162 → 200 (stored ≤ 255 bytes). Each 422 has the same `max_length` problem body and appends no event. Script 300 → `invalid_arguments`. |

## 4. Blast radius, invariants, anti-patterns

- Files: `lib/letflow/idempotency.ex` (new), `routers/entities.ex`, `routers/instances.ex`,
  `engine/lua/platform.ex`, `event_store.ex` (one new read), `entities/records.ex` (one
  optional attr). No migration.
- **INV-1**: prefix and actor come from `auth_context` server-side (`entities.ex:948`,
  `instances.ex:544`); the legacy read uses the same prefix. **INV-5**: D6. **INV-8**: an
  over-long body key goes from a 500 to a 422.
- Anti-patterns: *"…applied to two of three sibling code paths, not all three"* and *"A
  gate-approved design … missed a sibling write path…"*: one reader, the scan, the
  per-entry tests. *"A grep-shaped acceptance criterion can be tripped by the module's own
  moduledoc…"*: the scan excludes `idempotency.ex`; other moduledocs must not quote read shapes.

## 5. Open questions

- **OQ-1** (SECURITY-REVIEWER): audit existing `certificate:issue:*` events whose
  `actor_id` ≠ the session's candidate (blocking squats). A candidate's own forgery could
  only be found by comparing record values with the session, and it cannot happen while
  `:CANDIDATE` lacks `EntitiesRecordsWrite`.
- OQ-2 is closed by ORCH: cancel/rebind keys carry the instance id (D1, D6).
