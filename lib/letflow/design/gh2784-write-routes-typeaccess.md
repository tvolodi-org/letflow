# GH #2784 design: TypeAccess and field restrictions on the record WRITE routes and the record attachment routes (denied == absent)

Status: DESIGN (CODE-DESIGNER, 2026-10-18). Priority 2, SECURITY (tenant data path, authorization). No implementation code in this file.
Base: origin/main `27274bd2` (the merged #2659 upsert import is on it). Reads only; `mix` was not run (host constraint), every line
number below was re-read on this base, not copied from the issue.
Sources: GH #2784 (body, ACs; its anchors were read on `21c9b40b`), GH #2700 and GH #2739 (the rulings),
`lib/letflow/design/gh2700-type-access-joins-export-aggregate.md`, `gh2739-definitions-list-type-access.md`,
`gh2697-restricted-field-request-walker.md` (the field-restriction refusal ruling), `gh2659-external-ref-idempotent-import.md` 4.5 / 5.2 / 7,
`docs/agents/instructions/security-invariants.md` (INV-1, INV-2, INV-5, INV-7, INV-8). Decision 0061 (lock order) is not touched: no lock changes.

## 0. Decisions in one paragraph

ONE new module, `Letflow.Entities.RecordAccess` (sibling of `RequestAccess`, same discipline: do every read unconditionally, then make
one decision from a closed value that carries nothing the caller could tell apart), is the only gate the four record write handlers and
the four record attachment handlers call. For a record write it returns `:hidden` (TypeAccess-denied OR no active definition OR any failed
read, one value), `:managed` (visible but module-managed), or `{:open, restricted}`. `:hidden` is consumed by substituting, at the exact
point where `Records.*` would run, the result `Records` itself gives an absent type (`{:error, {:definition_not_found, type}}`), so a denied
type travels the SAME code and renders the SAME bytes as an absent one by construction, including the validation errors that precede that
point today. The decision is computed FIRST (so the managed 403 can never reveal a denied type) but is APPLIED last. A restricted written
key is refused with the #2697 constant 403 (POST, PUT) or the #2659 per-entry `field_restricted` (both imports). PUT, which replaces
`field_values` wholesale, is refused for any actor holding any restricted field on the type (fail closed, the PUT analogue of the upsert
rule). DELETE (and POST) responses of an open type are rendered through `FieldGrants.redact_field_values/2` for an actor with restricted
fields, because `record_map/2` renders `field_values` unredacted today (section 4). `ImportUpsert.precheck/3` is refactored onto the same
gate so there is one implementation. Denied == absent is claimed at the level of CALLS and RESPONSE BYTES (same four gate calls, then identical
code), not total SQL statements: the existing-vs-missing definition read is the #2700-accepted residual (SECURITY R6). Two PRs, attachments
first (section 12).

Revision 3, folds the verdicts on e4f2d438 and cbdc70f0 (2026-10-18).

## 1. Findings: every write route, re-grepped on main `27274bd2` (AC 1)

`lib/letflow/routers/entities.ex` (3025 lines). `authz_*` macros = the route-level permission gate, independent of the type, so it cannot
distinguish denied from absent and needs no change.

| # | Route (macro line) | Handler (line) | Gate state BEFORE | Gate state AFTER |
|---|---|---|---|---|
| 1 | `POST /records/:entity_type` `:EntitiesRecordsWrite` (:311) | `handle_create_record` :1018 -> `create_record_unmanaged` :1022 | `guard_tenant_write/3` (:2972, managed 403) only; no TypeAccess, no FieldGrants | `RecordAccess.write/3` decision; hidden -> 404, restricted key -> 403 |
| 2 | `PUT /records/:entity_type/:record_id` `:EntitiesRecordsWrite` (:315) | `handle_update_record` :1083 -> :1089 | managed guard only | decision; hidden -> 404, actor has any restricted field -> 403 |
| 3 | `DELETE /records/:entity_type/:record_id` `:EntitiesRecordsWrite` (:319) | `handle_delete_record` :1155 -> :1161 | managed guard only | decision; hidden -> 404; no field-key check, but the response `field_values` are redacted for a restricted actor (section 4) |
| 4 | `POST /records/:entity_type/import` `:EntitiesRecordsImport` (:332) | `handle_import_records` :1234 -> :1238; create mode `run_import*` :1353-1424; upsert mode `ImportUpsert` | managed guard; upsert mode alone has TypeAccess + FieldGrants (`precheck/3`, import_upsert.ex:90); create mode has neither | decision for both modes; create mode gains hidden fold + per-entry `field_restricted`; upsert reuses the same decision |
| 5 | `POST /records/:entity_type/:record_id/attachments` `:EntitiesAttachmentsManage` (:390) | `handle_create_record_attachment` :1676 | NO gate at all (not even managed; #2582 left attachments out of managed scope) | `RecordAccess.attachment/3`; hidden -> 404 |
| 6 | `GET /records/:entity_type/:record_id/attachments` `:EntitiesAttachmentsRead` (:394) | `handle_list_record_attachments` :1762 | none | hidden -> the absent answer, 200 empty page |
| 7 | `GET .../attachments/:attachment_id` `:EntitiesAttachmentsRead` (:398) | `handle_get_record_attachment_content` :1826 | none | hidden -> 404 |
| 8 | `DELETE .../attachments/:attachment_id` `:EntitiesAttachmentsManage` (:408) | `handle_delete_record_attachment` :1912 | none | hidden -> 404 |

Routes in the same file that write but are deliberately NOT changed here (listed so the inventory is complete, AC 1):
`POST /definitions` (:279, `handle_create_definition` :459) and `POST /definitions/:name/activate` (:275, :770) keep `guard_tenant_write`
(definition writes, not record writes; see OQ-3); `POST /restrictions/import` (:347, :1537) is restriction administration, a different
surface (the issue says so). Read routes (`/query`, `/query/aggregate`, export, definitions) were done by #2700 / #2739.

Facts that drive the design (all read on this base):

F1. `guard_tenant_write/3` (:2972) runs `ManagedTypes.check_tenant_write/2` and answers a managed type with the constant 403
`Error.entity_type_managed/0` (api/error.ex:338) BEFORE the body, path id or query string is read (moduledoc :46). It reads the managed stamp
of ANY definition row of the name, so today a caller denied by TypeAccess on a managed type gets 403 where an absent type gets 404: an
existence oracle for denied managed types.

F2. What an ABSENT type answers today (the bytes a denied type must equal), per route, is NOT "404 first": the handler validates first and
`Records` answers `{:error, {:definition_not_found, type}}` last, rendered by `render_record_command/3` (:1605) as `Response.not_found(conn)`
(the generic constant 404 Problem; there is no `entity_type_not_found` code on the wire, that is only the internal atom in `RequestAccess`).
POST: malformed body 400, schema error 422, key errors 422, THEN 404 (:1022-1051). PUT: invalid record id 404, then the same body errors, then 404
(:1089-1126). DELETE: invalid record id 404, bad `expected_last_event_global_seq` 400, then 404 (:1161-1181). Import create mode: cap 413 /
schema version 422 / entity_type mismatch 422 / `upsert_by` 422 precede; then `run_import` folds a first-entry `definition_not_found` to 404
(:1371-1380, :1255-1259), but an EMPTY `records: []` array answers 200 `{"results": []}` and a non-map entry raises. Import upsert mode: the same
checks, then `precheck/3` -> 404 (even for empty `records`). Hence "denied -> 404 early" would be distinguishable from absent (malformed body on a
denied type 404, on an absent type 400); the decision must be applied at the write point (section 3).

F3. `Records.create/update/delete` order for an absent type: `reject_reserved_attributes`, `reject_step_key`, `fetch_active_definition`
(records.ex:939-949, :1617), none reachable from the HTTP routes with data that differs by type (the idempotency key is namespaced `client:rec:`
by `Idempotency.from_body`, the attrs are server-built). So returning `definition_not_found` in their place is exactly the absent answer.

F4. No existing write path outside the router applies TypeAccess. Step writes apply field restrictions only (`StepWrites.check_restrictions/3`,
step_writes.ex:815, any written key in `FieldGrants.load_restrictions` -> `:field_restricted`, mapped :992). `Records` itself has neither
(records.ex:427 says the upsert primitive does not either). So the HTTP routes are the only place a gate belongs; `Records` stays unchanged
(engine, module handlers, exam and scripts write through `Records` with `:tenant`/`Owner` authority and must not gain a caller-principal gate).

F5. The rulings the issue refers to ("refused as the rulings say"): (a) type: #2700 / #2739 / #2659 4.5: denied and absent are one exit, nothing
logged or audited, all reads done unconditionally first (`RequestAccess.ensure_all_visible/3`, `ImportUpsert.precheck/3`). (b) restricted field:
#2697 section 4 (uniform constant 403 `"one or more requested fields are restricted for this caller"`, router :2739-2741, no field/type name; the
existence of a restricted field is already disclosed by the redaction sentinel, so refusing by name leaks nothing new); #2659 4.5 and
`StepWrites` (a restricted written key refused as `field_restricted`; for a bulk request, per entry). No ruling covers PUT replacement; section 5.

F6. The attachment handlers neither call `TypeAccess` nor check record existence in the router; the repository layer (entity_attachments.ex)
answers an absent `(entity_type, record_id)` pair as: upload -> after size check, hash and scan, `upsert_content` then insert, FK violation at
COMMIT, rolled back, `{:error, changeset}` -> 404 (router :1744-1751); list -> 200 `{"items": [], "next_cursor": null}` (no existence check,
by design, entity_attachments.ex moduledoc); content -> `get_content` then a path-vs-row type/record compare -> 404; delete -> `get` then the same
compare -> 404. The router compares the attachment row's type and record to the PATH (:1851-1871, :1936-1948), so a real attachment id under a
wrong path is already a 404. Correction to two earlier notes: gh2700 design F1/F9 and gh2739 attribute the attachment gap to #2718; #2718 is the
INSTANCE attachment routes. The record attachment routes are owned by this issue.

## 2. New module `Letflow.Entities.RecordAccess` (one gate implementation, AC: ONE gate)

Location `lib/letflow/entities/record_access.ex`. Pure of HTTP; takes `user_id`, `entity_type`, `prefix` (INV-1: `prefix` from
`prefix!(conn)`, `user_id` from `conn.assigns.auth_context.user_id`; never from the request).

Types:
- `write_decision :: :hidden | :managed | {:open, restricted :: MapSet.t(String.t())}`
- `attachment_decision :: :hidden | :open`

Functions (signatures only):
- `write(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) :: write_decision()`. Total (never raises on a well-typed call,
  never returns an error tuple). Makes, in this order and ALWAYS all four CALLS, with no short-circuit and no branching on an earlier result
  (the number of SQL statements inside a call is not constant, see I1):
  (i) `ManagedTypes.owner_of/2`; (ii) `TypeAccess.authorized?/3`; (iii) `Definitions.get_active_definition_by_name/2`;
  (iv) `FieldGrants.load_restrictions/3`. Then ONE decision: `:hidden` when (ii) is not `{:ok, :allowed}` OR (iii) is not `{:ok, _}` OR (iv) is
  not `{:ok, _}` OR (i) is an error (every failed read fails closed to hidden, like `precheck/3`); else `:managed` when (i) is `{:ok, _module_id}`;
  else `{:open, restricted}`. Precedence is hidden > managed > open. A `:hidden` value carries NO payload (not the restriction set, not the
  reason), so nothing downstream can tell a denied type from an absent one. No log line, no audit row, no telemetry event is emitted on any
  outcome (INV-8).
- `attachment(user_id, entity_type, prefix) :: attachment_decision()`. ONE read, `TypeAccess.authorized?/3`; anything but `{:ok, :allowed}`
  (denied or a failed read) is `:hidden`. No definition-existence read and no managed read on purpose (section 7): the attachment routes
  work on a type with no active definition today, and `:hidden` is realised by the substitution in section 8, which is the absent answer by
  construction, so existence needs no probe.
- `names_restricted?(field_values :: term(), restricted :: MapSet.t(String.t())) :: boolean()`. Pure. True iff `field_values` is a map with at
  least one top-level key in `restricted` (same predicate as `StepWrites.check_restrictions/3` and `ImportUpsert.check_restrictions/3`; they are
  rewritten to call this one). A non-map is false (the schema/`Records` layer rejects it).
- `hidden_result(entity_type :: String.t()) :: {:error, {:definition_not_found, String.t()}}`. The value `Records.create_record/2`,
  `update_record/2`, `delete_record/2` return for an absent type. The one definition of "what absent looks like" to the renderers.

Invariants (each gets a unit test in `test/letflow/entities/record_access_test.exs`):
- I1 `write/3` makes the same four calls (owner_of, authorized?, get_active_definition_by_name, load_restrictions), in that order, whatever the
  outcome and whatever earlier calls returned; the code after the gate is identical for denied and absent. The statement count inside the calls
  is NOT constant and is not claimed: `get_active_definition_by_name/2` (definitions.ex:318-340) does the tenant lookup plus
  `Activation.resolve` and, only for an existing type, a version read and a definition read; `ManagedTypes.owner_of/2` issues 0 queries for a
  name failing the managed-name format and 2 otherwise. The residual, stated once: a denied EXISTING type differs from an ABSENT type by this
  definition read inside `get_active_definition_by_name/2` (an existing type also does the version and definition reads) and by the post-gate
  work it implies; it is the #2700 R6 accepted residual (gh2700 design ~296-299).
- I2 `write/3` for a denied type and for an absent type returns the identical term `:hidden` (a denied type that is also managed, and one that has
  field restrictions, still returns `:hidden`).
- I3 `write/3` returns `{:open, restricted}` only when TypeAccess allows AND an active definition exists AND the type is unmanaged.
- I4 `attachment/3` performs exactly one read; `:hidden` iff TypeAccess denies.
- I5 neither function writes anything.

TypeAccess is default-allow (`type_access.ex` moduledoc): a tenant with no `entity_type_restrictions` row sees no behaviour change from the type
gate; a tenant with no `entity_field_restrictions` row has `restricted == MapSet.new()` and sees none from the field gate.

## 3. Ordering and the denial answer (decision (2) and (3))

Per record write handler, in this order (handler split in two, names pinned: the existing `handle_create_record/2`, `handle_update_record/3`, `handle_delete_record/3`, `handle_import_records/2` become the deciders (compute `RecordAccess.write/3`, answer `:managed`, else call the body); the existing `*_unmanaged` bodies are renamed `create_record_with_access/3`, `update_record_with_access/4`, `delete_record_with_access/4`, `import_records_with_access/3`, each taking the extra argument `access :: :hidden | {:open, restricted}` last; the names do not clash with `Records.do_create_record/4`, which is private to another module):

1. Route-level `authz_*` permission gate (unchanged; independent of the type).
2. `decision = RecordAccess.write(user_id, entity_type, prefix)` computed FIRST, before the body, path id or query string is read. The same four
   calls happen here, unconditionally and in the same order for denied, absent, managed and open types (statement counts inside the calls
   differ, I1).
3. `decision == :managed` -> `Response.send_problem(conn, Error.entity_type_managed())`, exactly today's guard answer and today's position
   (before the body is read). Reached only for a type that is visible to the caller and has an active definition, so the 403 can never reveal a
   denied type. `{:error, :invalid_schema_name}`-style 500 of the old guard disappears: a failed read is `:hidden` (INV-1 makes it unreachable).
4. Everything the handler does today before it calls `Records` runs unchanged and in the same order for EVERY decision (including `:hidden`):
   record-id cast, body parse, schema validation, `Idempotency.from_body`, `put_legacy_original` (a read), query-string parse, the import
   cap / version / type-match / `upsert_by` checks. This is what makes a malformed body on a denied type the absent-type answer (F2).
5. At the write point (where the handler calls `Records.create_record` / `update_record` / `delete_record`), and only there:
   - `:hidden` -> the value `RecordAccess.hidden_result(entity_type)` is passed to the existing `render_record_command/3` instead of calling
     `Records` (no event, no idempotency key claim, no row, no promoted-column write, no audit: `Records` is not reached). It renders
     `Response.not_found(conn)`: status, headers and body are produced by the same function as for an absent type.
   - `{:open, restricted}` -> the field checks of section 4, then `Records` exactly as today.
6. An ABSENT type is `:hidden` too (no active definition), so absent and denied do not just render equally, they execute the same
   code: the gate's four calls, the same step-4 code, then the substitution. Neither reaches `Records`, so neither reaches
   `EntityTypeInstance.get_or_create` (records.ex:955-957, the first write-capable step of `run_command`): a hidden write creates no synthetic
   instance row either. The only remaining difference is the I1 residual (#2700 R6).

Per-route denial answer (a write has no 200-empty analogue; the answer is whatever an absent type gets, which is the generic 404 except for
two route-shaped cases):

| Route | denied == absent answer |
|---|---|
| POST /records/:t | 404 generic Problem, after body/key validation (400/422 first if the body is bad, same as absent) |
| PUT /records/:t/:id | 404 (invalid id 404; body errors first, same as absent) |
| DELETE /records/:t/:id | 404 (invalid id 404; invalid `expected_last_event_global_seq` 400 first, same as absent) |
| POST .../import, create mode | cap/version/mismatch/`upsert_by` errors first; then: empty `records` -> 200 `{"results": []}`; first entry present -> 404 (the existing first-entry fold); the substitution is a stub writer inside `import_one_entry`, so non-map entries, derived idempotency keys and every other line are the same code as absent |
| POST .../import, `upsert_by` | same pre-checks, then the `precheck` 404 (even for empty `records`), as absent |

A caller that LACKS the route permission still gets the route-level 403 for every type including absent ones; the type does not influence it.

Timing: denied and absent run the same calls and the same code after the gate (point 6); the I1 residual is stated, not claimed away. The
visible-type path adds the four gate calls to today's work (cost in section 8).

Byte-identity scope: status, headers and body of `Response.not_found/1` are a function of nothing request-specific except `trace_id` (and the
Problem `instance` member if the shaper echoes the path; the tests normalise only those two, as #2659's `strip_trace/1` does, and also compare
the same type NAME across two tenants so that `instance` needs no normalisation at all, section 10).

## 4. Field restrictions on written fields (decision (4))

Applied only on `{:open, restricted}` at the write point (never on `:hidden`: a denied type has no restriction set to apply, so a denied caller
cannot learn that a field is restricted before learning the type exists). Refusals happen BEFORE `Records` is called: no validation of the
restricted value, no event, no key claim.

| Route | Rule | Answer |
|---|---|---|
| POST create | `names_restricted?(field_values, restricted)` | 403 `Response.forbidden(conn, "one or more requested fields are restricted for this caller")`: the #2697 constant. The detail string becomes one shared module attribute used by `render_query_error` (:2739) and the new write renderer, so the two cannot diverge. No field name, type name or value in the body or logs |
| PUT replace | `MapSet.size(restricted) > 0`, whatever the body (decided before any record lookup, AFTER id cast and body validation, see the pinned order below) | the same 403 |
| DELETE | no key check (no body); the RESPONSE is redacted | 200 with `field_values` passed through `FieldGrants.redact_field_values/2` |
| POST / DELETE success body | for `{:open, restricted}` with `restricted` non-empty | `record_map` output redacted the same way (see 4.1) |
| Import create mode | per entry: `names_restricted?(entry.field_values, restricted)` | that entry's result `{"status":"error","reason":{"type":"field_restricted"}}` (reason already in `ImportUpsert.error_reasons/0`, rendered by `import_reason_json/1`, :1506); other entries proceed; HTTP 200 as today |
| Import upsert | unchanged (`ImportUpsert.check_restrictions/3`, now calling `names_restricted?/2`) | unchanged |

Why PUT is refused for any restricted-field actor (the replacement problem): `update_record` replaces `field_values` wholesale
(import_upsert 4.5, records.ex update path). An actor who cannot see a restricted field cannot send its old value; every PUT by such an actor
would erase it (or overwrite it with the redaction sentinel the actor read, a corruption already possible today). Options weighed:
(a) blanket refusal, chosen; (b) refuse only when the existing record holds a restricted key (needs a record lookup, so 403-vs-404 becomes a
record-existence signal to a type-allowed actor, and still blocks the same actors for any record that has the field set); (c) merge semantics that
preserve unseen restricted values (changes `update_record`'s documented whole-document contract, the event payload, and replay; out of scope, OQ-1).
(a) needs no lookup, so it leaks nothing about records, and is exactly the upsert rule (`any restricted field + matching existing record ->
field_restricted`) applied where "matching existing record" cannot be known without a lookup. Consequence, stated plainly: an actor (a tenant
admin included) with an ungranted restricted field on a type cannot PUT records of that type through this route; the remedy is a field grant,
same as for the upsert import. POST of a record that does not mention a restricted field still works.

DELETE (CDV F1, BLOCKER, supervisor prio 1): the earlier claim that DELETE "neither reads nor sets a restricted value" and returns the
caller's "own redactable view" was WRONG. `Records.delete_record` returns the existing row with `field_values` unchanged (records.ex
~648-660; an already-deleted record returns the same row), and `render_record_command/3` (:1595-1603) renders it through `record_map/2`
(:2934-2944), which applies `Decimals.render_field_values` and NO `FieldGrants` redaction. `entities_decimal_strict_reads_test.exs:775-777`
shows the DELETE body carries `field_values`. So today any caller with `EntitiesRecordsWrite` who knows a record id reads every restricted
field with one DELETE (and re-DELETE of a deleted record repeats it). Decision: DELETE is allowed for an actor with restricted fields, but
its response MUST be redacted (refusing was weighed and rejected: it would make partly-restricted types undeletable by ordinary operators;
the delete itself reads and sets nothing). Rule, shared by every `{:open, restricted}` success rendering: when `restricted` is non-empty,
`record.field_values` is passed through `FieldGrants.redact_field_values/2` (value becomes the `__field_redacted__` sentinel, the #2697 /
REQ-231 read-side behaviour) BEFORE `Decimals.render_field_values`, in the same order the read routes use. PINNED mechanism: `render_record_command/3` becomes
`render_record_command/4` `(conn, result, status, restricted)`; in the `{:ok, %{record: %Latest{}}}` clauses (:1595, :1602), when
`MapSet.size(restricted) > 0`, `record.field_values` is passed through `FieldGrants.redact_field_values/2` and the redacted `Latest` goes to
`record_map/2`, which is UNCHANGED (so redaction precedes `Decimals.render_field_values`, as on the read routes). The three handlers (POST
:1039, PUT :1109, DELETE :1174) pass the set taken from `{:open, restricted}`; the `:hidden` path and every error clause never receive or use
it (the error clauses ignore the fourth argument). The sentinel is `:__field_redacted__` (query/field_grants.ex ~113). The redaction
applies on the first delete and on the re-delete (no-op success of an already-deleted record). POST: redaction is DEFENCE IN DEPTH only and
unreachable by construction (`Records` applies no defaults, records.ex ~1712; a restricted key in the body is refused before `Records`;
idempotency keys are namespaced per actor), so it is covered by a UNIT assertion on the helper, not an HTTP-level echo test. PUT needs none
(refused for these actors) but passes the set uniformly. The stored event and row are untouched; this is rendering only (INV-2).

### 4.1 Sweep of every renderer of record `field_values` (supervisor ruling b)

Grep `record_map(`, `"field_values" =>` over `lib/` on `27274bd2`:

| Renderer | Used by | Redaction today | Decision |
|---|---|---|---|
| `record_map/2` (:2934) via `render_record_command/3` (:1595, :1602) | POST, PUT, DELETE (and re-DELETE) | NONE | FIX in PR A (above) |
| `record_map/2` via `query_item_map/2` (:2847) | `/query` | yes: `redact/3` (:2087-2108) on the page before shaping | none |
| `entity_row_map/2` (:2896-2902) | `/query` promoted rows | yes (same `redact_page`) | none |
| `export_record_map/2` (:2643-2660) | export | yes (`export_redact`, :2468) except `unredacted: true`, which needs `EntitiesRecordsExportUnredacted` and is audited (`audit_exempted`) | none |
| import result JSON (`import_entry_result_json`, :1436-1465) | import | echoes `record_id`/`source_record_id`/`outcome`/`external_ref` only, never `field_values` | none |
| `exam_row_json/1` (modules/exam/router.ex:1005-1020) | exam list | NONE by design (comment ~:392: no restriction row for type `exam`) | finding: not a caller of the generic gate; unredacted if an operator later adds a row for `exam`. Listed, not changed here (OQ-10) |
| `ScriptReads` (entities/script_reads.ex:179, :302) | script reads | restricted fields excluded by policy (`Scripts.Policy`) | none |
| Record history / audit / webhook / DLQ copies of event `field_values` | decision 0059, REQ-516 | n/a (route not built) | already tracked by 0059 / #2701; instances routes hide the synthetic instances (#2702) |

So A fixes the one unredacted generic caller (`render_record_command/3`); the rest are covered or tracked elsewhere.

PINNED order, one place (CDV F4), for a visible (`{:open, restricted}`) type:
- POST: body parse (400) -> schema (422) -> idempotency key (422) -> restricted KEY 403 -> `Records`.
- PUT: record id cast (404) -> body parse (400) -> schema (422) -> idempotency key (422) -> restricted-SET 403 (any restricted field on the type,
  whatever the body) -> `Records`.
- DELETE: record id cast (404) -> `expected_last_event_global_seq` (400) -> `Records` -> redacted response.
- Import create: caps and checks as today -> per entry restricted key `field_restricted` -> `Records`.
The refusal never precedes validation, so validation errors depend only on the request; `put_legacy_original`'s read still runs before it.
A `:hidden` decision replaces ALL of the restricted steps (a denied type never reveals field restrictions).

## 5. Import (decision (5): ONE gate, no second implementation)

- The router computes `decision = RecordAccess.write/3` once at the top of `handle_import_records` (replacing `guard_tenant_write`), `:managed`
  -> 403 as before (before the body is read), otherwise both modes receive the decision.
- Upsert mode: `ImportUpsert.precheck/3` becomes `precheck(decision :: :hidden | {:open, restricted}, prefix) ::
  {:ok, MapSet.t(String.t())} | {:error, :not_found | :event_schema_outdated}`. It keeps its one unconditional
  `Registry.max_schema_version("ENTITY_RECORD_CREATED", prefix)` read, then: `:hidden` -> `{:error, :not_found}`; open with a version below 2 ->
  `{:error, :event_schema_outdated}`; else `{:ok, restricted}`. The three reads it used to do itself (TypeAccess, definition, restrictions) now
  live only in `RecordAccess.write/3`, so the #2659 behaviour (all reads unconditional, one 404 exit, hidden beats 503) is preserved and the
  duplicated read logic is deleted. `ImportUpsert.run/6` and its entry-level rules are unchanged apart from `check_restrictions/3` calling
  `RecordAccess.names_restricted?/2`. `precheck/3` has no caller outside the router and no direct test (grep), so the arity change is
  contained.
- Create mode: `run_import_mode(:create, ...)` receives the decision. `:hidden`: `import_one_entry` obtains its result from
  `RecordAccess.hidden_result/1` instead of `Records.create_record/2` (the rest of the function, including the first-entry
  `definition_not_found` fold and the `[]` -> `{:ok, []}` clause, is the existing code). `{:open, restricted}`: per entry,
  `names_restricted?` -> `{:error, source_record_id, {:error, :field_restricted}}` before `create_record`; with an empty set the request is
  byte-identical to today. The "without `upsert_by` the response is byte-identical" promise of #2659 holds for every caller without restricted
  fields; callers with restricted fields now see per-entry `field_restricted` on entries naming a restricted key (this is the intended change).
- The check order documented at :1204-1232 (cap, schema version, type match, `upsert_by`) is untouched, so "an invalid `upsert_by` is a 422 even on
  an unknown type" (entities_import_upsert_test) still holds, and the same now holds for a denied type.

## 6. Interaction with `guard_tenant_write` (decision (3))

`guard_tenant_write/3` stays for the two definition routes (:771, and `create_definition` after its body parse). It is REMOVED from the four
record write handlers; its managed answer moves into `RecordAccess.write/3` at precedence below `:hidden`. The "Inheritance rule" in the router
moduledoc (:46-52: any generic record write route MUST call `ManagedTypes.check_tenant_write/2` first) is rewritten: any generic record write
route MUST call `RecordAccess.write/3` first and apply its decision as in section 3; the doc line at :1654 about the race
(`render_record_command` `:entity_type_managed` clause) stays valid because `Records` still re-checks under its own lock.

Behaviour matrix (caller x type), after:

| Type | Denied by TypeAccess | Allowed |
|---|---|---|
| absent / no active definition | 404 path | 404 path |
| tenant-owned | 404 path | normal |
| module-managed | 404 path (NOT 403) | 403 `entity_type_managed` before the body, as today |

Edge, noted: a managed type that has NO active definition for an allowed caller moves from 403 to the 404 path (it is indistinguishable from
absent now). Such a state is a half-installed or uninstalled module; accepted (OQ-6).

## 7. Attachment routes (decision (6))

Scope decision: all four attachment handlers are gated, including list and content (reads), because the issue names them and because a denied
type's attachment metadata and bytes are tenant data returned today to any caller holding `EntitiesAttachmentsRead`. Their instance-vs-record
scope: they are RECORD attachments keyed by `(entity_type, record_id)` in `entity_record_attachments` (not instance attachments; #2718 is the
instance routes and untouched). The `record_id` in the path is only meaningful together with the type, which is why the type gate is the whole
fix: no new record-existence check is added (it would be a new behaviour for allowed callers and #2718's territory for instances).

Gate: `RecordAccess.attachment/3` (one TypeAccess read) at the top of each handler, before `cast_record_id`. Applied by SUBSTITUTION so the
denied path runs the same code as the absent path, not a parallel one:

- Upload: `:hidden` -> the handler continues unchanged (record-id cast, file-part check 422 `missing_file`) and calls
  `EntityAttachments.upload/2` with `record_id` replaced by a freshly generated UUID. No such record can exist, so the call yields exactly what
  an absent pair yields: size 413, infected 422, scan unavailable 503 for the same inputs, otherwise the FK failure -> 404. The transaction rolls
  back, so no `entity_record_attachments` row and no `repository_artifacts` row persists. Side channel check: the infected-upload warning
  (`log_infected_upload_attempt`) logs the caller's type and the substituted id; identical in shape to the absent case, no new tenant data.
- List: `:hidden` -> `EntityAttachments.list/2` called with the substituted `record_id`: an empty page, with the same page-size / cursor
  validation errors (400 / 422) as for an absent record. Absent-type bytes: `{"items": [], "next_cursor": null}` with 200.
- Content GET (CDV F3): `:hidden` -> the handler continues unchanged with BOTH `record_id` (after the cast) and `attachment_id` replaced by
  freshly generated UUIDs, so `get_content/2` looks up a row that cannot exist and returns `{:error, :not_found}` -> 404, exactly the
  absent-attachment path. No get-and-discard, nothing loads `repository_artifacts` bytes for a denied type, and `:content_missing` (500) /
  `:not_available` (409) can never surface for it.
- Delete (CDV F3): `:hidden` -> same substitution of `attachment_id`; `fetch_scoped_record_attachment_metadata` finds nothing -> 404 and
  `EntityAttachments.delete/2` is never reached.
No managed check is added (attachments on managed types are deliberately out of managed scope, #2582) and no field-restriction check (an
attachment is not a `field_values` document, router :1952-1960 INV-2 comment). No change to `EntityAttachments`.

## 8. Backward compatibility, callers, rollout (decision (7))

Who can write today what they cannot read: every caller of the four HTTP write routes and the four attachment routes in a tenant that has at
least one `entity_type_restrictions` row (type gate) or `entity_field_restrictions` row (field gate). Tenants with neither see no response
change. Re-grep result (implementer re-runs and quotes it in the PR):

- Internal writers do NOT use these routes and are unaffected: engine step writes and module write handlers (`Records` with `:tenant`/`Owner`
  authority, own FieldGrants check), exam module (`lib/letflow/modules/exam/*`, managed types, 403 on the HTTP route already), scripts
  (`ScriptReads` is read-only), WMS/offline flows reached through module handlers. The exam answer-key restrictions
  (`Exam.answer_key_fields`, exam.ex:96-160) are on managed exam types whose HTTP writes are 403 already (visible callers) or the 404 path
  (TypeAccess-denied, none are type-restricted by default).
  (CORRECTED, see "As built": `question.explanation` and `answer_option.is_correct/likert_*` sit on UNMANAGED authoring types.)
- `web/src/api/entities.ts` (:61-90) is the only SPA caller (`EntityCrudPage.tsx`): a user with a restricted field on a type now gets 403 on
  edit (PUT) and on create when the form submits a restricted key; before it silently wrote the sentinel/erased the value. A user type-denied
  cannot navigate to the type at all. No `web/` change is required for correctness; a friendlier 403 message is a FRONTEND follow-up (OQ-9).
- Caller grep results (CDV F7, recorded; implementer re-runs): `scripts/seed_vortex_entities.sh` is the ONLY script writing records over HTTP;
  `web/src/api/entities.ts:61-90` the only SPA caller; `test/letflow/scripts/seed_scripts_no_argv_payload_test.exs` is a STATIC scan that counts
  the `:stdin`/`:file`/`:literal` body modes of the script's curl calls (~:390-396) and expects `[:file, :literal, :stdin, :stdin, :stdin]`;
  the stub-curl numbered-invocation harness (~:551+) applies to the DEFINITION scripts only. `test/scripts/seed_vortex_entities_activate_test.exs`
  extracts functions from the script and is unaffected unless those functions change.
- BREAKING for `scripts/seed_vortex_entities.sh`: step 2 restricts `shipment_manifest` (type, no grant for the seeder) and
  `production_batch.cost_figure` (grant only for Anna); step 3 then imports as the admin token. After this change step 3 gets 404 for
  `shipment_manifest` (`curl -sf` exits non-zero) and a 200 with per-entry `field_restricted` for `production_batch` rows carrying `cost_figure`
  (silent partial seed). Fix in PR A: the script resolves the seeding actor with its existing `lookup_user_id` (a new required
  `SEED_ACTOR_USERNAME`, which MUST name a DEDICATED non-persona account: if it were Karl, Anna or an admin persona the UAT redaction/denial scenarios depend on, the grant would defeat them) and adds that user to the `type_grants` / `field_grants` of the same restrictions import; it also fails loudly on any
  `status: "error"` entry (today it ignores the response body). Test consequences: keep the three-`:stdin` invariant of
  `seed_scripts_no_argv_payload_test.exs` (the grant payload and any captured import response must not add a payload to argv; capture the
  response through stdout/a temp file, not a new literal argument); update that test's expected list only if the number of body-carrying curl
  calls really changes. PINNED binding: the grants go to the user named by `SEED_ACTOR_USERNAME` but the import runs as the `QA_AUTH_TOKEN` user, so
  the script MUST compare the token owner's own id (`GET /api/v1/me`, field `.id`, `Routers.Me`, api_pipeline.ex ~:244) against the looked-up id and exit non-zero on mismatch (otherwise the grant silently does
  nothing). (As a side
  note, since #2700 the script's `existing_keys_for` pre-check on `shipment_manifest` already returns empty for a denied seeder, so its
  idempotency was already broken; the grant repairs that too.) RESOLVED (supervisor 2026-10-18/19, OQ-4). The PR body must state that any RESEED of QA is UAT-class and needs a written APPROVE from letflow-2.
- Existing tests (CDV grep result): router tests that insert restrictions (`entities_test.exs` and the others listed by the grep) do NOT call
  the write routes under a restriction, and no UAT fixture PUTs records, so no existing test is expected to change answer. The implementer
  re-runs the grep; any test found writing a denied type or a restricted key over HTTP is updated to the new answer in PR A, not weakened.
- Docs to update in PR A, owner DOC-UPDATER: `docs/runbooks/gh2659-external-ref-rollout.md` and `docs/guides/backend_developer_guide.md`
  (the generic record write routes now go through `RecordAccess`; PUT/DELETE/POST behaviour for restricted-field actors).
- Rollout: no migration, no feature flag, no schema change, no event change. One deploy; the only data-dependent behaviour is keyed off existing
  restriction rows. Rollback = revert; nothing to repair. Cost: four small indexed reads per record write request (managed stamp, restriction
  existence incl. the tenant lookup, definition resolve, field restriction anti-join), plus one read per attachment request; the import pays them
  once per request, not per entry (the same cost `precheck/3` already pays in upsert mode). `Records` keeps its own definition read (its API
  is not changed to accept a pre-resolved definition; that optimisation is out of scope).
- Residual window: the gate reads and the `Records` write are separate statements, so a restriction row inserted in between is not seen by that
  one request (same shape as the ImportUpsert 4.5 pre-check, and as the router's old managed guard, which `Records` re-checks). Accepted, stated
  for SECURITY-REVIEWER.

## 9. Compat of the response contract (summary)

Open type, caller without restricted fields: every route byte-identical to main. Open type, caller with restricted fields: POST naming a
restricted key, any PUT, import entries naming a restricted key are refused as in section 4 (new). Denied/absent: section 3. Managed + allowed:
unchanged. Managed + denied: now the 404 path (new, the point of this issue). Attachments: denied -> the absent answers (new).

## 10. Test plan, reproduce-first (decision (8); AC 2, 3)

Write the failing tests FIRST on main and quote the red run in the PR, then implement. Real Postgres, tenant schemas, no mocks, real
`Letflow.Router` dispatch (pattern of `entities_import_upsert_test.exs`). Files: `test/letflow/routers/entities_write_type_access_test.exs`
(single-record writes + import), `test/letflow/routers/entities_attachments_type_access_test.exs`, `test/letflow/entities/record_access_test.exs`
(I1-I5), plus edits to `entities_import_upsert_test.exs`.

Fixture trick for byte-identity: tenant T1 holds type `X` restricted (a `entity_type_restrictions` row) and the caller U1 has no grant; tenant T2
has NO type `X`. Same request (same method, path, body, headers) to both; compare `status`, response headers (minus per-request ones), and body
with `trace_id` removed (and `instance` removed only if present). Because the path is identical, no other normalisation is needed. A second
variant uses an absent name in the same tenant.

Per-route RED expectations on main (these must FAIL before the change; quote the run): denied-vs-absent for POST, PUT, DELETE, import create
and import-create-empty (items 1, 2 where a denied type is written or answers differently, 3, 5: today a denied type is simply written);
managed-denied (3: 403 vs 404); restricted-key POST/PUT/import-create (8: written today); DELETE and POST redaction (8: the real value is
returned today); attachments upload/list/content/delete denied vs absent (today a denied type works like any other). GREEN on main by design:
allowed-caller goldens (7), precedence of malformed bodies on ABSENT types, and the existing upsert suite (10), which must stay green
through the refactor.

Per route (POST, PUT, DELETE, import create, import upsert, attachment upload, list, content, delete), all with the denied caller:
1. denied vs absent byte-identical for a well-formed request (existing record id for PUT/DELETE/attachments, so the denied type really has
   data);
2. denied vs absent byte-identical for a MALFORMED request (non-object body 400, missing `field_values` 422, bad idempotency key 422, bad
   `expected_last_event_global_seq` 400, bad record id 404, bad import cap/version/mismatch/`upsert_by`, missing multipart `file`, bad
   `page_size`/cursor), proving validation is applied before the hidden answer exactly as for absent;
3. denied vs absent for a managed type: a managed type (fixture_managed) denied to U1 equals the absent answer (NOT 403); an allowed caller
   still gets 403 `entity_type_managed` before the body is read (the existing gh2583 tests stay green);
4. import create: empty `records` -> 200 `{"results":[]}` for denied == absent; non-empty -> 404 for both; a non-map first entry behaves the same
   for both; upsert mode -> 404 for both even with empty `records` and with a malformed first-entry ref (T14 style);
5. no side effects on a denied request, by counting rows before and after (a hidden write never reaches `EntityTypeInstance.get_or_create`,
   so also assert no `entity_type_instances` row is created for the denied type): `events`, `entity_record_latest` (and any promoted-column table the
   type has), event-store idempotency keys, `entity_record_attachments`, `repository_artifacts`, audit log rows; all equal; also assert no
   warning/error log line (`capture_log`) except the infected-upload warning, which is asserted equal to the absent case;
6. call-sequence parity (CDV F2): assert the gate makes the same four calls in the same order for denied and absent (`:erlang.trace/3` or `:dbg` on `ManagedTypes.owner_of/2`, `TypeAccess.authorized?/3`,
   `Definitions.get_active_definition_by_name/2`, `FieldGrants.load_restrictions/3`, asserting the call order), and that the statements AFTER
   the gate are the same list for denied and absent: record `Repo` query telemetry in order for each request and CUT the log after the
   `entity_field_restrictions` query (the last gate call, iv), then compare the remainder; the total count is not compared (the
   existing-vs-missing definition read inside the gate is the stated I1 residual). The router is dispatched in-process via `Letflow.Router.call/2`, so tracing runs in the TEST process: `:erlang.trace(self(), :call, ...)` with `:erlang.trace_pattern` on the four MFAs (`ManagedTypes.owner_of/2`, `TypeAccess.authorized?/3`, `Definitions.get_active_definition_by_name/2`, `FieldGrants.load_restrictions/3`); if a test uses Tasks or another process the tracer must be set on that pid;
7. an allowed caller (no restriction rows in the tenant, and with unrelated restriction rows) is unchanged: status and body equal to the
   pre-change golden for create/update/delete/import/attachments;
8. field restrictions on an open type (actor holds none of the grants): POST naming a restricted key -> 403 with the constant detail and no event;
   POST naming only unrestricted keys -> 201; PUT with any restricted field on the type -> 403 whatever the body and whether the record exists
   (no 404/403 difference between a live and a random record id), with the pinned order: an invalid record id is still 404 and a malformed
   body is still 400/422 BEFORE the 403; PUT for an actor WITH the grant -> 200 and the full replacement; DELETE by a
   restricted-field actor -> 200 whose `field_values` carry `__field_redacted__` for every restricted field and never the stored value, also on
   a re-DELETE of the already-deleted record; the DELETE (first, re-delete) assertions drive the REAL router, and the same body-level assertion is made for PUT (an actor with a
   restricted set is refused, so only a granted or unrestricted actor gets a 200) and for POST with an unrestricted actor; a UNIT test on
   `render_record_command/4` shows the POST/PUT clauses redact when given a non-empty set (defence in depth, no HTTP echo test is claimed for
   POST); an actor WITH the grant sees the real values; import create with one entry naming a restricted key -> that entry `field_restricted`, others
   created, HTTP 200, the refused entry wrote nothing; a granted actor -> all created;
9. precedence: denied AND restricted-key body -> 404 path (not 403); allowed + restricted key + malformed body -> the validation error (POST and PUT alike, per the pinned order in section 4);
10. upsert refactor regression: the full existing `entities_import_upsert_test.exs` suite stays green; the "one schema-version read per request"
    test still passes; add: a denied type with `upsert_by` and a tenant below CREATED v2 is 404, not 503 (hidden beats outdated);
11. attachments content GET / delete: a denied type with a real attachment id answers the same bytes as a random attachment id, and no
    `repository_artifacts` content read is issued for it.

## 11. Route inventory and snapshot (decision (9))

No route is added, removed or renamed; no policy key changes (the same nine `authz_*` lines at :311-:432). So
`test/fixtures/route_scope/tenant_wide_default_routes.txt` (e.g. lines 3, 4, 23, 24, 85-88, 135) and `test/support/route_inventory.ex` need NO
change, and the route-snapshot test must stay green untouched; if it goes red the change is wrong. Security triggers (CDV F6):
`lib/letflow/routers/entities.ex` is NOT on the explicit mandatory list (`.claude/agents/security-reviewer.md:29-40`) but is in scope through
the tenant-data-path and response-shaping bullets; `lib/letflow/api/authorization.ex` IS on the explicit list. The earlier plan to edit the
`authorization.ex` moduledoc is DROPPED (the sentence goes in the router moduledoc table instead), so no PR here touches an explicit-list path.

## 12. PR split (decision (9); supervisor ruling a, 2026-10-18/19)

Mandatory gates on each: SECURITY-REVIEWER (hard gate), REVIEWER, scoped tests one file at a time, compile with warnings as errors, full-repo
format check read by exit code. No migration or event-schema change in either. `core-directives.md:699-700` allows several PRs per issue with a
reason recorded in the PR body; the reason sentence for both bodies: "split because the record routes carry the confidentiality fix and the
behaviour breaks (PUT, seed script) and must land first with their own SECURITY review; the attachment routes are independent code paths
reusing the same gate." PR A body says "Refs #2784", PR B "Closes #2784" (as #2697 did).

Order decision: the validator suggested attachments first because list and content GET return denied-type bytes. Weighed against the DELETE
leak: DELETE (and re-DELETE) returns every restricted FIELD value of any record to any `EntitiesRecordsWrite` caller who has a record id, a
live leak independent of any type restriction; the attachment routes need an `EntitiesAttachmentsRead` grant and only matter for TYPE-denied
types, a narrower population. The supervisor ruled DELETE first (A), recorded here.

- PR A (lands FIRST, ~500-650 changed lines plus tests), closes the confidentiality gap on the record routes alone: `RecordAccess`
  (`write/3`, `names_restricted?/2`, `hidden_result/1`) + unit tests; the response redaction of `render_record_command/3` (DELETE, re-DELETE,
  POST echo; section 4); the four record handlers (hidden, managed ordering, restricted key, PUT blanket 403, import create per entry); the
  `ImportUpsert.precheck` refactor; router moduledoc and inheritance-rule rewrite; the shared 403 detail attribute; the seed script fix and its
  harness test updates. Closes AC 1 and AC 2/3 for routes 1-4. Needs SECURITY-REVIEWER before merge, not held for B.
- PR B (~150-250 lines plus tests): `RecordAccess.attachment/3`, the four attachment handlers via substitution, the attachment test file;
  closes AC 2/3 for routes 5-8 and the issue. Depends on A only for the module file.
- Window: until B merges, attachments of type-denied types stay open; B follows in the next merge slot.

## 13. Risks

R1 (SEC) substitution-based denial couples correctness to "the stub returns exactly what `Records` returns for an absent type"; mitigated by
tests 1-4 running every route against both a denied and an absent type and by `hidden_result/1` being the single definition. R2 PUT is stricter
than before for restricted-field actors (a behaviour break by intent, OQ-1). R3 the seed script and any UAT/QA flow that writes restricted
types as an admin (OQ-4). R4 four extra reads per write request. R5 a half-installed managed type changes 403 -> 404 (OQ-6). R6 the
non-transactional gate/write window (section 8). R7 engine step writes and module handlers also lack TypeAccess (OQ-3), so a type-denied actor
who can start a process whose step writes that type still writes it: out of scope here, to be filed.

## 14. Rulings and open questions

RESOLVED (supervisor 2026-10-18/19), recorded as decisions:
- OQ-1 RESOLVED: ship the blanket 403 for PUT by an actor holding ANY restricted field on the type now; letflow-2 files a follow-up issue for
  merge semantics. UAT impact: non-Anna users editing `production_batch` (restricted `cost_figure`) lose PUT.
- OQ-2 RESOLVED: DELETE allowed but REDACTED (section 4, F1).
- OQ-3 RESOLVED: letflow-2 is the sole filer of ONE follow-up issue covering the definition write routes, `POST /restrictions/import` and
  the engine step-write / module-handler paths; filed before PR A merges. Not filed by this note.
- OQ-4 RESOLVED: required `SEED_ACTOR_USERNAME` (dedicated non-persona account), fail loud on any `status: "error"` entry, update the stub-curl
  harness tests; any RESEED of QA is UAT-class and needs a written APPROVE from letflow-2 (stated in the PR body).
- OQ-5 RESOLVED: attachment list and content GET are in scope.
- OQ-6 RESOLVED: accept (a managed type with no active definition moves 403 -> 404 for allowed callers).
- OQ-7 RESOLVED: two PRs, reason sentence in the bodies, A first (section 12).
- OQ-8 RESOLVED: reuse the #2697 constant 403; per-entry `field_restricted` for imports.
Still open:
- OQ-9: FRONTEND follow-up for a friendly message on the new 403 (non-blocking).
- OQ-10: `exam_row_json` returns record `field_values` with no redaction step (by design today); decide whether the exam module should apply
  `FieldPolicy` if a restriction row for `exam` is ever added (not this PR).

## As built (PR A, ELIXIR-DEV, 2026-10-19)

- Exam answer-key restrictions are on UNMANAGED authoring types (`question`, `answer_option`), not on managed ones (the claim at section 8 is wrong). After PR A an actor without a grant gets: POST naming `is_correct` 403, any PUT of `question`/`answer_option`/`session` 403, import entries `field_restricted`, DELETE 200 redacted. `Exam.on_install` inserts restriction rows and no grants, so the rollout needs grants first (runbook `docs/runbooks/exam-snapshot-rollout.md`, guide section 10). Tests `exam_managed_types_http_test` T-23 and `exam_snapshot_leak_test` T-30(4) were changed to these answers, plus a granted-actor success path.
- `StepWrites.check_restrictions/3` and `HandlerWrites` still duplicate the `names_restricted?/2` predicate (engine path; follow-up with OQ-3).
- `render_record_command/4` is `@doc false def` (public only for unit tests); `render_record_command/3` is kept for the error clauses, and /4 delegates to it for every non-success result.
- Token-owner check: `Routers.Me` has only `/memberships` and `/modules`; `GET /api/v1/me` does not exist, so the pinned `.id` comparison could not be built. The script probes `GET /entities/definitions/by-name/shipment_manifest` after the restrictions import: 200 proves the token holds a type grant (the seeder's is the only one seeded), NOT identity, and it cannot run before the grants are written (on a first run the restriction row does not exist yet, so the probe would pass for any token). The persona guard (Anna/Karl refused), the exact-username lookup and the per-entry `status: "error"` scan close most of the remaining gap.
- Changed assertion: the create-mode import (no `upsert_by`) now refuses an entry naming a restricted key per entry (`entities_import_upsert_test`: "the same actor WITHOUT upsert_by is unchanged" became a `field_restricted` entry).
- Accepted-class race (SECURITY F4): the gate reads and the `Records` write are separate statements, so a restriction or grant row changed in between is not seen by that one request (as section 8 "Residual window").

## As built (PR B, ELIXIR-DEV, 2026-10-19)

- `RecordAccess.attachment/3` is one `TypeAccess.authorized?/3` read; anything but `{:ok, :allowed}` is `:hidden`. Type `attachment_decision :: :hidden | :open`.
- Each of the four handlers computes the decision first (before `cast_record_id/1`) and, inside its existing `with`, substitutes AFTER the cast: `record_id = visible_attachment_id(access, record_id)` (and `raw_attachment_id` for content GET and delete). Substituting before the cast would turn a malformed id into a valid random one and make list answer 200 where an absent type answers 404, so the order is load-bearing. No other handler line changed; the 422 missing-file, page-size and cursor checks therefore run first for a denied type exactly as for an absent one.
- A visible type with an absent record or attachment answers the same as a denied one (upload FK failure at COMMIT -> 404, empty page, 404, 404); test T3 compares all three tenants. The FK-failure note holds: the substituted upload takes the same `upsert_content` then insert then rolled-back path.
- Not tested (no hook for it in this suite): the 413 oversize and 422/503 content-scan outcomes of upload (they precede any type-dependent line, unchanged code).
- No route, policy key, inventory or snapshot file changed.
