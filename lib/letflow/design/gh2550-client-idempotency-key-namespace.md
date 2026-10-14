# GH #2550 — client idempotency keys get their own namespace

Status: design (CODE-DESIGNER). Base: origin/main 1465df2a (contains #2543).
Gates: SECURITY-REVIEWER (INV-1, INV-5), REVIEWER. Design only, no implementation code.

## 0. Problem, verified

`event_idempotency.idempotency_key` is unique per tenant schema, with no origin column
(`priv/repo/migrations/20260816120006_create_event_idempotency.exs:59,66-69`,
`lib/letflow/event_store/idempotency_record.ex:69,88-89`). Every append claims it in
`claim_idempotency/3` (`lib/letflow/event_store.ex:649-690`). A duplicate returns the
original event (`event_store.ex:689`). Caller-chosen keys and server-built keys therefore
collide, and a caller who knows a server key can claim it first.

## 1. Inventory (settles brief item 1)

### 1a. Caller-supplied keys that reach an append (all of them)

| # | Entry point | Source | Where | Reaches |
|---|---|---|---|---|
| C1 | `POST /entities/records/:type` | body `idempotency_key` | `routers/entities.ex:937-945,956,1090-1095` | `Records.create_record/2` |
| C2 | `PUT /entities/records/:type/:id` | body `idempotency_key` | `routers/entities.ex:986,1008` | `Records.update_record/2` |
| C3 | `POST /instances` | header `idempotency-key` | `routers/instances.ex:328-329,549,1653-1658` | `Engine.create/2` |
| C4 | `POST /instances/:id/cancel` | header `idempotency-key` | `routers/instances.ex:638` | `Engine.cancel_instance/3` |
| C5 | `POST /instances/:id/rebind-pins` | header `idempotency-key` | `routers/instances.ex:345,470` | `PinRebind.rebind_pins/3` (`engine/pin_rebind.ex:473`) |
| C6 | Lua `platform.emit_event(t, p, key)` | 3rd script argument | `engine/lua/platform.ex:805-826` | `EventStore.append/2` |

Not caller-keyed (server mints `Ecto.UUID.generate/0`, unpredictable): entity DELETE
(`entities.ex:1051`), task completion (`routers/tasks.ex:331`), exam session/anti-cheat
(`modules/exam/session.ex:1070,1269,1333`, `anti_cheat.ex:268`), deadline sweep
(`scheduler/record_deadline_sweep.ex:260`). Onboarding and promotions do not read the
header (`routers/onboarding.ex:118`, `routers/promotions.ex:133`). The exam certificate
route takes no key (`modules/exam/router.ex:187-197`). No first-party client sends a key:
`web/src` sets none (`web/src/api/instances.ts:59-60`), `apps/mobile` has no hit, and
`scripts/seed_vortex_entities.sh:37-38` relies on server-minted keys.
Keys derived from a C3-C5 base keep the base as their first segment
(`engine/sub_process.ex:261-263`, `Enum.join([base, suffix | ids], "::")`), so they stay
in whatever namespace the base is in.

### 1b. Server-built key families (issue list verified, missing ones added)

| Family prefix | Site | In issue? |
|---|---|---|
| `timer_fired:` | `engine.ex:2918`, `scheduler.ex:416` | yes (lines moved) |
| `escalation_timer_fired:` | `engine.ex:3278` | yes |
| `service_task_dispatch:` | `engine.ex:3869,3927` | yes |
| `certificate:issue:` | `modules/exam/certificate.ex:340` | yes |
| `entities-record-import:` | `routers/entities.ex:1263-1265` | yes |
| `service_task:` | `engine/service_task.ex:495-499`, used by `service_task_dispatcher.ex:1265` | **missing** |
| `attachment_attached:` / `attachment_removed:` | `repository/attachments.ex:371,409` | **missing** |
| `effect_applied:` | `ordering/consumer.ex:159` | **missing** |
| `ordering_lag_exceeded:` | `ordering/metrics.ex:127-128` | **missing** (platform) |
| `promotion_rerun:` | `definitions.ex:2784` | **missing** |
| `definition_promoted:`, `definition_version_rolled_back:`, `promotion_assertion_teardown_failed:` | `event_store/platform_events.ex:94,128,171` | **missing** (platform) |
| `<server base>::sub_process_*::<uuid>` | `engine/sub_process.ex:115-117,653,756,1358` | **missing** (derived) |

`attachment_removed:<attachment id>` is the most exposed missing family: the id is
returned to the client. `certificate:issue:` is the most severe: the issuer uses
`idempotency_match: :target` (`certificate.ex:341`), which skips the `field_values`
compare (`entities/records.ex:794`). A candidate who may write `certificate` records
could create one with forged `field_values` under `certificate:issue:<own session>`.
`match_original/3` (`records.ex:803-814`) would then accept it as the issued certificate.

## 2. Design

### D1. New module `Letflow.Idempotency` (`lib/letflow/idempotency.ex`)

Pure functions only, with no I/O and no Repo access.

| Element | Shape |
|---|---|
| `@client_prefix` | `"client:"` (7 bytes, 7 codepoints) |
| `@script_prefix` | `"script:"` (7 bytes) |
| `@stored_max` | `255` (column / `event_store.ex:124`) |
| `@spec client_key(String.t()) :: String.t()` | returns `@client_prefix <> key`; `FunctionClauseError` on a non-binary or `""` (callers guarantee non-empty) |
| `@spec script_key(String.t()) :: String.t()` | returns `@script_prefix <> key`; same guard |
| `@spec raw_max_length() :: 248` | `@stored_max - byte_size(@client_prefix)`; both prefixes are 7 bytes, and a compile-time assertion pins that equality |
| `@spec caller_prefixes() :: [String.t()]` | `["client:", "script:"]` |
| `@spec server_prefixes() :: [String.t()]` | every family in §1b, verbatim, as the check test's source of truth |

Two prefixes, not one. HTTP callers and tenant scripts are different principals. With one
prefix, a script key `x` and an HTTP key `x` would collide with each other.

### D2. Where the namespace is applied, and why at the boundary

The prefix is applied at each caller boundary (C1-C6), never inside `EventStore`.
`EventStore.append/2`, `append_multi/3` and `append_platform_event/2` are shared by every
writer, client-keyed and server-keyed alike. The same `Engine.create/2`,
`cancel_instance/3` and `Records.create_record/2` are also reached by server callers
(`certificate.ex:335`, `session.ex:1328`, the import). The store cannot tell origin, so a
store-side rule would need a new origin flag threaded through roughly 40 call sites. Six
boundaries, each calling one central function, is smaller and greppable (the AC5 check test pins it).

Step order at each boundary is: validate the raw key, then apply the prefix, then make the
domain call. Router-minted UUIDs (absent key) stay **unprefixed**, because they are
server-random and unchanged from today.

- **C1/C2** (`routers/entities.ex`): the `"idempotency_key"` `FieldConstraint`
  (`:939-944`) gains `max_length: 248` (via `Idempotency.raw_max_length/0`). The present
  branch of `idempotency_key/1` (`:1092`) returns `Idempotency.client_key(key)`, and the
  nil branch stays `Ecto.UUID.generate()`. Because `@record_update_schema` is
  `@record_write_schema ++ [...]` (`:986`), C2 inherits the change.
- **C3/C4/C5** (`routers/instances.ex`): `@max_idempotency_key_bytes` (`:329`) becomes
  `Idempotency.raw_max_length()` (248). The present branch of `idempotency_key/1`
  (`:1655`) returns `Idempotency.client_key(truncate(value, 248))`. `truncate/2` keeps its
  codepoint-boundary walk (`:1674-1680`). The moduledoc convention paragraph (`:84-86`) is
  updated to say the key is truncated to 248 bytes and namespaced.
- **C6** (`engine/lua/platform.ex:819`): `idempotency_key: Idempotency.script_key(idempotency_key)`.
  The guard `is_binary(idempotency_key)` (`:806`) allows `""`. Add `byte_size(idempotency_key) > 0`
  to that guard so `""` falls to the existing `invalid_arguments` clause (`:828-830`) instead
  of becoming the valid key `"script:"`. Today `""` reaches `EventStore`, which returns
  `missing_idempotency_key` (`event_store.ex:455-456`). The Lua error string therefore
  changes from `missing_idempotency_key` to `invalid_arguments`, and the call still fails
  with no event appended. Test: `"empty script key is invalid_arguments"`.
  Moduledoc (`:187-197`) gains one sentence on the namespace. That sentence must not
  contain the literal `prefix: idempotency_key`, which `test/letflow/engine/lua/platform_test.exs:1624`
  greps for.

Server writers are untouched. They build their keys from literals that never start with
`client:`/`script:`, and the AC5 check test pins this.

### D3. Compatibility: Option A (prefix only, no legacy lookup)

A key stored before deploy stays bare. A pre-deploy request replayed after deploy is
claimed as `client:K`, which is a first write. Effects per route:

| Route | Effect of a cross-deploy replay |
|---|---|
| C1 create | a second record (new `record_id`) |
| C2 update | a second `ENTITY_RECORD_UPDATED` with the same values (same end state) |
| C3 start | a second instance, unless `correlation_key` gives 409 (`instances.ex:608-613`) |
| C4 cancel | `{:instance_already_terminal, :cancelled}`, so the existing `render_cancel` clause (`instances.ex:661`) applies, not a 200 replay; no duplicate event |
| C5 rebind | a second rebind of the same pins |
| C6 Lua | a second script event on a re-run that straddles the deploy |

Exposure window: only a request whose first attempt landed before deploy and whose
retry lands after it. First-party clients send no key (§1a), so their exposure is zero.
For third-party API clients, the window is the client's own retry horizon across one
deploy (seconds to minutes).

Option B (look up the bare legacy `K` before writing) is **rejected**:
1. Stored keys carry no origin marker. A lookup of bare `K` cannot tell a legacy client
   key from a server key, so `client_key("timer_fired:<id>")` with a legacy fallback would
   again hit the server event. That brings back both the squat on the read side (the
   `:target` certificate case returns the server's record) and the INV-5 oracle
   (422 reuse vs 201).
2. Cost and race: one extra indexed read per keyed write, outside the claim's
   transaction (`event_store.ex:649-690`), so it is a check-then-act that is not atomic.
3. A cutoff by `inserted_at` would fix point 1 only partly and permanently adds a
   deploy-time constant. That is not worth a window that is zero for first-party clients.

### D4. Interaction with #2543

There is no code change in `entities/records.ex`. The fingerprint (`records.ex:783-791`)
does not include the key. `match_original/3` (`:803-814`) compares event_type, actor,
entity_type, record_id and field_values against the original, which is found by the
already-namespaced key (`interpret_result/3`, `:727-737`). A same-request replay of `K`
maps to the same `client:K`, so the duplicate path and result are unchanged, and
`idempotency_key_reuse` keeps its semantics. Import (`:1242-1265`) and certificate
`:target` (`certificate.ex:340-341`) keys are unchanged.

### D5. Length limits

| Layer | Limit today | After |
|---|---|---|
| column `varchar(255)` / changeset | 255 (`idempotency_record.ex:88`) | unchanged |
| `EventStore.fetch_idempotency_key/1` | 255 graphemes (`event_store.ex:446-458`) | unchanged |
| C1/C2 body | **none**: a key over 255 reaches `append_multi` and gives `:idempotency_key_too_long`, which falls to the 500 catch-all (`entities.ex:1435-1438`) | `max_length: 248` gives a 422 field error (`api/validation.ex:352-358`) |
| C3-C5 header | truncate to 255 bytes | truncate to 248 bytes, then the 7-byte prefix gives ≤ 255 bytes |
| C6 Lua | 255 at `EventStore` | 248 raw; 249-255 now returns Lua error `idempotency_key_too_long` |

Behaviour change: body keys of 249-255 graphemes go from 201 to 422, and header keys that
share their first 248 bytes now dedupe together (before, 255 bytes). Both are
documented in the PR.

### D6. Import key (brief item 6)

`entities-record-import:<uuid>:<inspect(source id)>`. The UUID is minted per call
(`entities.ex:1125`) and never returned (`:1129`). After D2, every C1/C2 key starts with
`client:`, so no client value can equal a key that starts with `entities-record-import:`.
The `source_record_id` part is client input, but it sits after a server UUID the client
cannot know.

### D7. Existence oracle (INV-5, brief item 7)

After D2, a caller only ever probes `client:*` (or `script:*`) keys. Server keys can no
longer be named, so `201` vs `422 idempotency_key_reuse` reveals nothing about timers,
dispatches, certificates, attachments or imports. One leak stays: within one tenant, a
user can learn that **another user** used client key `K` (#2543's actor binding gives
422). This is same-tenant, not cross-tenant, so INV-5 (a cross-tenant rule) is not
violated. It is recorded as OQ-2.

## 3. AC map and tests

New files: `test/letflow/idempotency_test.exs` (unit + check) and
`test/letflow/client_key_namespace_test.exs` (integration, real Postgres, `async: false`).

| AC | Design | Test (describe / name) |
|---|---|---|
| AC1 timer | D2 C1, C3 | `"squat timer_fired: client key first, timer still fires"`: arm a timer, POST an entity record with key `timer_fired:<timer.id>`, fire via `Letflow.Scheduler` (`scheduler.ex:410-419`). Assert a `TIMER_FIRED` event keyed `timer_fired:<id>` exists, the instance advanced, and the client event key is `client:timer_fired:<id>`. Second variant: same key sent as the `idempotency-key` header on `POST /instances`. |
| AC1 escalation | D2 | `"squat escalation_timer_fired:"`: same shape, escalation fixture as in `engine/human_task_escalation_test.exs` |
| AC1 dispatch | D2 | `"squat service_task_dispatch:"` and `"squat service_task:"`: squat `service_task_dispatch:<dispatch.id>` and `ServiceTask.build_idempotency_key/4` for attempt 0, run the dispatcher, assert the completion event and the instance advanced |
| AC1 certificate | D2, §1b | `"squat certificate:issue: forged record is not returned"`: the candidate POSTs `certificate` with key `certificate:issue:<session>` and forged values, then issues. Assert the issued record's `field_values` are server-computed and its `record_id` differs from the forged one |
| AC1 import | D6 | `"import keys are unreachable from the client namespace"`: StreamData property, `client_key(s)` never starts with any `server_prefixes/0` entry. Plus: import one entry, read its stored key, POST it as a client key, and get 201 with a new record (no dedupe onto the import) |
| AC1 Lua | D2 C6 | `"squat via platform.emit_event"`: the script emits with key `timer_fired:<id>`, the timer still fires |
| AC2 | D4 | `"same-request replay stays idempotent"`: POST twice with key `k`, same `record_id`, event count +0; Lua `emit_event` twice with `k`, one event |
| AC3 | D2 (server sites untouched) | suites that stay green: `scheduler_test.exs`, `engine/timer_wiring_test.exs`, `engine/human_task_escalation_test.exs`, `engine/*escalation_timer_test.exs`, `engine/service_task_dispatcher_test.exs`, `engine/service_task_test.exs`, `modules/exam/certificate_test.exs`, `routers/entities_test.exs` (REQ-320 import, `:2309`; GH #2543, `:3534`), `entities/records_test.exs`, `repository/attachments_test.exs`, `engine/pin_rebind_test.exs`, `routers/instances_test.exs`, `engine/lua/platform_test.exs`, `engine_cancel_instance_test.exs` |
| AC4 | D3 | `"legacy bare key is not consulted (Option A)"`: write a record via `Records.create_record/2` with bare key `legacy-k`, then POST with `legacy-k`. Assert 201, a new `record_id`, event count +1 |
| AC5 | D1, D2 | `idempotency_test.exs` `"server prefixes never overlap caller prefixes"`: no `server_prefixes/0` entry starts with a `caller_prefixes/0` entry, and vice versa. `"every server family literal is pinned"`: reads each §1b file and asserts its literal is present and listed. `"every caller boundary namespaces"`: `entities.ex` and `instances.ex` contain `Idempotency.client_key(`, `platform.ex` contains `Idempotency.script_key(` |
| D5 | D5 | `"249-char body key is 422 max_length"`, `"248-char key gives 201, stored length 255"`, `"300-byte header truncates to a stored key ≤ 255 bytes, valid UTF-8"` |

## 4. Blast radius, invariants, anti-patterns

- Files changed: `lib/letflow/idempotency.ex` (new), `routers/entities.ex`,
  `routers/instances.ex`, `engine/lua/platform.ex`. No migration, no schema change,
  no `EventStore` or `Records` change.
- **INV-1**: the namespace is applied after the tenant prefix is derived server-side
  (`entities.ex:948`, `instances.ex:544`). The key never selects a schema. The sidecar
  stays per tenant (migration `:56-57`).
- **INV-5**: §D7. The 422/201 difference is now confined to caller namespaces.
- **INV-8**: D5 turns a reachable 500 (an over-long body key) into a 422.
- Anti-patterns: *"An established template-substitution mechanism applied to two of
  three sibling code paths, not all three"* and *"A gate-approved design fixing a shared
  write function missed a sibling write path…"*: C1-C6 are all listed, and the AC5 check
  test fails if any boundary loses its call. *"A grep-shaped acceptance criterion can be
  tripped by the module's own moduledoc…"*: the AC5 source scan matches call shapes
  (`Idempotency.client_key(`), and moduledocs must not quote them, the same rule as the
  existing Lua `prefix: idempotency_key` scan.

## 5. Open questions

- **OQ-1** (SECURITY-REVIEWER): the certificate forgery path (§1b) exists on main today if
  any role holds `EntitiesRecordsWrite` on `certificate`. D2 closes it. Confirm whether a
  separate issue is needed to audit records already stored under `certificate:issue:*`
  whose event actor or values were not written by the issuer.
- **OQ-2**: same-tenant, cross-user client-key probing (§D7) remains, by #2543's design.
  Accept, or bind the namespace per actor (`client:<actor_id>:K`, which costs about 44
  bytes of key budget)? This design accepts it, because it is not an INV-5 violation.
- **OQ-3**: a client could pre-claim `client:K::sub_process_start::<uuid>`, but the
  suffix carries a freshly minted child UUID (`sub_process.ex:645-651`), so it is not
  predictable. No action.
- **OQ-4** (pre-existing, not widened): limits are counted in graphemes
  (`validation.ex:341`, `event_store.ex:449`), but `varchar(255)` counts codepoints, so a
  248-grapheme key made of combining sequences can still reach Postgres and give a 500.
  This should be a separate issue, not this one.
