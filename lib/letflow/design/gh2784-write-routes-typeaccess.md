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
rule). DELETE needs the type gate only. `ImportUpsert.precheck/3` is refactored onto the same gate so there is one implementation.
Two PRs (section 11).

## 1. Findings: every write route, re-grepped on main `27274bd2` (AC 1)

`lib/letflow/routers/entities.ex` (3025 lines). `authz_*` macros = the route-level permission gate, independent of the type, so it cannot
distinguish denied from absent and needs no change.

| # | Route (macro line) | Handler (line) | Gate state BEFORE | Gate state AFTER |
|---|---|---|---|---|
| 1 | `POST /records/:entity_type` `:EntitiesRecordsWrite` (:311) | `handle_create_record` :1018 -> `create_record_unmanaged` :1022 | `guard_tenant_write/3` (:2972, managed 403) only; no TypeAccess, no FieldGrants | `RecordAccess.write/3` decision; hidden -> 404, restricted key -> 403 |
| 2 | `PUT /records/:entity_type/:record_id` `:EntitiesRecordsWrite` (:315) | `handle_update_record` :1083 -> :1089 | managed guard only | decision; hidden -> 404, actor has any restricted field -> 403 |
| 3 | `DELETE /records/:entity_type/:record_id` `:EntitiesRecordsWrite` (:319) | `handle_delete_record` :1155 -> :1161 | managed guard only | decision; hidden -> 404; no field check |
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
  never returns an error tuple). Performs, in this order and ALWAYS all four, with no short-circuit and no branching on an earlier result:
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
- I1 `write/3` executes exactly four reads per call, whatever the outcome (denied, absent, managed, open, restriction rows present or not).
- I2 `write/3` for a denied type and for an absent type returns the identical term `:hidden` (a denied type that is also managed, and one that has
  field restrictions, still returns `:hidden`).
- I3 `write/3` returns `{:open, restricted}` only when TypeAccess allows AND an active definition exists AND the type is unmanaged.
- I4 `attachment/3` performs exactly one read; `:hidden` iff TypeAccess denies.
- I5 neither function writes anything.

TypeAccess is default-allow (`type_access.ex` moduledoc): a tenant with no `entity_type_restrictions` row sees no behaviour change from the type
gate; a tenant with no `entity_field_restrictions` row has `restricted == MapSet.new()` and sees none from the field gate.

## 3. Ordering and the denial answer (decision (2) and (3))

Per record write handler, in this order (handler = the existing `*_unmanaged` function split in two: a thin wrapper that decides, and the
existing body that now receives the decision):

1. Route-level `authz_*` permission gate (unchanged; independent of the type).
2. `decision = RecordAccess.write(user_id, entity_type, prefix)` computed FIRST, before the body, path id or query string is read. All four
   reads happen here, unconditionally, so the database work up to this point is identical for denied, absent, managed and open types.
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
   statements: the gate's four reads, the same step-4 code, then the substitution. The residual difference of an absent type in the old code
   (one extra definition read inside `Records`) disappears because neither calls `Records`.

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

Timing: denied and absent run the same statements (point 6). The visible-type path adds the four gate reads to today's work (cost in section 9),
which is not a denied-vs-absent signal.

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
| PUT replace | `MapSet.size(restricted) > 0`, whatever the body (decided before any record lookup) | the same 403 |
| DELETE | none | n/a |
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

DELETE: no field check. Delete is a record-lifecycle operation, not a field write: it is soft (`delete_record` appends `ENTITY_RECORD_DELETED`,
sets `deleted: true`, keeps `field_values` unchanged), it neither reads nor sets a restricted value, and its response is `record_map` of the
caller's own redactable view. Requiring field grants would make records of any partly-restricted type undeletable by ordinary operators without a
confidentiality gain. The type gate (section 3) still applies. Flagged for SECURITY-REVIEWER ruling (OQ-2).

The order of the restricted-field refusal against body validation, for a visible type: validation errors (400/422) first, then the refusal, then
`Records` (a restricted-key body that is also malformed is the validation error, which depends only on the body). Against the key-claim window:
the refusal precedes `put_legacy_original`'s result being used; the read itself still runs (no behaviour difference visible to anyone).

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
- Content GET: `:hidden` -> the handler still performs `EntityAttachments.get_content/2` (same statements), then discards its result and
  answers `{:error, :not_found}` -> 404. This also folds `:content_missing` (500) and `:not_available` (409) into 404, which is what an absent
  type with that attachment id gives (no such attachment row under that type).
- Delete: `:hidden` -> `fetch_scoped_record_attachment_metadata` still runs, its result is discarded, `EntityAttachments.delete/2` is NOT called,
  answer 404.
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
- `web/src/api/entities.ts` (:61-90) is the only SPA caller (`EntityCrudPage.tsx`): a user with a restricted field on a type now gets 403 on
  edit (PUT) and on create when the form submits a restricted key; before it silently wrote the sentinel/erased the value. A user type-denied
  cannot navigate to the type at all. No `web/` change is required for correctness; a friendlier 403 message is a FRONTEND follow-up (OQ-9).
- BREAKING for `scripts/seed_vortex_entities.sh`: step 2 restricts `shipment_manifest` (type, no grant for the seeder) and
  `production_batch.cost_figure` (grant only for Anna); step 3 then imports as the admin token. After this change step 3 gets 404 for
  `shipment_manifest` (`curl -sf` exits non-zero) and a 200 with per-entry `field_restricted` for `production_batch` rows carrying `cost_figure`
  (silent partial seed). Fix in PR A: the script resolves the seeding actor with its existing `lookup_user_id` (a new required
  `SEED_ACTOR_USERNAME`) and adds that user to the `type_grants` / `field_grants` of the same restrictions import; it also fails loudly on any
  `status: "error"` entry (today it ignores the response body). `test/scripts/seed_vortex_entities_activate_test.exs` and
  `test/letflow/scripts/seed_scripts_no_argv_payload_test.exs` are the existing tests around it; the implementer greps for others. (As a side
  note, since #2700 the script's `existing_keys_for` pre-check on `shipment_manifest` already returns empty for a denied seeder, so its
  idempotency was already broken; the grant repairs that too.) Needs supervisor acknowledgement because it touches a UAT seed (OQ-4).
- Existing tests that restrict a type/field and then write records through HTTP (to be re-grepped by the implementer): `entities_test.exs` (insert_field_restriction! at :1479-:2066,
  insert_type_restriction! at :2691-:2904 use `Records` or the read routes for their writes per my read, to be re-grepped), 
  `entities_answer_key_field_leak_test.exs`, `bilimbaga_solution_e2e_test.exs`, the REQ-317 attachment route tests (no restrictions
  present, unaffected). Any that write a denied type or a restricted key via HTTP are updated to the new answer in PR A, not weakened.
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
5. no side effects on a denied request, by counting rows before and after: `events`, `entity_record_latest` (and any promoted-column table the
   type has), event-store idempotency keys, `entity_record_attachments`, `repository_artifacts`, audit log rows; all equal; also assert no
   warning/error log line (`capture_log`) except the infected-upload warning, which is asserted equal to the absent case;
6. query-count parity: a telemetry counter on `Repo` queries shows denied and absent execute the same number of statements per route;
7. an allowed caller (no restriction rows in the tenant, and with unrelated restriction rows) is unchanged: status and body equal to the
   pre-change golden for create/update/delete/import/attachments;
8. field restrictions on an open type (actor holds none of the grants): POST naming a restricted key -> 403 with the constant detail and no event;
   POST naming only unrestricted keys -> 201; PUT with any restricted field on the type -> 403 whatever the body and whether the record exists
   (no 404/403 difference between a live and a random record id); PUT for an actor WITH the grant -> 200 and the full replacement; DELETE by a
   restricted-field actor -> 200/204 as today; import create with one entry naming a restricted key -> that entry `field_restricted`, others
   created, HTTP 200, the refused entry wrote nothing; a granted actor -> all created;
9. precedence: denied AND restricted-key body -> 404 path (not 403); allowed + restricted key + malformed body -> the validation error;
10. upsert refactor regression: the full existing `entities_import_upsert_test.exs` suite stays green; the "one schema-version read per request"
    test still passes; add: a denied type with `upsert_by` and a tenant below CREATED v2 is 404, not 503 (hidden beats outdated).

## 11. Route inventory and snapshot (decision (9))

No route is added, removed or renamed; no policy key changes (the same nine `authz_*` lines at :311-:432). So
`test/fixtures/route_scope/tenant_wide_default_routes.txt` (e.g. lines 3, 4, 23, 24, 85-88, 135) and `test/support/route_inventory.ex` need NO
change, and the route-snapshot test must stay green untouched; if it goes red the change is wrong. `lib/letflow/routers/entities.ex` is a
SECURITY-REVIEWER mandatory-trigger file (tenant data path, authorization; `authorized_router`/route-scope triggers are not hit because nothing
about route scope changes).

## 12. PR split (decision (9))

Mandatory gates on each: SECURITY-REVIEWER (hard gate; authorization on a tenant data path), REVIEWER, scoped tests one file at a time, compile
with warnings as errors, full-repo format check read by exit code. Neither PR holds a migration or an event-schema change. The repo rule is
"one PR per issue"; two PRs are proposed because the second is independent and the first is already large (OQ-7). Both link #2784.

- PR A, ~450-600 changed lines plus tests: `RecordAccess` (+ unit tests), the four record handlers, `ImportUpsert.precheck/2` refactor and
  `names_restricted?` adoption, router moduledoc and inheritance-rule rewrite, the shared 403 detail attribute, the seed script fix, test
  updates. Closes AC 1, the type and field halves of AC 2 and 3 for routes 1-4.
- PR B, ~150-250 changed lines plus tests: `RecordAccess.attachment/3` and the four attachment handlers (substitution), the attachment test
  file. Closes AC 2 and 3 for routes 5-8. Depends on A only for the module; can be written in parallel on top of it.
- Both: DOC-UPDATER notes in the router moduledoc table and `authorization.ex` moduledoc (the Write/Import/Attachments grants now also
  require type access, one sentence each).

## 13. Risks

R1 (SEC) substitution-based denial couples correctness to "the stub returns exactly what `Records` returns for an absent type"; mitigated by
tests 1-4 running every route against both a denied and an absent type and by `hidden_result/1` being the single definition. R2 PUT is stricter
than before for restricted-field actors (a behaviour break by intent, OQ-1). R3 the seed script and any UAT/QA flow that writes restricted
types as an admin (OQ-4). R4 four extra reads per write request. R5 a half-installed managed type changes 403 -> 404 (OQ-6). R6 the
non-transactional gate/write window (section 8). R7 engine step writes and module handlers also lack TypeAccess (OQ-3), so a type-denied actor
who can start a process whose step writes that type still writes it: out of scope here, to be filed.

## 14. Open questions for the supervisor

- OQ-1: PUT blanket 403 for any actor with a restricted field on the type (chosen) versus preserving unseen restricted values by merge
  semantics (changes `update_record` and replay). Needs a ruling; the chosen option is the conservative one and matches the upsert rule.
- OQ-2: DELETE without a field check, and DELETE of a record whose restricted fields the actor cannot see: confirm (SECURITY-REVIEWER).
- OQ-3: should the definition write routes (`POST /definitions`, `/definitions/:name/activate`) and the engine step-write / module-handler
  paths apply TypeAccess too (a type-denied actor with `EntitiesDefinitionsWrite` can create or activate a version of a type they cannot
  read; a 409/200 difference may be an existence oracle)? Proposal: file one follow-up issue; not in this PR.
- OQ-4: the seed script change (new required `SEED_ACTOR_USERNAME`, grants for the seeder) touches a QA/UAT seed; confirm, or choose instead to
  seed records before restrictions (cannot be re-run safely).
- OQ-5: confirm list and content-GET attachment routes are in scope (issue names them; they are reads and #2700 left them out).
- OQ-6: precedence hidden > managed (a managed type with no active definition becomes 404 for allowed callers). Accept?
- OQ-7: two PRs under one issue versus one large PR (repo rule is one PR per issue).
- OQ-8: the 403 for a restricted key reuses the #2697 constant detail text (chosen) instead of a new `Error` constructor or a 422; confirm.
- OQ-9: FRONTEND follow-up for a friendly message on the new 403 (non-blocking).
