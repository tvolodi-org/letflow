# GH #2543 -- Bind an entity-record `idempotency_key` to its request (`idempotency_key_reuse`, 422)

Run: WF-02, branch `feat/GH-2543-idempotency-key-binding`, stacked on GH #2529 (PR #2546,
`gh2529-append-only-entity-types.md`); GH #2528 (`gh2528-record-version-conflict.md`) is on main.
Type: backend only. **No migration, no event-type/payload change, no `Letflow.EventStore` change.**
No decision record: this tightens REQ-228 AC3 (records.ex:177-178). Gates: CODE-DESIGN-VALIDATOR,
SECURITY-REVIEWER (INV-2/5/8), REVIEWER. Line numbers are this branch at HEAD 1c642b84.

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | The binding is checked in `Letflow.Entities.Records`, after the transaction returns `{:error, :idempotency, {:duplicate_idempotency_key, original_event}, _}` (records.ex:658-662). The new request is compared against the **original event** (column `event_type`, column `actor_id`, payload). `EventStore.claim_idempotency/3` (event_store.ex:649-692) is untouched. | Keeps the shared event store generic. Every other event writer keeps its own semantics. |
| D2 | Compare the **existing stored payload**. No hash column, no migration. | The payload already holds the whole canonical command input: `entity_type`, `record_id`, `field_values` (records.ex:331-352). The command is the `event_type` and the actor is the `events.actor_id` column. A hash would need a per-tenant migration and an EventStore change. Events written before the change would have no hash, so the payload compare would still be needed for them. |
| D3 | Oversized originals are read back. If `payload` is `%{"$ref" => event_id}` (event_store.ex:716-721), Records loads `event_payload_store.payload` by `event_id`. | The side row always exists while the event exists (FK `on_delete: :restrict`, priv/repo/migrations/20260816120004_create_event_payload_store.exs:71). The duplicate-insert step already gives the full decoded map (event_store.ex:744-758). This also fixes a latent crash: today `duplicate_result/1` calls `Map.fetch!(payload, "entity_def_version")` (records.ex:681) on a `$ref` map, which raises `KeyError`. |
| D4 | Bound elements (section 2): command (`event_type`), `entity_type`, target `record_id` (update and delete), `field_values` (create and update), and **`actor_id`**. | The issue's tuple plus the actor. A legitimate retry always comes from the same actor (section 6). Adding the actor stops a second user from replaying a guessed key and values to learn a `record_id` (INV-2). |
| D5 | **Not bound:** `expected_last_event_global_seq`, `entity_def_version`, `metadata`, the freshly minted create `record_id`. | Replay precedence from #2528 D3 stays: the version check runs after `:idempotency`, and a same-request replay with a stale or different expected value is still `is_duplicate: true` (it is not in the payload). `entity_def_version` can change when a newer definition is activated between the two calls, but the request is still the same. A create mints its `record_id` per call (records.ex:186). |
| D6 | Mismatch -> `{:error, :idempotency_key_reuse}` -> HTTP **422** `Error.idempotency_key_reuse/0`, a constant body with code `"idempotency_key_reuse"`. | Not 409: the SPA reads 409 as "reload and retry" (web/src/api/client.ts:119, error.ex:288-290). Reloading does not fix a reused key, so the client must use a new key. This matches `entity_append_only` (422). It is not 400, because the body is well-formed. |
| D7 | `create_attrs` gains `optional(:idempotency_match) => :request \| :target`. The default is `:request` (full binding). `:target` drops only the `field_values` compare. It is an **internal-only** option: the router builds `command_attrs` literally (entities.ex:951-956, 1243-1249) and never sets it. Any other value raises `ArgumentError`. | `Certificate` relies today on "fetch-or-create by natural key" with a *different* payload (section 6). `:target` keeps that and still rejects a cross-type, cross-command or cross-actor reuse. Create only (YAGNI). |
| D8 | Step order is unchanged. #2529 `ensure_mutable` runs before any key read. The #2528 `:check_record_version` runs after `:idempotency`. The already-deleted delete no-op returns before the claim (section 7). | No reordering. Each existing test that pins the order stays valid. |

## 2. "Same request" per command

The original event `O` matches the new request when all checks in its row hold. The checks
are evaluated in this order and stop at the first failure.

| Command | `O.event_type` | `O.actor_id` | `payload["entity_type"]` | `payload["record_id"]` | `payload["field_values"]` |
|---|---|---|---|---|---|
| create `:request` | `"ENTITY_RECORD_CREATED"` | = `attrs.actor_id` | = `attrs.entity_type` | not compared | = canonical(`attrs.field_values`) |
| create `:target` | `"ENTITY_RECORD_CREATED"` | = | = | not compared | not compared |
| update | `"ENTITY_RECORD_UPDATED"` | = | = | = `attrs.record_id` | = canonical(`attrs.field_values`) |
| delete | `"ENTITY_RECORD_DELETED"` | = | = | = `attrs.record_id` | not compared (absent from the DELETED payload, records.ex:341-344) |

Check order: event_type, then actor, then `$ref` resolution, then the payload fields. A
non-entity or wrong-command original fails on the event_type check, before any payload read.

## 3. Canonical comparison (exact)

- `canonical(v) :: term()` is `v |> Jason.encode!() |> Jason.decode!()`. This is the same
  transform the original write went through: `to_append_attrs/4` encodes with `Jason.encode!`
  (records.ex:358), and EventStore decodes with `Jason.decode!` (event_store.ex:240). It cannot
  raise at compare time, because this call's own `Jason.encode!` already succeeded before the
  transaction. Keys become strings (atom and string keys match); `Date`/`DateTime`/`Decimal`
  and atom values become the strings Jason emits; `true`/`false`/`nil` stay.
- The stored side is used as decoded from jsonb (Postgrex/Jason).
- Equality is Erlang `==` (never `===`, never a pattern match): map key order is irrelevant;
  JSON numbers compare numerically (`1 == 1.0` is the same request; jsonb may return `1e2` as
  `100`); keys, strings, list order and the key set are compared exactly.
- UUIDs (`record_id`, `actor_id`): both sides through `Ecto.UUID.cast/1` (lowercase canonical);
  a cast `:error` on either side means "not same". `entity_type`/`event_type`: exact `==`.

## 4. `Letflow.Entities.Records` (entities/records.ex)

Types: `create_attrs` (records.ex:120-125) gains `optional(:idempotency_match) => idempotency_match()`.
`command_error` (records.ex:153-163) gains `| {:error, :idempotency_key_reuse}`. The public
function heads stay the same.

```elixir
@type idempotency_match :: :request | :target
@typep request_fingerprint :: %{
         event_type: String.t(),            # "ENTITY_RECORD_CREATED" | "..._UPDATED" | "..._DELETED"
         actor_id: Ecto.UUID.t(),
         entity_type: String.t(),
         record_id: Ecto.UUID.t() | :not_compared,
         field_values: map() | :not_compared  # already canonical(), see section 3
       }
@spec idempotency_match(map()) :: idempotency_match()        # raises ArgumentError on other values
@spec request_fingerprint(ctx :: map(), attrs :: map()) :: request_fingerprint()
@spec interpret_result(tx_result :: term(), request_fingerprint(), prefix :: String.t()) ::
        {:ok, command_result()} | command_error()
@spec match_original(Event.t(), request_fingerprint(), prefix :: String.t()) ::
        {:ok, Event.t()} | {:error, :idempotency_key_reuse}
        | {:error, {:payload_resolution_failed, Ecto.UUID.t()}}
@spec resolve_original_payload(Event.t(), prefix :: String.t()) ::
        {:ok, Event.t()} | {:error, {:payload_resolution_failed, Ecto.UUID.t()}}
@spec same_request?(resolved :: Event.t(), request_fingerprint()) :: boolean()
@spec canonical_json(term()) :: term()
@spec same_uuid?(term(), term()) :: boolean()
```

Steps:
1. `create_record/2` (records.ex:182-201) reads `idempotency_match(attrs)` first, before
   `fetch_active_definition`, so a bad value raises on every path. This follows the
   `expected_seq/1` precedent (records.ex:406-419). The ctx gains `idempotency_match`.
   `update_record/2` and `delete_record/2` set `:request` in ctx and do not read attrs.
2. `run_command/2` (records.ex:308-329) builds the `fingerprint` once, before
   `EventStore.append_multi/3`, from `ctx.kind`, `ctx.idempotency_match`, `attrs.actor_id`,
   `ctx.entity_type`, `ctx.record_id` and `ctx.field_values`.
   - It uses `:not_compared` for create's `record_id`, for delete's `field_values`, and for
     `:target` field values.
   - It calls `canonical_json/1` here.
   - It pipes the transaction into `interpret_result(result, fingerprint, ctx.prefix)`.
     Arity changes from /1 to /3. The other clauses (records.ex:654-674) ignore the new
     arguments and behave as before.
3. The duplicate clause runs `match_original(original_event, fingerprint, prefix)`:
   - `{:ok, resolved}` returns `{:ok, duplicate_result(resolved)}`. `duplicate_result/1`
     (records.ex:680-694) is unchanged, so it now always gets a resolved payload.
   - Otherwise the error is returned as-is.
4. `match_original/3` checks the event_type, then `same_uuid?(O.actor_id, fp.actor_id)`. If
   either fails it returns `{:error, :idempotency_key_reuse}` with no further reads. Next it
   calls `resolve_original_payload/2`, then `same_request?/2`, which returns `false` on a
   mismatch.
5. `resolve_original_payload/2`:
   - A payload that is not `%{"$ref" => ref}` comes back unchanged.
   - For a `$ref` payload it runs one Ecto query on `Letflow.EventStore.StoredPayload` with
     `event_id == ^ref`, selects `payload`, and passes `prefix: prefix` (INV-7: no
     interpolation). This mirrors `Reconstruction.resolve_live_payloads/2`
     (engine/reconstruction.ex:385-405), which duplicates the private
     `EventStore.resolve_payloads/2` (event_store.ex:1385-1403) for the same reason. It runs
     after the rolled-back transaction, and the original event is already committed.
   - A missing side row returns `{:error, {:payload_resolution_failed, ref}}`. The router's
     catch-all turns that into a 500 with no detail (INV-8). It is not reachable while the FK
     holds.
6. `same_request?/2` uses `Map.fetch/2` on the payload, so a missing key means "not same".
   It applies the section 2/3 rules.
7. The moduledoc gains a section "Idempotency key binding (GH #2543)" that restates D1-D8. The
   `@doc` of `create_record/2` (step 6, records.ex:177-178) and of `update_record/2`
   (records.ex:213-218) are reworded: "the same request" instead of "a duplicate key".

## 5. Error and router

- `Letflow.Api.Error.idempotency_key_reuse/0 :: t()`, placed after `entity_append_only/0`
  (error.ex:294-302): `type: @problems_base <> "idempotency-key-reuse"`,
  `title: "Idempotency Key Reused"`, `status: 422`,
  `detail: "this idempotency_key was already used for a different request; send a new key"`,
  `extensions: %{"code" => "idempotency_key_reuse"}`. No argument, so no record id, field value,
  entity type or event data can reach the body (INV-2, INV-4). The `@doc` names D6.
- `render_record_command/3` (routers/entities.ex): add the clause
  `{:error, :idempotency_key_reuse}`, which sends `Error.idempotency_key_reuse()`. Place it
  after the `entity_append_only` clause (entities.ex:1415-1416) and before the catch-alls.
  Add one row to the mapping comment (entities.ex:1358-1370).
- `import_reason_json/1`: add a clause before the catch-all (entities.ex:1301) that returns
  `%{"type" => "idempotency_key_reuse"}`. Without it the outcome would be logged as
  `internal_error`.
- Route table (entities.ex:49-51, 59): the status sets do not change, because POST, PUT and
  DELETE already list 422. Append the note "422 also `idempotency_key_reuse` (GH #2543)" to
  the create_record and update_record rows. DELETE mints a fresh key per request
  (entities.ex:1050), so the reuse error cannot happen there. Its row says so, and the
  shared clause still maps it. The import row is unchanged; the reason appears per entry.
- The handler comment at entities.ex:929-933 changes to: "the caller's own replay token, bound
  to (command, entity_type, record_id, field_values, actor) -- GH #2543".

## 6. Callers (grep `create_record\|update_record\|delete_record` and `idempotency_key` in lib/)

| Caller | Key derivation | Verdict |
|---|---|---|
| POST /records (entities.ex:946-958) | client body key, or a fresh UUID (entities.ex:1089-1094) | A client retry sends the same body and user, so it matches. A different body, record, type or user gets 422. |
| PUT /records (entities.ex:996-1011) | same | Same as POST. `expected_last_event_global_seq` is not bound (D5). |
| DELETE (entities.ex:1041-1054) | `Ecto.UUID.generate()` | Never a duplicate. Unaffected. |
| import (entities.ex:1240-1263) | `"entities-record-import:#{fresh import_request_id}:#{inspect(source_record_id)}"`; the request id is minted per call (entities.ex:1125) | Two entries in one call with the same `record_id` and identical values still dedupe, so the test at entities_test.exs:2310-2339 stays green. **Behaviour change:** two entries with the same `record_id` but different values give a per-entry `"idempotency_key_reuse"`. Today the second entry is silently dropped and reports the first entry's `record_id` as "ok". The same applies to entries with no `record_id`, which all share the key `...:nil` (OQ-3). |
| Certificate (modules/exam/certificate.ex:319-345) | `"certificate:issue:" <> session.id` | **Relies today on reuse with a different payload.** The payload includes `issued_at = utc_now()` (certificate.ex:327) plus live branding and candidate name. Fix: pass `idempotency_match: :target` in the attrs at certificate.ex:331-337, and add one moduledoc sentence. The actor is always `candidate_id`, because ownership is checked first (certificate_test.exs:234). certificate_test.exs:263-264 and 301-344 stay green. |
| Seed task (lib/mix/tasks/letflow.seed.exam_fixtures.ex:573-581) | literal `"req345-seed-..."` keys; the values are literals or ids returned by earlier idempotent creates; the actor is the resolved candidate (line 175) | A re-run gives the same request and converges. If the seed content is edited between runs in one tenant, the task raises with `:idempotency_key_reuse` instead of keeping the old content. That is intended; the moduledoc (lines 72-76) gets a note. |
| Session (session.ex:1070, 1269, 1333), AntiCheat (anti_cheat.ex:268), deadline sweep (scheduler/record_deadline_sweep.ex:260) | `Ecto.UUID.generate()` per call | A key is never reused, so these callers are unaffected. Their tests (session_test, anti_cheat_test, record_deadline_sweep_test) stay green. |

No caller other than Certificate relies on reuse with a different payload.

## 7. Cross-writer keys and ordering

- One `event_idempotency` table per tenant schema is shared by every writer. Examples of other
  keys: `timer_fired:` (scheduler.ex:389), `attachment_attached:` (attachments.ex:371), Lua
  `emit_event` script keys (engine/lua/platform.ex:805-819), and service-task keys
  (engine.ex:3702).
  **Today** an entity command whose key was first used by a non-entity event reaches
  `duplicate_result/1`, which raises `KeyError` on `"entity_def_version"` (records.ex:681): a
  500 crash (INV-8 defect). **After**, the event_type check fails first -> `:idempotency_key_reuse`
  with no payload read. The reverse (a non-entity writer hitting a key an entity command claimed
  first) still gets `is_duplicate: true` from `EventStore.append`; unchanged, out of scope (OQ-1).
- Update order: `expected_seq` -> `fetch_active_definition` -> `ensure_mutable` (#2529) ->
  `fetch_existing_record` -> `ensure_not_deleted` -> `validate_field_values` -> tx M1-M6
  (`:idempotency` = M3) -> `:check_record_version` (#2528) -> upsert -> dual write ->
  `interpret_result/3`. So: reused key on an append-only type -> `entity_append_only`;
  same-request replay with a stale expected -> `is_duplicate: true`; different request ->
  `idempotency_key_reuse` (the version check never runs; `:idempotency` halts the Multi).
- Delete on an already-deleted record returns its no-op before the claim (records.ex:285-286),
  so the key is never checked (unchanged; it returns only the row the caller addressed).

## 8. AC -> design -> test

New `describe "GH #2543 -- idempotency key bound to the request"` in
test/letflow/entities/records_test.exs (R*); router tests (H*) in test/letflow/routers/entities_test.exs.

| AC | Design | Test (name) |
|---|---|---|
| Binding plus stable error | D1, D4, section 2 | R `update key reused for a different record_id -> idempotency_key_reuse, target unchanged, no event` |
| | | R `create key reused for update -> reuse`; R `create key reused for delete -> reuse` |
| | | R `create key reused with different field_values -> reuse`; R `update key reused with different field_values -> reuse` |
| | | R `create key reused on another entity type with identical field_values -> reuse` |
| | | R `same key and payload from another actor -> reuse` |
| | | R `key first used by a non-entity event -> reuse, no raise` (EventStore.append on a started instance) |
| No original data, fixed status | D6, section 5 | H `POST reuse -> 422, body is exactly the constant problem, contains neither the original record_id nor its field values`; H `PUT reuse -> 422 idempotency_key_reuse`; test/letflow/api/error_test.exs `idempotency_key_reuse/0 builds the 422 document` |
| Same-request replay stays idempotent | D5, section 3 | Existing AC3 test (records_test.exs:253-273); existing `identical replay ...` (records_test.exs:945-960) |
| | | R `replay with reordered keys and 1 vs 1.0 -> is_duplicate: true, one event` |
| | | R `same values, different stale expected -> is_duplicate: true` |
| | | R `oversized (> 4096 B payload) create replay -> is_duplicate: true, full field_values` (D3) |
| | | H `POST replay -> 201 with the same record_id` |
| Backward compatibility | D7, section 6 | R `:target create with different values -> original, is_duplicate: true`; R `:target create on another type -> reuse`; R `invalid idempotency_match raises ArgumentError` |
| | | Unchanged suites: certificate_test, session_test, anti_cheat_test, record_deadline_sweep_test, entities_test import dedup |
| | | H `import: same record_id with different values -> per-entry idempotency_key_reuse` |
| Payload compared, choice named | D2 | PR body: "existing stored payload compared, no hash, no migration" |
| Order unchanged | D8 | R `reused key on an append-only type -> entity_append_only` |

**Intentional test rewrite:** records_test.exs:962-1000 (`replay with the same key but a different
stale expected and different values returns the original`) asserts the defect. It is split into
two tests:
- R `same values, different stale expected -> is_duplicate: true`
- R `different values, same key -> idempotency_key_reuse, nothing written`

test/specs/GH-2528.md:36 is reworded to match.

## 9. Security notes

- **INV-2:** the reuse body is constant and the error function takes no argument. A different
  request can no longer receive another record's `record_id` or `field_values`, which closes
  the leak the issue describes. A same-request replay returns only values the caller sent
  itself, and only to the same actor (D4).
- **INV-5:** the reuse answer depends only on the key's own history, not on whether the target
  record exists. On update, a missing record still answers 404 before the claim, as today. The
  answer does reveal that a key was used before. Keys are the caller's own tokens; server
  namespaces are covered in OQ-1.
- **INV-8:** this fixes two raise paths, a non-entity original (records.ex:681 `KeyError`) and
  a `$ref` original. A missing side row is a handled 500 with no detail.
- **INV-1 / INV-6 / INV-7:** the new read is bound to `prefix` and written as an Ecto query.

## 10. Blast radius

Edited: lib/letflow/entities/records.ex; lib/letflow/api/error.ex; lib/letflow/routers/entities.ex
(two clauses, comments, route table); lib/letflow/modules/exam/certificate.ex (one attr, moduledoc);
lib/mix/tasks/letflow.seed.exam_fixtures.ex (moduledoc only); test/specs/GH-2528.md; section 8 tests.
Not edited: event_store.ex, migrations, event types, web/ (the SPA never sends `idempotency_key`
for entity records, so the error is unreachable from the UI).

Anti-patterns (docs/anti-patterns.md): "An established template-substitution mechanism applied
to two of three sibling code paths, not all three" -- the binding covers create, update, delete
and import. "A gate-approved design fixing a shared write function missed a sibling write path
constructing the same state independently" -- every `Records` caller is reviewed in section 6.

## 11. Open questions

- **OQ-1:** client keys share a namespace with server-derived keys. A client could POST with
  `"timer_fired:<id>"` or `"certificate:issue:<sid>"` and squat a key that a server writer
  uses later; that writer would then see `is_duplicate: true` and skip its work. This exists
  today; `EventStore` is not changed here. Recommend a follow-up: prefix client keys in the router.
- **OQ-2:** squatting a Certificate key under `:target`. A different actor gets reuse, then a
  500 for the candidate: a denial, not a forgery. The same actor would get the squatted record
  back, which already happens today. This needs `EntitiesRecordsWrite` on `certificate`.
  SECURITY-REVIEWER should confirm candidates lack it.
- **OQ-3:** import entries without `record_id` share one key per call. After this change,
  differing entries give a per-entry reuse error where today they are silently dropped.
  Recommendation: a follow-up keys such entries by entry index; not changed here.
