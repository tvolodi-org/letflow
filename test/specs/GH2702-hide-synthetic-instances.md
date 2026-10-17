# Test Spec: GH2702 — hide synthetic entity-type instances from every Instances route

Design authority: `lib/letflow/design/gh2702-hide-synthetic-instances.md` (sections 2, 6, 7).
Implementation: `lib/letflow/event_store/instance_visibility.ex`, `instances.ex`, `engine.ex`
(cancel lock), `engine/pin_rebind.ex`, `engine/reconstruction.ex`, `routers/instances.ex`,
`entities/entity_type_instance.ex`.

NOTE (post-review change): the reconstruct guard refuses ONLY synthetic ids
(`InstanceVisibility.synthetic?/2`) and the platform sentinel id
(`EventStore.platform_instance_id/0`). An absent id, or a real instance whose projection row
was deleted, still reaches the log read (INV-RC-2). Design text saying "visible projection row"
is superseded; the tests follow the code.

## Files

| File | Covers |
|---|---|
| `test/letflow/routers/instances_restricted_field_events_test.exs` (committed) | T1: the 13 reproducing tests (8 failed on main) |
| `test/letflow/routers/instances_synthetic_hidden_test.exs` (new) | T2, T2b, T3, T4, T5, T6, T8, reconstruct/INV-RC-2 |
| `test/letflow/event_store/instance_visibility_test.exs` (new) | T7 |
| `test/letflow/entities/entity_type_instance_race_test.exs` (new) | T9 |
| `test/letflow/engine/reconstruction_test.exs` (existing, unchanged) | AC2 (~l.317) and AC5/OQ-4 (~l.509) must still pass |

## Acceptance criteria to tests

| Criterion | Test(s) and why |
|---|---|
| List/get/history/timeline never expose synthetic instances (repro a, a2, b1, b1q, b2 for TASK_WORKER and TENANT_AUDITOR) | T1 file. Real HTTP, boolean probes only. |
| Every route taking an instance id treats a synthetic id exactly like a random UUID (status, body, full headers) | `T2 route walk` "each id route answers ..." walks the 14 routes with the synthetic `widget` and `gadget` ids and a fresh UUID; headers compared in full, only request id and `date` masked, trace id pinned by sending `x-trace-id`. Needed because INV-5 is about byte identity, not just status. |
| The route list cannot silently grow | `route inventory`: `__authz_routes__/0` filtered on `:id` must equal the walk table. A new route without a decision fails. |
| `GET /instances` omits synthetic instances for every role | `T2` "GET /instances omits both" (worker, auditor, admin). |
| Platform sentinel answers like a nonexistent id once its log is non-empty | `T4`: appends a real platform event first (reconstruct was a 500 on main), then runs the whole walk on the sentinel id. |
| Replayed `Idempotency-Key` on cancel and rebind-pins is indistinguishable and stores nothing | `T2b (i)`: first == replay == nonexistent replay; `IdempotencyRecord` count unchanged. |
| 403 identical (permission precedes existence) | `T2b (ii)`: TASK_WORKER on cancel, rebind-pins, reconstruct, advance-timer. |
| 422 identical (over-long key, bad entries, missing reason) | `T2b (iii)`. |
| Malformed body with a synthetic id equals the nonexistent id | `T2b (iv)`. |
| Equal DB round trips where the design says equal | `T2b (v)`: get, history, timeline, cancel, rebind-pins counted with a `[:letflow, :repo, :query]` handler scoped to the test process (warm-up first). Reconstruct is NOT equal by design after the guard change (a nonexistent id continues into the log reads, a synthetic id stops after the registry read), so only `synthetic <= nonexistent` is asserted. Pins (1 vs 2 queries) is the accepted residual and is not asserted. |
| Mutating routes never change a synthetic instance | `T3`: projection struct equal before/after, status `:active`, `cancelled_at` nil, event list (sequence + type) unchanged, no `INSTANCE_CANCELLED` / `INSTANCE_PINS_REBOUND`, idempotency count unchanged, and a later `Records.create_record` for the type still succeeds (the DoS is gone). |
| Real workflow instances unchanged | `T5`: list contains the real id and not the synthetic ones; get 200, history has `INSTANCE_STARTED`, timeline 200, pins 200, cancel 200 and projection `:cancelled`. Kills the inverted predicate (M4). |
| Pagination exact | `T8`: 3 real + 2 synthetic, `page_size=2` gives 2 + 1, valid cursor, ids equal the real ones. Kills "post-filter" implementations (M1). |
| INV-RC-2 preserved | `T5` "projection row deleted still reconstructs" (direct call and HTTP 200); "absent / synthetic / sentinel ids are `:instance_not_found`". Existing AC2/AC5 tests stay green. |
| Internal callers unaffected | `T6`: `get_or_create/2` idempotent, record write + `/entities/query` returns the record (projector), history of the synthetic instance still 404 for clients. |
| `InstanceVisibility` unit behaviour | T7 file: removes only registered ids; real row with `definition_id == instance_id` stays visible; synthetic row with changed `definition_id` stays hidden; composes with where/limit; tenant isolation incl. explicit prefix; generated SQL carries the tenant schema name and `NOT EXISTS`; table-name string equals `EntityTypeInstance.__schema__(:source)`; `is_binary` guards raise `FunctionClauseError`; `synthetic?/2` is `=== true / === false` only. |
| No orphan projection from a first-write race (R1/F8) | T9: deterministic loser (winner's registry row uncommitted, loser parks on it, winner commits; loser must return the winner id and no projection exists for its minted id) plus an 8-way x 4-type stress test (registry ids == synthetic-shaped projection ids, one id per type). Uses Sandbox `:auto` + `checkin` like `engine_concurrency_test.exs`. |

## Mutants (design section 7) and the tests that must fail

| Mutant | Expected failing tests |
|---|---|
| M1 remove `exclude_synthetic` from `Instances.list/2` | repro (a) x2 roles, T2 list test, T5 list, T8 |
| M2 remove it from `ensure_instance_exists/2` | repro (b1)/(b1q)/(b2), T2 walk (history, timeline), T2b (v) |
| M3 use `definition_id = instance_id` instead of the registry | T7 "real projection with equal ids stays visible" and "changed definition_id stays hidden" |
| M4 invert the predicate (EXISTS) | T5, T8, T7 (all) |
| M5 omit the guard in the cancel lock | T2 cancel row, T3 (synthetic gets cancelled, record write refused) |
| M6 drop the synthetic / sentinel check in `Reconstruction.ensure_not_hidden/2` | T2 reconstruct row (500 vs 404), T4 (sentinel with a platform event), T5 absent/synthetic/sentinel test |
| M6b (new, INV-RC-2) restore the "projection row must exist" guard | T5 "projection row deleted still reconstructs", existing reconstruction AC2/AC5 |
| M7 drop the explicit prefix on the inner source | T7 "reads exactly the prefix passed", generated-SQL test |
| M8 distinct 404 detail or status for synthetic in any render clause | T2 walk byte comparison |
| M9 revert `create_and_reselect/2` to projection-before-reselect | T9 deterministic loser (orphan projection for the loser's minted id) |
| M10 drop the pins route `synthetic?/2` guard | none expected: the route already 404s by event content (defence in depth; equal observable behaviour) |

## Not covered / residual

* Attachment routes: asserted only as "synthetic == nonexistent" (follow-up #2718).
* Pins query-count asymmetry (1 vs 2) accepted by SECURITY-REVIEWER; not asserted.
* Legacy orphan projections from past races (O6) are not repaired and not tested.
