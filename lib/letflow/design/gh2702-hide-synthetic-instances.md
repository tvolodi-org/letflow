# GH #2702 design: hide synthetic entity-type instances from every Instances route

Status: DESIGN (CODE-DESIGNER, 2026-10-17T01:19Z). Priority 1, SECURITY (PR-0b). Design only, no implementation code.
Source: GH #2702 body (binding, advisor option A), `handoffs/WF02-GH2702-INSTANCES-SYNTHETIC-20261017/step-01-leak-repro.json`.
Reproducing test (ships with this PR): `test/letflow/routers/instances_restricted_field_events_test.exs` (13 tests, 8 fail on main).
No decision record (it closes already-written events with no data change). Option B (read-time redaction with
`FieldPolicy.redact` on a dedicated record history route) is a different PR (REQ-516 / #2701) and out of scope.

CONSEQUENCE to state in the PR body: until REQ-516 lands, NO role can read record create/update history through
`/instances` (TENANT_AUDITOR included; TENANT_AUDITOR loses record history visibility meanwhile). Past exposure
is not repaired by this PR (events already written are unchanged); audit holds mutations only, so past reads cannot be established.

## 0. Findings from reading the code

F1. Synthetic instance anatomy. `EntityTypeInstance.get_or_create/2` (`lib/letflow/entities/entity_type_instance.ex:93-155`)
inserts the `entity_type_instances` row FIRST (PK `entity_type`, `instance_id NOT NULL`, no index on `instance_id`),
then the matching `instance_projections` row (`status :active`, `definition_id = instance_id`). The projection row is
never updated or deleted afterwards by any client path. Therefore "is synthetic" is immutable from the moment the
projection exists (no TOCTOU between a guard and a later engine call). No flag column exists on the projection.

F2. Read stack (all in `lib/letflow/instances.ex`): `get_by_id/2` (`Repo.get`, :56-69), `list/2` (:87-109, no
exclusion), `history/3` and `timeline/3` (both `ensure_instance_exists/2`, :357-365, then an `events` query by id).
`ensure_instance_exists/2` is the ONLY existence gate for history and timeline: patching it covers both. No non-router
lib caller of these four functions exists (grep: only `lib/letflow/routers/instances.ex`; the rest are docs and tests
with real instances: `engine_complete_task_test`, `attachments_test`, simulation `req207/req208` and `runner.ex`).

F3. Router routes (`lib/letflow/routers/instances.ex`, `authz_*` gate runs BEFORE the handler, so permission precedes
existence everywhere; a caller lacking the permission gets the same 403 for synthetic and nonexistent ids; no new
oracle): GET `/`, `/:id`, `/:id/history`, `/:id/timeline`, `/:id/pins`, `/:id/attachments`,
`/:id/attachments/:attachment_id`, `.../link-content`, `/storage-usage`; POST `/`, `/:id/rebind-pins`, `/:id/cancel`,
`/:id/reconstruct`, `/:id/advance-timer`, `/:id/attachments`, `.../link`; DELETE `.../:attachment_id`.

F4. Mutating routes today act on a synthetic id (not just read):
- cancel: `Engine.fetch_and_lock_instance_projection_for_cancel/3` (`engine.ex:8616`) finds the row and cancels it, a
  DoS on every later record write for that entity type.
- reconstruct: `Reconstruction.reconstruct_instance/2` (`reconstruction.ex:281`) reads the log, then `replay/4`
  (:491-516) first calls `SnapshotStore.get_by_instance_id/2` (`snapshot_store.ex:139`, a `Repo.get` on
  `InstanceDefinitionSnapshot`). Verified: nothing under `lib/letflow/entities/` or `lib/letflow/event_store*` references
  `SnapshotStore`/`InstanceDefinitionSnapshot`, so a synthetic instance has no graph snapshot. With a non-empty log the
  result is `{:error, {:replay_failed, {:snapshot_unavailable, :snapshot_not_found}}}`, which the router renders as a 500
  (`render_reconstruct` internal clause); NO write_back happens (replay fails before it). A nonexistent id has an empty log
  and gets `:instance_not_found` -> 404. So today's defect is a 500-vs-404 EXISTENCE ORACLE, not a projection rewrite.
  The platform sentinel is the same: once any platform event exists its log is non-empty, it has no snapshot and no
  projection, and reconstruct gates on neither, so it also answers 500 (same oracle).
- rebind-pins: `PinRebind.lock_projection_nowait/3` (`pin_rebind.ex:426-440`) finds the row; the request is then
  refused later with 422 `unknown_pin_ref` (a DIFFERENT status than a nonexistent id, an existence oracle).
- pins: `PinResolver.reconstruct_effective_pins/2` (`pin_resolver.ex:766`) returns `:instance_not_found` when no
  `INSTANCE_STARTED` event exists, so the synthetic id already 404s, by accident of event content.
- advance-timer: `Scheduler.resolve_advance_target/3` finds no pending timer for a synthetic id, already `404`
  (`:no_pending_timer`), by accident of data.
- attachments (`lib/letflow/repository/attachments.ex`): NO existence check at all and no FK on `instance_id`
  (`instance_attachments` references only `repository_artifacts`). list of a synthetic id and of a nonexistent id are
  both 200 empty; upload to either succeeds. They are already identical; nothing of the synthetic instance leaks.

F5. Platform sentinel `EventStore.platform_instance_id()` (`event_store.ex:991-1003`): its own doc and
`priv/repo/migrations/20260816120001_create_events.exs:44` state it is NEVER inserted into `instance_projections`;
`/platform-events` filters on it (`event_store.ex:1281-1300`). Every Instances route gates on the projection row (or
on an event log that holds no `INSTANCE_STARTED`), so it already answers 404 like a nonexistent id. VERDICT: not in
scope for the predicate; covered by one regression assertion in the route walk (section 6) so a future change that
seeds a sentinel projection fails loudly.

F6. Other readers of `instance_projections` examined, none client-reachable with a synthetic id and none changed:
`Tasks`/`routers/tasks.ex` (left join / not-active check on a task's own instance; a synthetic instance has no tasks),
`Engine.Lua.Platform.fetch_instance_state` (`platform.ex:664`; only the script's OWN `execution_context.instance_id`),
`Lua emit_event` (appends to the script's own instance only), `Obs.Alerts` (counts ERROR instances; synthetic are
`:active`), `ServiceCatalog` (non-terminal instances with frozen pins; synthetic have no snapshot), `Scheduler`, `SubProcess`,
`TenantProvisioning`. Telemetry (`[:letflow, :event_store, :append]` span metadata `%{}`) and Logger carry no payloads
(grep of `records.ex`, `event_store.ex`, `projector.ex`). Webhooks/DLQ/audit/read_global/`/platform-events`: per the
consumer checklist, no production path feeds entity event payloads out; unchanged.
Reachability of `Letflow.Instances.*` or `reconstruct_*` by a Lua script or module code: none found.

F7. Layering. `mix letflow.check_boundaries` Rule 6 forbids `Engine.*` referencing `Letflow.Entities.*`. The engine
lock queries therefore cannot alias `Letflow.Entities.EntityTypeInstance`. The shared predicate must sit below both.

F8. ORPHAN PROJECTIONS (security review R1). `create_and_reselect/2` (`entity_type_instance.ex:119-140`) mints an id,
inserts the `entity_type_instances` row with `on_conflict: :nothing`, THEN inserts the projection for the MINTED id
(`ensure_instance_projection/2`, conflict target `instance_id`, which never conflicts for a fresh id), and only afterwards
re-reads which id won. If two first writes for one entity type race, the loser's `entity_type_instances` insert does nothing
but its projection insert succeeds: an ORPHAN projection (`:active`, `definition_id = instance_id`, no events) whose id is not
in the registry. The anti-join would not hide it: it stays in list/get and is cancellable (no values, but an existence signal
and a cancel target). Code evidence: the fast path (`get_or_create` row hit) never reaches this code; only first creation of a
type does.
DECISION: preferred fix, in the Entities write path, minimal: reorder `create_and_reselect/2` to (1) insert the registry row
`on_conflict: :nothing`, (2) re-read the registry row to learn the WINNING id, (3) `ensure_instance_projection` for the winning id
only (idempotent, `on_conflict: :nothing`). Winner and loser both ensure the same projection, so no orphan can be created, and
the pre-existing window "registry row committed, winner crashed before its projection insert" is UNCHANGED (once the registry
row commits, later callers take the fast `Repo.get` path and never ensure the projection; no repair is added there because it
would touch the Records hot path). That state is not a leak: the type simply has a registry row without a projection row, so there
is nothing to hide. Hot-path risk: the Records hot path takes the fast read branch and is untouched; only
the once-per-entity-type first-creation branch changes, with the same statements (one registry insert, one projection insert,
one re-read; the re-read moves earlier). A loser's events use the winning id, as before. NOT chosen: also hiding rows with
`definition_id = instance_id` (reverses the ruled M3 stance and keeps the fragile convention). RESIDUAL: orphans already
created in existing tenants by past races (rare, value-free) stay visible and cancellable; one-off cleanup is a follow-up (O6).

## 1. Where the predicate lives (decision)

ONE new leaf module `Letflow.EventStore.InstanceVisibility` (`lib/letflow/event_store/instance_visibility.ex`), depending
only on Ecto. It references the table by its SOURCE STRING `"entity_type_instances"` (schemaless source, same style as
`Obs.Alerts` uses `"instance_projections"`), not the `EntityTypeInstance` schema, so Engine and Instances can both use it
without crossing the Rule 6 layer boundary. Rejected: per-function inline predicates (drift; five copies), a flag column
(advisor ruling), `definition_id = instance_id` (fragile: the placeholder is flagged for removal in
`ensure_instance_projection/2`).

Public API (types only):
- Both functions have an `is_binary(prefix)` guard (and a UUID-string guard on `synthetic?/2`); a bad argument is a
  `FunctionClauseError` programmer error, never rescued, never swallowed into `true`/`false`. The inner source takes the prefix
  through the Ecto query-level prefix mechanism (`put_query_prefix` on the inner query), never a `fragment` or string
  concatenation (INV-7). `synthetic?/2` returns only `true` or `false`; no `{:error, _}`; a DB error propagates as the normal
  Repo raise.
- `exclude_synthetic(query :: Ecto.Queryable.t(), prefix :: String.t()) :: Ecto.Query.t()`. Precondition: the query's
  first source is `InstanceProjection`. Adds `NOT EXISTS (SELECT 1 FROM <prefix>.entity_type_instances e WHERE
  e.instance_id = p.instance_id)`. This is the anti-join form of the advisor's `instance_id IN (SELECT ...)`; it is the
  exact complement and is null-safe (`instance_id` is NOT NULL, so `NOT IN` would also be safe, but the anti-join is
  planner-friendly). The prefix is set EXPLICITLY on the inner source (INV-1), not left to propagate.
- `synthetic?(instance_id :: Ecto.UUID.t(), prefix :: String.t()) :: boolean()`. One `EXISTS` read on
  `entity_type_instances` by `instance_id`. For callers that have no projection query to compose (reconstruct, pins).

Generated-SQL test: the SQL for a query composed with `exclude_synthetic/2` (query log or telemetry) contains the tenant schema
name qualifying `entity_type_instances`, not the bare table.
Table-name drift guard: a unit test asserts the string equals `EntityTypeInstance.__schema__(:source)`.

## 2. Changes by function (every acceptance criterion maps here)

| Site | Change | Result for a synthetic id |
|---|---|---|
| `Instances.list/2` | compose `exclude_synthetic/2` into the query before filters and cursor | absent from every page; `page_size` and keyset cursor stay exact (WHERE, not post-filter) |
| `Instances.get_by_id/2` | replace `Repo.get` by a single query on the projection with `exclude_synthetic/2`; keep `{:error, :invalid_id}` before DB | `{:error, :not_found}` (same code path as nonexistent) |
| `Instances.ensure_instance_exists/2` (history, timeline) | add `exclude_synthetic/2` to the single existence query | `{:error, :not_found}`; the events query never runs; same ONE round trip as a nonexistent id |
| `Engine.fetch_and_lock_instance_projection_for_cancel/3` | add `exclude_synthetic/2` before `lock("FOR UPDATE")` | nil row -> existing `{:error, :instance_not_found}` -> 404; nothing written |
| `PinRebind.lock_projection_nowait/3` | same | existing `{:error, :instance_not_found}` -> 404 (request validation precedes it, identical to a nonexistent id) |
| `Reconstruction.reconstruct_instance/2` | after `cast_instance_id`, BEFORE `select_replay_source`/`read_full_log`: require a visible projection row, i.e. one query `exists(instance_projections row for id)` composed with `exclude_synthetic/2`; absent -> `{:error, :instance_not_found}` | synthetic AND platform-sentinel ids (no projection / synthetic) -> 404 exactly like a nonexistent id; replay never reached |
| Router `handle_get_pins/2` | defence in depth: `synthetic?/2` check before `PinResolver`; maps to `Response.not_found/1` | 404 (already true by accident of event content; now by construction) |
| advance-timer, attachments | no code change (F4); asserted by the route walk | already identical to nonexistent |
| router `render_*` | NO new clause: every path reuses the existing `Response.not_found/1` (constant body, no detail slot), so byte identity is structural | INV-5 |

Internal callers (must not change behaviour; enumerated):
- `Records.create_record`/update/delete, `StepWrites`, `HandlerWrites`, `Record.Projector` use `EntityTypeInstance.get_or_create/2`
  / `fetch_instance_id/2`, `EventStore.append*/read`, `Repo.get(EntityTypeInstance, ...)`: none touch `Instances.*`, the
  lock queries above, or `Reconstruction`. Unchanged.
- `Engine.cancel_instance` callers: router only. `PinRebind.rebind_pins`: router only. `Reconstruction.reconstruct_instance`:
  router and `engine.ex:8880` (`maybe_snapshot_after_set_instance_error`, matched only on a result carrying
  `execution_error_projection_update: %InstanceProjection{}`, i.e. the instance's projection row was just updated, so it
  always has a visible projection row; unchanged). Requiring a projection row in reconstruct changes no real-instance flow:
  a real instance always has one (the router also never reconstructs a projection-less instance successfully today, as
  `replay/4` needs its snapshot, which is written with the projection in the create transaction).
  `PinResolver.reconstruct_effective_pins`: engine create/sub-process (`engine.ex:1391,1747`), rebind; NOT guarded
  (hot internal path, real ids only).
- `Instances.get_by_id/history`: simulation runner and tests with real workflow instances. Unchanged.
- No internal caller needs a synthetic instance through these functions; none exists.

## 3. Performance

`entity_type_instances` holds one row per entity type per tenant (tens). The anti-join is a hashed subplan evaluated once
for `list/2`; for the single-row lookups it is one extra index-less probe of a tiny table beside a PK probe on the
projection. DECISION: NO index on `entity_type_instances.instance_id` and NO migration. A migration would also need the
`TenantProvisioning` manifest entry and has collided with `test/support/tenant_template.ex` before (see the comment in
`20260906010002_create_entity_type_instances.exs`). Revisit only if a tenant exceeds ~10^4 entity types (open question O3).

## 4. Timing and ordering (INV-5)

- Permission before existence: `authz_*` precedes the handler; unchanged.
- Existence is decided by ONE query that already contains the synthetic exclusion (no "exists, then is it synthetic"
  two-step), so synthetic and nonexistent take the identical DB path and round-trip count for get/history/timeline/cancel/rebind.
- Reconstruct: the projection-row gate runs first for synthetic, sentinel and nonexistent ids alike (identical single query,
  identical early return), so all three take the same path with the same round trips; the earlier "fewer reads" residual is gone.
  (Any residual: the prober is already authenticated, tenant-scoped and holds
  the permission, and none expected; O2 resolved.)
- Validation order is preserved: invalid UUID is still 422, request-body/idempotency-key validation still precedes the
  not-found (so a synthetic id with a bad body is the same 422 as a nonexistent id with that body).

## 5. Invariants

I1. A client route NEVER returns data, existence or error text distinguishing a synthetic instance from a nonexistent one.
I2. No client route mutates a synthetic instance (projection row, token, event, idempotency record) in any way.
I3. Real workflow instances are byte-for-byte unchanged on list/get/history/timeline/pins/cancel/reconstruct/rebind.
I4. Entity writes and the entity-record projector keep working: the predicate sits only on the client read/mutate paths.
I5. The predicate is derived from `entity_type_instances` alone, within the caller's tenant prefix.

## 6. Test plan (TEST-DESIGNER implements; real HTTP router, boolean probes only, no restricted value in failure messages)

T1. The 8 failing tests (a, a2, b1, b1q for TASK_WORKER and TENANT_AUDITOR) pass; the 5 controls (b2, c1, c2, c3 and the
second b2 role) stay green. Run output quoted.
T2. Route walk, new file `test/letflow/routers/instances_synthetic_hidden_test.exs`: a table of every route in F3 that takes
an instance id. For each: request with the synthetic answer_option id and with a fresh random UUID; assert equal status
AND equal `resp_body` AND equal full response headers (mask only the request id and `date`) (including the reconstruct row: 404 for both, body equal; on main it is 500 vs 404) (404 for all but: attachments list -> both 200 with identical body; upload -> equal status, body
compared with attachment id masked; storage-usage has no id, excluded). Roles: TENANT_ADMIN for permission-gated mutating routes,
TASK_WORKER and TENANT_AUDITOR for reads. The walk is generated from the router's route table so a new route without a
decision fails the test (route inventory assertion).
T2b. Wider INV-5 comparisons (same file): (i) cancel and rebind-pins sent TWICE with the same `Idempotency-Key`: the replay for a
synthetic id equals the replay for a nonexistent id (status, body, headers) and neither stores a result; (ii) the 403 case (a caller
lacking the permission, e.g. TASK_WORKER on cancel/rebind-pins) is identical for synthetic and nonexistent ids; (iii) the 422 cases
(bad UUID shape, over-long or invalid `Idempotency-Key`, bad `entries`) are identical; (iv) a MALFORMED JSON body sent with a
synthetic id equals the same body sent with a nonexistent id (validation precedes not-found for both); (v) equal DB query count
for synthetic vs nonexistent ids per route (get, history, timeline, cancel, rebind-pins, reconstruct), counted with a telemetry
handler on the repo query event scoped to the request.
T3. After the mutating walk (cancel, rebind-pins, reconstruct, advance-timer): the synthetic projection is still `:active`,
`cancelled_at` nil, event count and last sequence unchanged, no `INSTANCE_CANCELLED`/`INSTANCE_PINS_REBOUND` event,
`Records.create_record` for that entity type still succeeds. (Reconstruct is checked by T2 status+body, not by a write_back probe.)
T4. Platform sentinel: FIRST append a real platform event with `EventStore.append_platform_event/2` (so its log is non-empty),
THEN assert every id route, reconstruct in particular, answers the same status and body as a nonexistent id (404). On main the
reconstruct row is 500, so this fails before the fix.
T5. Control with a REAL workflow instance (Engine.create from an active definition): list contains it; get 200 with unchanged
body; history 200 with `INSTANCE_STARTED`; timeline 200; pins 200; cancel 200. Its list entry is present while synthetic ones
are absent in the same response.
T6. Internal callers unaffected: `Records.create_record` then `/entities/query` returns the record (projector OK);
`EntityTypeInstance.get_or_create/2` idempotent; `Instances.get_by_id/history` on a real simulation instance (existing tests).
T7. Unit `InstanceVisibility`: `exclude_synthetic/2` removes only rows whose id is in `entity_type_instances`;
a REAL projection whose `definition_id == instance_id` but not in `entity_type_instances` stays visible; a synthetic
projection whose `definition_id` was changed stays hidden; tenant isolation: an id synthetic in tenant A is visible-as-ordinary
in tenant B (predicate reads the passed prefix only); source string equals `EntityTypeInstance.__schema__(:source)`.
T9. Orphan race (R1): N (>= 8) concurrent `EntityTypeInstance.get_or_create/2` calls for one brand-new entity type, each on its own
connection; afterwards every `instance_projections` row with `definition_id = instance_id` is in `entity_type_instances` (counts
equal, exactly one per type), and all callers got the same id; repeated for several types. Plus a deterministic variant: pre-insert
the registry row with another id, call it, assert the returned id is the registered one and no projection exists for any other id.
T8. Pagination: with 3 real instances and 2 synthetic, `page_size=2` returns exactly 2 items per page, a valid cursor, total 3.

## 7. Mutants the tests must kill

M1 remove `exclude_synthetic` from `list/2` -> (a) and T8 fail.
M2 remove it from `ensure_instance_exists/2` -> (b1), (b1q), (b2) and the walk fail.
M3 use `definition_id = instance_id` instead of the table -> T7 (definition_id-changed synthetic; real row with equal ids).
M4 invert the predicate (EXISTS instead of NOT EXISTS) -> T5 control fails.
M5 omit the guard in the cancel lock -> T2 cancel row and T3 fail (synthetic gets cancelled).
M6 drop the reconstruct projection/synthetic gate (or move it after `read_full_log`) -> the T2 reconstruct comparison (500 vs 404) and T4 (sentinel with a platform event, 500) fail.
M7 drop the explicit prefix on the inner source -> T7 tenant isolation fails (or reads the wrong schema).
M9 revert `create_and_reselect/2` to projection-before-reselect -> T9 fails (orphan row).
M8 return a distinct 404 detail or 403 for synthetic in any render clause -> T2 byte comparison fails.

## 8. PR size and files

One PR. Production: `lib/letflow/event_store/instance_visibility.ex` (new, ~50 lines), `entities/entity_type_instance.ex` (reorder, ~10 lines), `instances.ex` (+~15), `engine.ex` (+~4),
`engine/pin_rebind.ex` (+~4), `engine/reconstruction.ex` (+~8), `routers/instances.ex` (+~8, pins guard; moduledoc INV-5
paragraph naming the synthetic rule). Tests ~350 lines (repro file already written + the walk file). No migration, no schema
change, no config. Docs: one anti-pattern entry (DOC-UPDATER) and the moduledoc notes. Reviewers: SECURITY-REVIEWER (mandatory,
cover the open items of #2702: platform sentinel, logs/telemetry, reconstruct/cancel/rebind, Lua `emit_event`, other
`instance_projections` readers, all answered in F4-F6), REVIEWER.

## 8b. PR-body statements (mandatory, security review R4)

Past exposure, stated precisely against the code:
- InstancesRead holders (TASK_WORKER, TENANT_AUDITOR and every role holding the permission) could read restricted entity-field
  values through the full `field_values` of record create/update events via `GET /instances/:id/history`, and could list/get the
  synthetic instances. Timeline never carried payloads.
- InstancesCancel holders could cancel a synthetic entity-type instance. Effect: any later record create/update for that type is
  refused (`active_instance_guard` returns `{:instance_terminated, :cancelled}`, `event_store.ex:681-690`), a denial of service on
  that entity type. Rebind-pins on a synthetic id returned 422 `unknown_pin_ref` (existence oracle), no write. Reconstruct on a
  synthetic id returned a 500 (`replay_failed`, F4), never reconstructed variables and never a projection rewrite (replay fails
  before write-back); an existence oracle only. The earlier idea that reconstruct could rewrite the projection or return values is
  retracted.
- Events already written are NOT altered by this PR. Past reads cannot be established (audit records mutations only). Treat
  restricted values written before this fix as DISCLOSED to those roles.
- TENANT_AUDITOR (and every other role) loses record create/update history via `/instances` until REQ-516 (#2701) adds a redacting
  record history route; also written into the `lib/letflow/routers/instances.ex` moduledoc; flag to the product owner.
- Attachments on synthetic or nonexistent ids behave identically and are unchanged; follow-up #2718 (O1).
- #2612 (permission-matrix golden) is not triggered (section 9).
- Legacy orphan projections from past first-write races stay visible (value-free); follow-up cleanup (O6).

## 9. #2612 applicability

#2612 (REQ-498 permission-matrix golden, `priv/permission_matrix/effective.golden`, `mix letflow.permission_matrix --check`)
is NOT triggered: no permission atom, role grant, `endpoint_policy_key` or module manifest changes. Routes keep their existing
`authz_*` permissions. No golden regeneration. The mandatory SECURITY-REVIEWER trigger paragraph it added still applies on
its own terms (tenant-data path), which this PR meets.

## 10. Open questions

O1. Attachments: upload to ANY uuid (synthetic or nonexistent) succeeds and list returns 200 empty; there is no instance
existence check. Pre-existing, not a leak of the synthetic instance, and byte-identical to the nonexistent case, so left
unchanged. Should a separate issue make attachment routes 404 for nonexistent instances (which then must also 404 for synthetic)?
O2. (Resolved by the R2 amendment: reconstruct gates on a visible projection row first, so no round-trip delta.)
O3. `entity_type_instances.instance_id` index: not added (section 3); confirm.
O4. `reconstruct_effective_pins/2` stays unguarded internally; only the pins route guards. Acceptable?
O6. Legacy orphan projections (F8): clean up in a follow-up one-off data fix, or accept as a value-free residual?
O5. Product: TENANT_AUDITOR record-history visibility is lost until REQ-516 (stated, not mitigated).
