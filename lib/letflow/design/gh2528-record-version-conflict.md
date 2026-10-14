# GH #2528 -- Optimistic concurrency on entity record update/delete

Run: WF-02, branch `feat/GH-2528-record-version-conflict`. Source: core brief 01, roadmap W1a.
Type: backend only (`lib/letflow/`). No migration, no definition change, no event change.
Gates: CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER (INV-1/2/4/5/6/7/8), REVIEWER.

## 1. Problem

`Records.update_record/2` replaces `field_values` in full. Two clients that load the same record
and save in turn both get 200; the second silently discards the first. The only serialisation is
the per-entity-type `instance_sequence` lock taken by `EventStore.append_multi/3`
(`:assign_sequence`), which orders the writes but never compares them. The version token already
exists and is already returned in every record body (`record_map/1`, entities.ex ~2554):
`entity_record_latest.last_event_global_seq` (bigint, not null).

## 2. Decisions (summary)

| # | Decision | Why |
|---|---|---|
| D1 | New optional attr `:expected_last_event_global_seq` (`nil` or a non-negative integer) on `update_attrs`/`delete_attrs`. Absent or `nil` = today's behaviour. | Opt-in; all current callers unchanged. |
| D2 | When `nil`, the check step is **not added** to the `Multi` (same idiom as `EventStore.maybe_store_oversized_payload/2`). | Byte-for-byte: identical `Multi` step list, identical SQL, identical result for every existing caller. A no-op step would still change the `changes` map. |
| D3 | When non-nil, `Multi.run(:check_record_version, ...)` is appended **after** all `append_multi/3` steps and **before** `:upsert_record_latest`. | Runs under the sequence lock and after `:idempotency`, so an identical replay short-circuits as `is_duplicate: true` first; an error rolls back `:insert_event`, the idempotency claim, `instance_sequence` and the projection bump (one transaction). |
| D4 | The check re-reads the row with Ecto `lock: "FOR UPDATE"`, prefix-scoped, and compares `last_event_global_seq` with the expected value. It never reads `ctx.existing_record`. | `ctx.existing_record` is read before the transaction, so two racers both hold the old value; only a read after the lock sees the winner's commit (READ COMMITTED, new statement snapshot). |
| D5 | When the check ran, `:upsert_record_latest` builds its changeset from the locked row (`changes.check_record_version`), else from `ctx.existing_record`. | Ecto computes the UPDATE diff against the base struct; a stale base can drop a column from the UPDATE when the new value equals the stale one. With the check passed the two are equal in content, but basing on the locked row makes correctness hold by construction, not by inference. The nil path keeps `ctx.existing_record` (D2). |
| D6 | Mismatch, or locked row absent -> `{:error, :record_version_conflict}`. | Absent row inside the tx can only be a concurrent projection rebuild (rows are never hard-deleted otherwise); the pre-read already proved existence in this tenant, so a 409 ("reload and retry") is truthful and leaks nothing (INV-5). |
| D7 | `delete_record/2` on an already-deleted record keeps its early no-op success **regardless of the expected value** (no check, no event). | Domain-level idempotent delete (moduledoc); the caller's intended end state holds and nothing is overwritten, so no lost update. Resurrection/stale-delete semantics are out of scope (issue "Out"). |
| D8 | PUT uses a new `@record_update_schema` (= `@record_write_schema` + the new field). POST keeps `@record_write_schema` unchanged. | POST behaviour stays byte-for-byte; `Validation.validate/2` `Map.take`s schema fields, so a client sending the key on POST is silently ignored (mixed-version safe). |
| D9 | DELETE reads `?expected_last_event_global_seq=` via `fetch_query_params`; invalid -> **400** `bad_request("invalid expected_last_event_global_seq")`. PUT body type errors -> **422** (`Validation.problem/1`). | Matches the router's existing split: query-string errors are 400 (`page_size`), body schema errors are 422. |
| D10 | `If-Match` stays ignored. `EventTypes`, event payloads, routes, permissions unchanged. | Web sends a definition version in it today. |

## 3. Domain API -- `Letflow.Entities.Records` (lib/letflow/entities/records.ex)

Type changes (signatures of the three public functions are unchanged):

```elixir
@type expected_seq :: non_neg_integer() | nil

@type update_attrs :: %{
        required(:entity_type) => String.t(),
        required(:record_id) => Ecto.UUID.t(),
        required(:field_values) => Validator.field_values(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t(),
        optional(:expected_last_event_global_seq) => expected_seq()
      }
# delete_attrs: same new optional key added.
# command_error: add `| {:error, :record_version_conflict}`.
```

`ctx` (internal map) gains `expected_last_event_global_seq: expected_seq()`, read with
`Map.get(attrs, :expected_last_event_global_seq)` in `update_record/2` and `delete_record/2`;
`create_record/2` sets it to `nil` (create never checks). A non-nil value that is not a
non-negative integer is a programmer error from an internal caller: guard in a private
`expected_seq/1` helper that raises `ArgumentError` (the router validates before calling, so the
HTTP path can never reach it). `expected_seq/1` is called at the **entry** of `update_record/2`
and `delete_record/2`, before any lookup -- in particular before `delete_record/2`'s
already-deleted early return -- so a bad internal value raises on both a live and an
already-deleted record.

Private additions (shapes only):

```elixir
@spec maybe_check_record_version(Ecto.Multi.t(), ctx :: map()) :: Ecto.Multi.t()
# nil expected -> multi unchanged; else Multi.run(multi, :check_record_version, &check_record_version(&1, &2, ctx))

@spec check_record_version(Ecto.Repo.t(), changes :: map(), ctx :: map()) ::
        {:ok, Latest.t()} | {:error, :record_version_conflict}
```

`run_command/2` order becomes: `append_multi/3` steps -> `maybe_check_record_version/2` ->
`:upsert_record_latest` -> `:dual_write_promoted_columns` -> `Repo.transaction/1` ->
`interpret_result/1`. No new `interpret_result/1` clause: `{:error, :check_record_version,
:record_version_conflict, _}` already falls to the generic `{:error, reason}` clause.
`upsert_record_latest/3` (update/delete clause) base struct:
`Map.get(changes, :check_record_version, ctx.existing_record)` (D5).

Error precedence for `update_record/2` (all pre-transaction checks keep their order):
`definition_not_found` (404) -> `record_not_found` (404) -> `record_already_deleted` (409,
`conflict` type) -> `record_payload_invalid` (422) -> in-tx: duplicate idempotency key (200,
`is_duplicate: true`) -> `record_version_conflict` (409). A stale client therefore sees 422 for an
invalid payload before it sees a version conflict; this is intended (no write would happen either
way).

## 4. Locked read -- `Letflow.Entities.Record.Latest` (lib/letflow/entities/record/latest.ex)

```elixir
@spec get_for_update(repo :: Ecto.Repo.t(), record_id :: Ecto.UUID.t(),
        entity_type :: String.t(), prefix :: String.t()) :: t() | nil
```

Query: `from r in Latest, where: r.entity_type == ^entity_type and r.record_id == ^record_id,
lock: "FOR UPDATE"`, executed with `repo.one(query, prefix: prefix)`. Ecto composition only
(INV-7). It does not re-run `tenant_id_for_schema_name/1`: `prefix` is the same value
`Latest.get/3` already validated in the same command call, before the transaction (INV-6 proof:
the scoping comes from `prefix` plus the `entity_type`+`record_id` predicate on the unique index
`entity_record_latest_entity_type_record_id_idx`).

## 5. DB

Tables touched: `entity_record_latest` (one extra `SELECT ... FOR UPDATE` per opted-in write,
on the existing unique index). No new table, column, index or constraint; no migration. A
rolled-back conflict burns one `events.global_seq` value (gap) -- already true of any rolled-back
append; consumers do not assume gap-free global seqs.

## 6. HTTP -- `Letflow.Routers.Entities` and `Letflow.Api.Error`

`Letflow.Api.Error` (follows `module_owned_pack/0` / `output_refused/2`):

```elixir
@spec record_version_conflict() :: t()
# %Error{type: @problems_base <> "record-version-conflict", title: "Record Version Conflict",
#        status: 409, detail: "the record was changed by someone else; reload it and try again",
#        extensions: %{"code" => "record_version_conflict"}}
```

Takes no argument, so no record data, field value or sequence number can reach the body (INV-2,
INV-4). Router renders it with `Response.send_problem(conn, Error.record_version_conflict())`
(problem+json); no new `Response` helper.

Router changes:
- `@record_update_schema` = `@record_write_schema ++ [%FieldConstraint{name:
  "expected_last_event_global_seq", required: false, type: :integer, min_value: 0, max_value:
  9_223_372_036_854_775_807}]`. `max_value` keeps a JSON bignum from reaching Postgrex's int8
  encoder (INV-8: would raise -> 500). JSON `null` = absent (`validate_field/2` treats nil as not
  present); router passes `Map.get(attrs, "expected_last_event_global_seq")` through untouched
  -- no cast, no rounding. `type: :integer` (`is_integer/1`) already rejects `1.0`, `"5"` and
  `true` with 422; JSON `null` arrives as `nil`, which the domain treats as absent.
- `handle_update_record/3`: validate with `@record_update_schema`; add the key to
  `command_attrs`.
- `handle_delete_record/3`: after `cast_record_id/1` (malformed id -> 404 first), call
  `fetch_query_params/1` and a new private parser:
  `@spec parse_expected_seq_param(nil | String.t()) :: {:ok, non_neg_integer() | nil} | {:error, :invalid_expected_seq}`
  -- absent -> `{:ok, nil}`; a string that `Integer.parse/1` consumes fully, `>= 0` and
  `<= 9_223_372_036_854_775_807` -> `{:ok, n}`; anything else (`"abc"`, `""`, `"-1"`, `"1.5"`,
  `"1x"`, overflow) -> 400. The 400 is independent of record existence, so it is no probe oracle.
- `render_record_command/3`: new clause `{:error, :record_version_conflict}` -> 409 above the
  catch-all. Comment block gains `:record_version_conflict -> 409 (record-version-conflict)`.
- Moduledoc route table: update_record `200 / 404 / 409 / 422` (unchanged codes, 409 now has two
  causes); delete_record `200 / 400 / 404 / 409`. The DELETE comment "no 409 branch is
  reachable" is rewritten (409 is reachable via a stale expected value).
- `__authz_routes__/0` unchanged (no new route; the 18-route test stays green).

## 7. Callers (all unchanged, opt-in)

- `lib/letflow/modules/exam/session.ex:1064`, `:1263` -- `update_record/2`
- `lib/letflow/scheduler/record_deadline_sweep.ex:254` -- `update_record/2`
- `lib/letflow/routers/entities.ex:986` (PUT), `:1018` (DELETE) -- changed per section 6
- No calls in `priv/` or `scripts/`. Tests calling them (records_test, projector_test,
  query_test, exam session tests) pass no expected value and must pass unmodified.
Opting exam session / deadline sweep in, and web wiring (`EntityCrudPage`), are separate issues.

## 8. Acceptance criteria -> design -> test

Domain tests go in `test/letflow/entities/records_test.exs` (already `async: false`), new
`describe "expected_last_event_global_seq"`. Router tests in
`test/letflow/routers/entities_test.exs`, new `describe "GH-2528 -- record version conflict"`.

| AC | Design element | Test |
|---|---|---|
| Pre-existing tests unmodified; two updates without expected both `{:ok, _}` | D1, D2 | domain describe: "absent expected keeps last-writer-wins" |
| Match -> `{:ok, %{record: r}}`, `r.last_event_global_seq > S1` | D3, D4, D5 | "matching expected updates" |
| Mismatch atomic: conflict; field_values/seq unchanged; event count unchanged; key not claimed (retry same key + correct expected -> `is_duplicate: false`) | D3 (rollback), D6 | "stale expected is refused atomically" |
| Delete match/mismatch; mismatch leaves `deleted: false` | D3, D4 on `:delete` ctx | "delete with matching / stale expected" |
| Race (see 8.1) | D4 | describe "expected_last_event_global_seq -- concurrency": Test 1 (barrier, 20 iterations), Test 2 (control), Test 3 (deterministic lock-holder, carries the mutation-kill) |
| Replay precedence: key K + S1 twice -> `is_duplicate: true` | D3 (after `:idempotency`) | "identical replay returns the original, not a conflict" |
| Router: stale PUT 409 problem+json, `code`, no `field_values`, no seq; correct 200; `"abc"` 422; stale `If-Match` only 200; stale DELETE 409; non-integer DELETE param 400 | section 6, D8, D9, D10 | router describe, one test per bullet; body assertion: `Map.keys(body)` has no `"field_values"`, `"last_event_global_seq"`, and no integer equal to either seq |
| INV-5: cross-tenant / absent record with any valid expected -> zero-detail 404 | pre-tx `fetch_existing_record` precedes the check | router describe: both cases, body byte-identical to `Error.not_found/0` |
| `EventTypes` unchanged: UPDATED payload keys exactly entity_type/entity_def_version/record_id/field_values | D10, `build_event_attrs/3` untouched | domain describe: read stored event after an opted-in update |
| `Error.record_version_conflict/0` -> 409 + code; unknown body key does not break `Validation.validate/2` | section 6 | `test/letflow/api/output_refused_test.exs`, new `describe "Error.record_version_conflict/0"`; one-line test in `test/letflow/api/validation_test.exs` (unknown key -> `{:ok, map}` without it) |

### 8.1 Race test design

**Sandbox mode (load-bearing).** The file's existing `provisioned_tenant/0`
(`records_test.exs`, `SandboxAutoMode.provision!/2`) restores `:manual` + `checkout` on return
(`test/support/sandbox_auto_mode.ex`, `provision!/2`), so `Task.async` children would share the
test's single sandbox connection: no real race, and the lock-holder below would deadlock. The
three concurrency tests therefore live in their own
`describe "expected_last_event_global_seq -- concurrency"` whose tenant helper
(`provisioned_tenant_auto/0`, new, test-local) follows `test/letflow/engine_concurrency_test.exs`'s
`provisioned_tenant/0` exactly: `SandboxAutoMode.enter_auto_mode!(Letflow.Repo)`; then
`on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Letflow.Repo) end)` registered **first** (LIFO: it
runs last); then `TenantFixture.provisioned_tenant!(teardown: false)` and the file's existing
schema-drop / tenant-row cleanup `on_exit` registered **second** (runs first, while `:auto` is
still active). `:auto` stays in effect for the whole test, so every Task gets its own real
connection.

**State and cleanup.** In `:auto` mode every write commits for real. Each test provisions one
fresh tenant (unique schema), dropped by the cleanup `on_exit`; nothing is rolled back between
iterations. Each iteration creates a **fresh record** in that tenant and every count assertion is
a **delta** (event count for the entity type before vs. after the iteration), never an absolute
count.

**Test 1 (AC barrier race).** Loop `for i <- 1..20` (bounded; each Task await
5000 ms). Each iteration: create a fresh record (seq S1); two `Task.async` closures each send
`{:ready, self()}`, wait for `:go` (5000 ms `after` -> flunk), then call `update_record/2` with
`expected: S1`, distinct `field_values` (`"A#{i}"` vs `"B#{i}"`) and distinct idempotency keys.
Parent: `assert_receive {:ready, p1}/{:ready, p2}`, send `:go` to both, await both. Assert exactly
one `{:ok, _}` and one `{:error, :record_version_conflict}`; a fresh `Latest.get/3` shows the
winner's value and the winner's seq; entity-type event count rose by exactly 1.

**Test 2 (control).** Same loop shape, no expected value: two `{:ok, _}` per iteration, event
count delta +2.

**Test 3 (deterministic lock-holder -- MANDATORY; this is the test that carries "must fail if the
check reads `ctx.existing_record`").** Test 1 only catches that mutation on iterations where both
writers pre-read before the first commit, which is probable, not certain. Test 3 forces it:
1. Create a fresh record (S1); resolve the synthetic instance id with
   `EntityTypeInstance.get_or_create("customer", schema)` (row already exists after the create).
2. Holder `Task.async`: inside `Repo.transaction`, run an Ecto query
   `from s in Letflow.EventStore.InstanceSequence, where: s.instance_id == ^instance_id, lock: "FOR UPDATE"` with
   `prefix: schema`, send `{:locked, self()}` to the parent, then `receive :release` (5000 ms
   `after` -> flunk). Parent `assert_receive {:locked, holder}, 5000`.
3. Start the two writer tasks (expected S1, values `"A"`/`"B"`, distinct keys) with no barrier;
   each completes its pre-transaction `Latest.get/3` (sees S1) and then blocks in
   `:assign_sequence`'s `FOR UPDATE` on the held row.
4. Parent polls, bounded (max 50 polls, 20 ms apart via `receive ... after 20`, flunk on
   exhaustion), until exactly two backends wait on that row, filtered by target query text as in
   `test/letflow/event_store/partition_maintenance_test.exs` (`alter_partition_backend_active?/2`)
   and `test/letflow/identity/tenant_realm_bind_test.exs`:
   `SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query ILIKE $1`
   with `$1 = "%\"#{schema}\".\"instance_sequence\"%FOR UPDATE%"`. The schema name is unique to
   this test's tenant and the holder itself is idle-in-transaction (not `Lock`), so only the two
   writers match.
5. `send(holder, :release)`; await holder and both writers (5000 ms each).
6. Assert exactly one `{:ok, _}` and one `{:error, :record_version_conflict}`, stored value is the
   winner's, event count delta +1. Under the mutation both writers pass a check against their own
   pre-read S1 and the test gets two `{:ok, _}`, so it fails deterministically.

## 9. Blast radius for existing tenants

Opt-in and backward compatible: no migration, no definition change, no column/index, no event
envelope change, no route or permission change. Existing clients (web today, mobile, exam
session, deadline sweep) never send the field, so they never reach the new 409; the existing
`409 record_already_deleted` is unchanged. Cost: one indexed `SELECT ... FOR UPDATE` per opted-in
write inside an already-serialised transaction. Mixed versions: an old server ignores the new
body key (`Map.take`) and the query param; a new server with an old client behaves as today.
Deploy backend before frontend.

## 10. Security invariants

- INV-1: `prefix` still comes only from `prefix!(conn)`; the new field carries no authority.
- INV-2/INV-4: 409 body is constant (code + fixed detail); no field values, seqs, ids.
- INV-5: existence checks (404) run before the version check; invalid query param 400 is
  existence-independent; the in-tx absent row maps to 409 only after a same-tenant pre-read hit.
- INV-6: new read path `Latest.get_for_update/4` is scoped by validated `prefix` + type + id.
- INV-7: `lock: "FOR UPDATE"` via Ecto query composition; no SQL strings.
- INV-8: bignum bounded by `max_value` / parser upper bound; every new error is mapped.
- INV-3, INV-9, INV-10: not touched.

## 11. Anti-patterns checked

`docs/anti-patterns.md` sibling-path entries ("An established template-substitution mechanism
applied to two of three sibling code paths, not all three"; "A gate-approved design fixing a
shared write function missed a sibling write path constructing the same state independently";
"ISS-0397's own join_counters fix still missed a THIRD sibling read/write path, in a different
module — plus a Multi-step-ordering bug only that path exposed"): the only other writer to
`entity_record_latest` is `Letflow.Entities.Record.Projector.rebuild_projection/2` (rebuild from
the event log, same seqs); it does not need the check, and D6 covers it deleting a row under us.
All three record commands still funnel through `run_command/2`; create never adds the step.

## 12. Open questions

1. Delete idempotency over HTTP: DELETE mints a fresh idempotency key per request, so a client
   retrying a timed-out stale-checked DELETE gets either 200 (first attempt committed: record
   already deleted, D7) or 409. Accepted as-is; no change proposed here.
