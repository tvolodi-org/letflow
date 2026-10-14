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
`legacy_original/3`.

| Element | Shape |
|---|---|
| `@type route :: :rec \| :inst_start \| :inst_cancel \| :inst_rebind` | tokens `"rec"`, `"inst_start"`, `"inst_cancel"`, `"inst_rebind"` |
| `@spec raw_max(route() \| :script) :: 199 \| 162` | per route (ORCH): `rec`, `inst_start`, `:script` → 199; `inst_cancel`, `inst_rebind` → 162 = 255 - 93 (`"client:inst_cancel:"` 19 + actor 36 + `:` + instance 36 + `:`). The others' overhead is ≤ 56, so 199 fits. |
| `@spec client_key(route(), actor_id :: Ecto.UUID.t(), instance_id :: Ecto.UUID.t() \| nil, raw :: String.t()) :: String.t()` | `rec`/`inst_start` (instance nil): `"client:" <> token <> ":" <> actor <> ":" <> raw`. `inst_cancel`/`inst_rebind` (instance required): `"client:" <> token <> ":" <> actor <> ":" <> instance_id <> ":" <> raw`. `FunctionClauseError` on a wrong instance arity, a non-36-byte uuid, or an empty raw value or one over `raw_max/1`. |
| `@type resolved :: %{key: String.t(), legacy_raw: String.t() \| nil}` | `key` is stored; `legacy_raw` is K if supplied and not excluded by D3 (iv), else nil (`rec` only) |
| `@spec from_body(map(), route(), Ecto.UUID.t()) :: {:ok, resolved()} \| {:error, :idempotency_key_too_long}` | reads `attrs["idempotency_key"]`: absent gives `key: Ecto.UUID.generate()` (bare), `legacy_raw: nil`; ≤ `raw_max(:rec)` bytes gives `client_key(:rec, actor, nil, raw)`; more gives the error |
| `@spec from_header(Plug.Conn.t(), route(), Ecto.UUID.t(), Ecto.UUID.t() \| nil) :: {:ok, String.t()} \| {:error, :idempotency_key_too_long}` | first `idempotency-key` value; absent or `""` gives a bare UUID (today's rule, `instances.ex:1656`); otherwise limited by `raw_max(route)` and built by `client_key/4`. **No truncation** (N1). |
| `@spec script_key(term(), Ecto.UUID.t()) :: {:ok, String.t()} \| {:error, :invalid_idempotency_key}` | a non-empty binary of ≤ 199 bytes gives `"script:" <> actor_id <> ":" <> raw` |
| `@spec legacy_original(resolved(), actor_id :: Ecto.UUID.t(), [prefix: String.t()]) :: {:ok, Event.t()} \| :none` | D3, `rec` only |
| `@spec legacy_cutoff() :: DateTime.t()` | D3 (i) |
| `@spec too_long_error(:body \| :header) :: Letflow.Api.Validation.FieldError.t()` | the stable 422: `field` is `"idempotency_key"` for `:body` and `"idempotency-key"` for `:header`, with `constraint: "max_length"` and no `received` echo (`api/validation.ex:50`). The atom argument keeps both literals out of the routers, which the AC5 scan needs. |
| `@spec caller_prefixes() :: [String.t()]` / `server_prefixes() :: [String.t()]` | `["client:", "script:"]` / §1b verbatim |

The limit is counted in **bytes**. Since bytes ≥ codepoints ≥ graphemes and the overhead
is ASCII, a stored caller key never exceeds `varchar(255)` or `EventStore`'s check
(`event_store.ex:446-458`).

### D2. Boundaries call D1 (at the router, not in EventStore)

`EventStore.append/2`, `append_multi/3` and `append_platform_event/2` serve every writer.
`Records.create_record/2` is also called with server keys by `certificate.ex:335`,
`session.ex:1328`, `anti_cheat.ex:258`, the import (`entities.ex:1254`) and the seed task
(`:577`). The store cannot tell origin, so namespacing happens where caller input enters.

Order at each boundary: resolve the actor; resolve the key with D1 (too long gives a 422 via
`Validation.problem([too_long_error(:body | :header)])`); for `rec` only, run
`legacy_original/3`; then make the domain call.

- **C1/C2** `entities.ex`: delete `idempotency_key/1` (`:1090-1095`). Both handlers' `with`
  gains `{:ok, resolved} <- Idempotency.from_body(attrs, :rec, conn.assigns.auth_context.user_id)`.
  The command attrs then get `idempotency_key: resolved.key`, plus `legacy_original: event`
  when `legacy_original/3` returns `{:ok, event}` (D3).
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

### D3. Compatibility: constrained legacy lookup, `rec` only, for one release

**Scope (N8).** Only C1/C2 have real duplicate semantics, through Records'
`match_original/3`. C3-C5 do not, because the engine ignores `is_duplicate`. Start inserts
the projection before its append (`engine.ex:1718,1770`), so a same-key replay creates a
second instance with no `INSTANCE_STARTED` event. Cancel returns 409 on a replay. C3-C5 get
no lookup, so a pre-deploy key replayed there is a first write. The engine gap is
**pre-existing and out of scope**, tracked as **GH #2577**.

An unconstrained lookup of the bare key stays rejected, because server keys are stored
bare. `legacy_original/3` hits only if all of these hold:
- **(iv)** K starts with no `server_prefixes/0` entry and no `caller_prefixes/0` entry.
  This is checked in `from_body/3` with no I/O; otherwise `legacy_raw` is nil. The
  prefixes are public source, so the check leaks nothing.
- **One query** through
  `@spec EventStore.get_legacy_original(key :: String.t(), actor_id :: Ecto.UUID.t(), event_types :: [String.t()], before :: DateTime.t(), [prefix: String.t()]) :: {:ok, Event.t()} | {:error, :not_found}`.
  It joins `event_idempotency` to `events` on `(event_id, event_created_at)`, the shape of
  `resolve_duplicate/3` (`event_store.ex:678-692`), with these guards all in the `WHERE`:
  - **(i)** `created_at < before`, where `before` = `legacy_cutoff()`;
  - **(ii)** `actor_id = $actor`;
  - **(iii)** `event_type IN ('ENTITY_RECORD_CREATED','ENTITY_RECORD_UPDATED')`.

  It selects only `event_id, created_at, instance_id, event_type, actor_id, payload,
  global_seq`, which is what `match_original/3` and `duplicate_result/1` read
  (`records.ex:803-814,932-946`). Archived rows are not searched. It is one round-trip
  either way; the remaining sub-millisecond difference is within one tenant and is
  accepted.
- Guard (v), the instance match, is dropped, since N8 removes cancel/rebind.

**Hit path.** Records gains `optional(:legacy_original) => Event.t()` in
`create_attrs`/`update_attrs` (`records.ex:155,178`). In `run_command/2`, right after
`request_fingerprint/2` (`:377`), a present `legacy_original` skips the append. It returns
`match_original/3` mapped as in `interpret_result/3` (`:727-737`): the same result, or a
422 reuse.

**(i) Cutoff = the planned removal date (N6)**: the compile-time constant
`@legacy_cutoff ~U[2026-11-16 00:00:00.000000Z]`. A cutoff after deploy is safe: no bare
caller key is written after deploy, (iv) excludes every server and caller prefix, and the
other bare keys written after deploy are server-minted UUIDs that no caller sees
(`entities.ex:1051`, `session.ex:1070,1269,1333`, `anti_cheat.ex:268`).

Rejected alternatives: an app-env value (drifts per environment, misconfigures silently)
and a migration timestamp (there is no migration).

**N7 (removal, GH #2578).** Removal happens on or after #2550's production deploy date
plus one release. 2026-11-16 is a placeholder that is moved once the deploy date is known.
The `@legacy_cutoff` comment and the PR body cite #2578 and the date. The test
`"legacy cutoff is pinned"` asserts the date. #2578 deletes `legacy_original/3`,
`legacy_cutoff/0`, `get_legacy_original/5`, the Records attr, the hit path and the AC4
tests.

**Transaction, race, cost.** The read runs before the append transaction. Legacy rows
never change after deploy, so there is no check-then-act race, and
`uq_event_idempotency_key` still arbitrates the namespaced claim. A row moved by
`archive/1` (`event_store.ex:1215`) mid-request gives a first write. Cost: one indexed
query, only on `rec` with a supplied K that passes (iv).

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
cancels the projection even when its append was a duplicate (`engine.ex:6186-6224`). D3 (`rec` only) returns only
same-actor entity-record rows, never server or caller families, in one query.

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
| AC2 | D4 | **`rec` only**; C3-C5 have no replay semantics (#2577). POST twice with K: same `record_id`, +0 events. PUT twice with K: same result, +0 events. C6 `emit_event` twice: 1 event (EventStore dedupe). |
| AC3 | D2 | stay green: `scheduler_test`, `engine/timer_wiring_test`, `engine/human_task_escalation_test`, `engine/*escalation_timer_test`, `engine/service_task_dispatcher_test`, `engine/service_task_test`, `modules/exam/certificate_test`, `routers/entities_test` (`:2309`, `:3534`), `entities/records_test`, `repository/attachments_test`, `engine/pin_rebind_test`, `routers/instances_test`, `engine/lua/platform_test`, `engine_cancel_instance_test`, `simulation/seed_idempotency_test` |
| AC4 fixture | D3 | EventStore stamps `created_at` with now (`event_store.ex:243`), so legacy rows are inserted **directly via Repo** with `prefix:`. Insert one `%Event{}` with an ENTITY_RECORD_CREATED payload (`entity_type`, `record_id`, `field_values`, `entity_def_version` as hex) and an `instance_id` from `EntityTypeInstance.get_or_create/2`. Insert one `IdempotencyRecord.insert_changeset/2` row. Set `created_at`/`event_created_at` to `legacy_cutoff()` ± 1 day. Out-of-range dates land in `events_default` (`20260922000002_create_events_p_initial_partitions.exs:62`). |
| AC4 hit | D3 | `"legacy key, same actor, before cutoff → duplicate"` (cutoff − 1 day): POST `legacy-k`, get the fixture's `record_id`, +0 events |
| AC4 server | D3 (iv) | `"legacy server key from a client is not a duplicate"`: a server `timer_fired:<id>` row exists; a client POSTs that K and gets 201 with a new record; the server row is untouched |
| AC4 actor | D3 (ii) | `"legacy key from a different actor → not a duplicate"`: 201, +1 event |
| AC4 cutoff | D3 (i) | `"legacy row after the cutoff → ignored"` (cutoff + 1 day): 201, +1 event. Plus `"legacy cutoff is pinned"` (#2578 date). |
| AC5 per entry | D2 | one test each, asserting the stored key exactly: C1/C2 `client:rec:<actor>:K`, C3 `client:inst_start:<actor>:K`, C4 `client:inst_cancel:<actor>:<instance>:K`, C5 `client:inst_rebind:<actor>:<instance>:K`, C6 `script:<actor>:K` |
| cross-instance | D6 | `"same actor, same K, different instance on cancel → both cancels write INSTANCE_CANCELLED"`: cancel A then B with one K; each has its own `INSTANCE_CANCELLED` event and both return 200. Same shape for rebind: two `INSTANCE_PINS_REBOUND` events. |
| AC5 scan | D1 | `"caller key is read only in Idempotency"`: in `lib/**/*.ex` except `idempotency.ex` and `lib/letflow/design/`, fail on any **exact quoted literal** `"idempotency_key"` or `"idempotency-key"` (quotes included), reporting `file:line`. The allowlist holds only the `FieldConstraint` `name:` at `entities.ex:940`. Exact matching does not hit `"idempotency_key_reuse"`, `idempotency-key-reuse`, or the CORS header list (`cors.ex:78`, which is one longer string). It does catch `Map.get`, a `%{"idempotency_key" => k}` pattern match, and a `Map.take(…, ["idempotency_key"])` bypass. On main today it hits `entities.ex:1091` and `instances.ex:328`; D2 deletes both. |
| AC5 prefixes | D1 | caller and server prefixes don't overlap in either direction; every §1b literal is still present in its file and is listed |
| D5 | D5 | body 200 bytes → 422; 199-byte multibyte → 201 (stored ≤ 255 bytes). Start header 200 → 422. Cancel/rebind header 163 → 422 and 162 → 200 (stored ≤ 255 bytes). Each 422 has the same `max_length` problem body and appends no event. Script 300 → `invalid_arguments`. |

## 4. Blast radius, invariants, anti-patterns

- Files: `lib/letflow/idempotency.ex` (new), `routers/entities.ex`, `routers/instances.ex`,
  `engine/lua/platform.ex`, `event_store.ex` (one read, removed by #2578),
  `entities/records.ex` (one optional attr, removed by #2578). No migration.
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
- OQ-2 is closed (ORCH: cancel/rebind keys carry the instance id). Follow-ups: #2578, #2577.
