# GH #2529 -- Append-only entity types (`append_only: true` refuses update/delete, 422)

Run: WF-02, branch `feat/GH-2529-append-only-entity-types`, stacked on GH #2528
(`lib/letflow/design/gh2528-record-version-conflict.md`). Source: core brief 03, roadmap W1b.
Type: backend only (`lib/letflow/`). No migration, no DDL, no event-type or payload change.
Gates: CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER (INV-1/2/5/8), REVIEWER.
Line numbers below are this branch's HEAD (59c16a20).

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | New optional top-level definition key `append_only :: boolean()`. Absent = mutable. Never defaulted, never inserted by any layer. | Opt-in; stored definitions keep byte-identical JSON, so their hashes are unchanged. |
| D2 | Validator: `append_only` present and not a boolean (including JSON `null` arriving through a pack) -> `%Violation{rule: :malformed, path: [:append_only]}`. Absent -> no violation. | AC; a stored `null` would silently change the hash of a "mutable" type, so `null` is rejected rather than treated as absent. |
| D3 | Flag is read in `Records` from the **current active** definition: `Map.get(definition.definition_json, "append_only") == true` (strict `true`, string key). | Records always re-queries the row (string-keyed JSONB, records.ex:48-71); only literal `true` locks. |
| D4 | Refusal sits right after `fetch_active_definition/2`, before `fetch_existing_record/3`, `ensure_not_deleted/2`, the already-deleted no-op, payload validation and the transaction (so before idempotency). | Existence-independent (INV-5): same answer for a live, deleted, absent or cross-tenant record id; zero events. |
| D5 | GH #2528's `expected_seq(attrs)` stays **first** (before `fetch_active_definition`). | It validates the call's own argument and raises on a programmer error; that must not be masked or unmasked by tenant configuration that flips on activation. Also keeps #2528's lines untouched. |
| D6 | Error term `{:error, {:entity_append_only, entity_type}}`; HTTP 422 via a new `Error.entity_append_only/0` (no argument). | 409 means "edit conflict" to the SPA; 403 is reserved for `managed_by` (#2530). Constant body: no record data (INV-2). |
| D7 | `create_record/2`, import, query, export, attachments: unchanged. | Issue "Out". |
| D8 | No DB trigger / revoked UPDATE. `Records` stays the single writer of update/delete events. | Would need a decision record (issue "Out"). |

## 2. Where `append_only` flows

1. **HTTP definition builder** -- `build_definition_document/1` (routers/entities.ex:509-523): add
   `|> maybe_put_optional(:append_only, body, "append_only")`. `maybe_put_optional/4`
   (entities.ex:606-611) drops only `nil`, so `false` is carried and JSON `null` stays absent.
   `@create_definition_schema` (entities.ex:426-438) is **not** changed: a `FieldConstraint`
   `type: :boolean` would turn `"yes"` into a `Validation.problem/1` 422 with a different code/path,
   breaking the AC that `"yes"` gives `malformed` at `["append_only"]`. `"yes"` instead passes the
   total builder unchanged and is rejected by the Validator (D2), rendered by
   `render_create_definition/2` (entities.ex:641-649) via `violation_map/1` (entities.ex:2662-2668),
   which emits `"code" => "malformed"`, `"path" => ["append_only"]`.
2. **Pack** -- `@top_level_keys` (definitions/solution_pack.ex:1073-1081): add
   `"append_only" => :append_only`. `translate_keys/2` (solution_pack.ex:1138-1145) keeps rejecting
   every other unknown key with `{:error, :invalid_pack_document}`. Export already ships the stored
   string-keyed `definition_json` verbatim (`pack_entity_definition/1`, solution_pack.ex:904-912), so
   no export change. Install goes `atomize_definition_json/1` -> `Definitions.create_definition/2`.
3. **Type** -- `Letflow.Entities.Definition.t()` (entities/definition.ex:23-31) gains
   `optional(:append_only) => boolean()`; moduledoc gets one paragraph (semantics, D3/D4).
4. **Validator** -- `malformed_violations/1` (definition/validator.ex:105-125): add one step
   `|> check_optional_boolean(definition, :append_only)` after `:constraints` (line 113).
   ```elixir
   @spec check_optional_boolean([violation()], Definition.t() | map(), atom()) :: [violation()]
   # Map.fetch: :error -> unchanged; {:ok, b} when is_boolean(b) -> unchanged;
   # {:ok, _} -> [malformed([key], "#{key} must be a boolean") | violations]
   ```
   Uses `Map.fetch/2` (not `Map.get/2` like `check_optional_string/3`, line 135) so a present
   `nil` is malformed (D2). Being in the top-level chain, it short-circuits field-shape checks the
   same way any other top-level malformed key does (validator.ex:114-124). No numbered rule changes.
5. **Storage / read-back** -- `Definitions.create_definition/2` (entities/definitions.ex:109-140)
   stores the atom-keyed document as `definition_json` (line 158); JSONB reads back string-keyed
   (`"append_only" => true`). `definition_map/1` (entities.ex:2583-2595) returns
   `"definition" => definition_json` whole, so `GET /entities/definitions/active/:name` echoes it with
   no change. `TenantProvisioning.document_from_persisted/1` (tenant_provisioning.ex:2660-2669) and
   `Records.definition_document/1` (records.ex:731-737) rebuild partial documents for DDL/record
   validation only, never for hashing: they correctly ignore the key; no change.
6. **Hash / logical shape** -- `Shape.content_hash/1` and `logical_shape_of/1`
   (definition/shape.ex:42-63) `Jason.encode!` the **whole** document; `logical_shape_of/1` drops
   only `@non_logical_fields [:display_name, :description]` (shape.ex:34). The key therefore
   participates automatically; `shape.ex` is **not edited**. Consequences: absent -> identical
   digests to today; `true` -> new `logical_shape_version` (unique index
   `entity_definitions_tenant_name_shape_idx` on `[:tenant_id, :name, :logical_shape_version]`,
   priv/repo/migrations/20260906000001_create_entity_definitions.exs:65-68, makes it a new row to activate);
   `false` is also a distinct logical shape from absent (accepted; see OQ-2).

## 3. Domain -- `Letflow.Entities.Records` (entities/records.ex)

Types: `command_error` (records.ex:144-153) gains
`| {:error, {:entity_append_only, entity_type :: String.t()}}`. Public signatures unchanged.

New private helper (shape only):
```elixir
@spec ensure_mutable(EntityDefinition.t(), entity_type :: String.t()) ::
        :ok | {:error, {:entity_append_only, String.t()}}
# definition_json["append_only"] == true -> {:error, {:entity_append_only, entity_type}}; else :ok
```

Step order after the change:
- `update_record/2` (records.ex:214-238): `expected_seq(attrs)` -> `fetch_active_definition/2` ->
  **`ensure_mutable/2`** -> `fetch_existing_record/3` -> `ensure_not_deleted/2` ->
  `validate_field_values/2` -> `run_command/2` (unchanged, incl. #2528's
  `maybe_check_record_version/2`).
- `delete_record/2` (records.ex:255-278): `expected_seq(attrs)` -> `fetch_active_definition/2` ->
  **`ensure_mutable/2`** -> `fetch_existing_record/3` -> already-deleted no-op -> `run_command/2`.
- `create_record/2` (records.ex:172-191): unchanged.

Error precedence (update): ArgumentError (bad expected seq, raise) -> `definition_not_found` (404)
-> `entity_append_only` (422) -> `record_not_found` (404) -> `record_already_deleted` (409) ->
`record_payload_invalid` (422) -> in-tx duplicate (200) -> `record_version_conflict` (409).
Delete: same minus payload; an already-deleted record of an append-only type now gets 422, not the
no-op 200 (cannot arise from this API, since the type refused the delete; only from a version flip).
Idempotency consequence: replaying a key that succeeded while the type was still mutable now gets
422 (refusal precedes the in-tx idempotency step) -- see OQ-1.
Docs: `@doc` of both functions and the moduledoc gain one sentence each naming the refusal and its
position. Comments must not quote the event-type names in any file outside the grep set (anti-pattern
"A grep-shaped acceptance criterion can be tripped by the module's own moduledoc ...").

## 4. HTTP -- `Letflow.Api.Error` and `Letflow.Routers.Entities`

```elixir
@spec entity_append_only() :: Letflow.Api.Error.t()
# %Error{type: @problems_base <> "entity-append-only", title: "Entity Type Is Append-Only",
#        status: 422, detail: "records of this entity type are append-only and cannot be updated or deleted",
#        extensions: %{"code" => "entity_append_only"}}
```
Placed after `record_version_conflict/0` (api/error.ex:271-280), same `@doc` style (INV-2/INV-4: no
argument, so no entity type, record id or field value reaches the body; `serialise/1` merges
`extensions` at error.ex:128-133).

Router (routers/entities.ex):
- `render_record_command/3`: new explicit clause
  `{:error, {:entity_append_only, _entity_type}}` -> `Response.send_problem(conn, Error.entity_append_only())`,
  placed after the `:record_version_conflict` clause (1404-1405), above the 500 clauses (1407-1414).
- Comment table above it (1353-1363): add `{:entity_append_only, _} -> 422 (entity-append-only, GH #2529)`.
- Moduledoc route table (entities.ex:50-51): update_record stays `200 / 404 / 409 / 422` (422 gains
  a cause; note it in the PUT comment block, 967-976); delete_record becomes `200 / 400 / 404 / 409 / 422`;
  DELETE comment block (1022-1033) gains one sentence on the 422.
- Handlers `handle_update_record/3` (992-1020) / `handle_delete_record/3` (1035-...): no change.
  Router-level 404 for a malformed id and 422 for a bad PUT body still precede the domain call;
  both are existence-independent, so INV-5 holds. `__authz_routes__/0` unchanged (no new route).

## 5. Callers of update/delete (all in `lib/`, no `priv/` or `scripts/` callers)

| Caller | Match shape | Effect if its type adopted the flag |
|---|---|---|
| `modules/exam/session.ex:1064` (`session_answer`) | `write_result = ...; ok_or_error(write_result)` (1075; `ok_or_error/1` 1339-1340 handles `{:error, _}`) | error returned, no crash |
| `modules/exam/session.ex:1263` (`session`) | `ok_or_error(Records.update_record(...))` | error returned, no crash |
| `scheduler/record_deadline_sweep.ex:254` (`apply_transition/3`) | `case` at 207-210: `{:error, reason} -> Repo.rollback(...)` -> logged warning, id added to `failed_ids` (180-189) | no crash, record skipped per sweep |
| `routers/entities.ex:1007`, `:1048` | `render_record_command/3` | 422 per section 4 |

None matches `{:ok, _} =` unconditionally. Exam types (`priv/modules/exam/entity_definitions/*.json`)
and any type a deadline rule targets **must not** adopt the flag (both update their records by
design); no file in this change touches them. Nothing deletes records outside the router.

## 6. AC -> design element -> test

| AC | Design element | Test (file :: describe/test) |
|---|---|---|
| 1 refusal, no state change | D4, sec 3 | `test/letflow/entities/records_test.exs` :: describe "append_only": "create succeeds", "update refused, record and event count unchanged", "delete refused, record and event count unchanged" (assert `field_values`, `deleted`, `last_event_global_seq`, and count of `events` rows for the type's synthetic instance before == after) |
| 2 existence independence | D4 order | same describe: "random non-existent record_id gets entity_append_only, not record_not_found" (update and delete) |
| 3 default off | D1/D3 | existing describes unmodified; plus "append_only: false behaves as mutable incl. delete idempotency" |
| 4 real round-trip | sec 2.5, D3 | all "append_only" fixtures built via `Definitions.create_definition/2` + `activate_definition/4`; one test asserts the reloaded `definition_json["append_only"] == true` |
| 5 version flip | D3 (current active) | "activating a version without the flag unlocks; re-adding it locks again" -- v1 `true`, v2 absent, v3 `true` **plus one extra optional field** (v3 must differ in logical shape from v1, else the unique index rejects it) |
| 6 HTTP | sec 2.1, sec 4 | `test/letflow/routers/entities_test.exs` :: describe "append_only (GH #2529)": PUT 422 + DELETE 422 (`code == "entity_append_only"`, content-type problem+json, no `field_values` key), POST record 201, normal type PUT 200, definition POST `true` 201 + GET active echoes `"append_only" => true`, `"yes"` 422 with an `errors` entry `code "malformed"`, `path ["append_only"]` |
| 7 validator | sec 2.4 | `test/letflow/entities/definition/validator_test.exs` :: describe "append_only": `true`/`false`/absent `:ok`; `"true"`, `1`, `"x"`, `nil` -> `%Violation{rule: :malformed, path: [:append_only]}` |
| 8 pack | sec 2.2 | `test/letflow/definitions/solution_pack_test.exs` :: describe "append_only round-trip (GH #2529)": export from tenant A, install into tenant B, `definition_json["append_only"] == true`; a pack with `"definition_json": {..., "frozen": true}` still `{:error, :invalid_pack_document}` |
| 9 hash stability | sec 2.6 | `test/letflow/entities/definition/shape_test.exs` :: describe "GH #2529 hash stability": key-less fixture's `content_hash/1` and `logical_shape_of/1` equal pinned lowercase-hex literals captured by running the same fixture on `origin/main` before the change; the fixture plus `append_only: true` gives a different `logical_shape_of/1` |
| 10 funnel | sec 5 | records_test.exs "append_only": a test-local function shaped like `apply_transition/3` (a `case` over `Records.update_record/2` inside `Repo.transaction/1`, rolling back on `{:error, _}`) returns the refusal; no `MatchError` |
| 11 no new write path | D8 | `test/letflow/entities/records_test.exs` :: "no new write path": `git grep -l` for the two event-type names under `lib`, excluding `lib/letflow/design/`, equals exactly `event_types.ex`, `records.ex`, `record/projector.ex` (skips with a message if git is unavailable) |

## 7. Blast radius

Opt-in only. No stored definition has the key (`git grep append_only -- lib priv` finds none), so
existing hashes, shapes, payload validation and every existing caller are unchanged; no migration.
Adopters: every update/delete caller of that type gets the refusal by design, and adopting is a new
`logical_shape_version` to activate. Mixed versions: an older server drops the key on
`POST /entities/definitions` (type created unprotected); an older pack installer rejects the pack.
The validator now rejects one more malformed shape, but only for a key nobody sends today (anti-pattern
"A validator that began refusing at activate broke two already-merged test files" checked: no file under `lib/` or `priv/`, and no definition fixture
in `test/` or `priv/` carries `append_only`). SPA: a 422 with `code entity_append_only` on PUT/DELETE;
hiding the buttons is a follow-up.

## 8. Security invariants

- INV-1: flag read from the definition resolved under the caller's own `prefix`; no new query.
- INV-2: 422 body is constant; no field value or record data. Definition GET already returns the
  whole document to `EntitiesDefinitionsRead` holders; the key is not sensitive.
- INV-5: refusal precedes record lookup, so absent / deleted / cross-tenant ids all get the same 422;
  the type's own existence is already observable (404 `definition_not_found`), unchanged.
- INV-8: helper is total (`Map.get` + `==`); a non-boolean can never be stored (D2); explicit render
  clause, so the catch-all 500 is not reached.
- INV-6/7: no new data-access path, no SQL.

## 9. Anti-pattern checks (docs/anti-patterns.md)

- "An established template-substitution mechanism applied to two of three sibling code paths, not
  all three" / "A gate-approved design fixing a shared write function missed a sibling write path":
  the only writers of update/delete events are the two guarded functions (AC 11 pins it).
- "A grep-shaped acceptance criterion can be tripped by the module's own moduledoc": new comments in
  error.ex / entities.ex must not name the event types.
- "Claiming a function 'already carries' a value without reading its real parameter list": every
  cited function was read at the line numbers given.

## 10. Not in this change

#2530 (`managed_by`) is not merged: no combined-order test here (it adds the 403-before-422 test).
Attachment mutation, SPA, exam/deadline adoption, DB enforcement: separate work.

## 11. Open questions

- OQ-1: a replayed idempotency key that succeeded before the flip now gets 422 instead of the
  original result. Chosen: accept (refusal must precede idempotency per the issue). Flag for REVIEWER.
- OQ-2: `append_only: false` is a distinct logical shape from absent. Chosen: accept (no
  normalisation, per "never defaulted"); clients wanting "unchanged" should omit the key.
