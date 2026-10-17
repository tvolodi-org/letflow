# GH #2659 / REQ-505 - master external_ref {system, id} and the idempotent upsert-by-external-id import

Status: design (CODE-DESIGNER). Base: origin/main 21c9b40b. Build owner: ELIXIR-DEV (backend only; no `web/` change).
No implementation code below: names, shapes, step orders, tests. Method: code read with grep/git, NO `mix` run (host
memory-starved). Citations are `path:line` on this base. The issue text itself could not be fetched (`gh issue view 2659
--comments` returned empty); the acceptance criteria below are the eight the supervisor listed in the task, which this
design treats as the issue's AC list (AC1..AC8, section 8). Anchors in the issue that were read on an older main are
re-derived here.

Sources: decision 0057 D1 (`docs/migration/decisions/0057-wms-customer-draft-reconciliation.md:13` "Masters come in by a
one-time idempotent import (`EntitiesRecordsImport`, upsert by external id). Every master has a nullable `external_ref`
`{system, id}` from day one."), D12 (`:56`, seed through the generic idempotent import REQ-505); WMS draft IN-01 (`:106`),
IN-06 (`:111`: "cross-reference IDs ... reject ambiguous mappings"), MD-01 (`:60`); decision 0060 (decimal_strict, merged
#2654); decision 0061 (global lock order); GH #2543 (idempotency key binding).

## 1. Core vs module: decision

**Core.** The primitive lives in `Letflow.Entities.Records` (a new function) plus two nullable columns on the per-tenant
`entity_record_latest`, and the HTTP surface is an optional `upsert_by` on the existing generic import route. Reasons:

1. The route is generic and tenant-facing (`lib/letflow/routers/entities.ex:71`, `:331`); D12 names "the generic idempotent
   import" as the seed path, so the behaviour must be reachable without a module.
2. The only race arbiter that does not need a new lock class is a unique index on the projection row, which only core can add.
3. A module cannot own it: a module-owned (`managed_by`) type is refused on every tenant write route with a constant 403
   (`guard_tenant_write`, `entities.ex:2899-2906`, via `ManagedTypes.check_tenant_write/2`, `managed_types.ex:248-256`),
   so the HTTP import cannot reach a managed type at all. If the WMS masters end up module-managed, the module's own write
   handler (REQ-501 mechanism) calls the SAME core primitive with its `Owner` authority (the same `authority` argument
   `create_record/3` already takes, `records.ex:325-332`). One implementation, two callers; the module never re-implements
   the lookup or the index. Whether the WMS masters are managed or tenant types is an open question (OQ-1); this design is
   correct for both.

Rejected: a module-side importer only (duplicates the race logic, and the tenant `EntitiesRecordsImport` seed path of D12
would not exist); a new route (a second permission surface for the same action).

## 2. The external_ref convention

Decision: **two nullable columns on `entity_record_latest` plus one partial unique index; the value is carried in the event
payload (top-level key `"external_ref"`), NOT inside `field_values`.**

| Option | Verdict |
|---|---|
| Nested object in `field_values` | Rejected. `Record.Validator` is closed (`additionalProperties: false`, `record/validator.ex:58,77`), so every master definition would have to declare a `:json` field; a nested value cannot carry a unique constraint (definition `constraints` compile to a UNIQUE on promoted columns of the per-type table only, `records.ex:1070-1099`); and a `:json` field cannot be `queried` (`definition.ex:117`). It would also leak into every query/export `field_values`. |
| Dedicated unique index on a promoted column | Rejected. Promotion is per type and opt-in (`records.ex:966-973`); the index must exist for every type from day one ("from day one", 0057 D1). |
| Columns on `entity_record_latest` + partial unique index | **Chosen.** One index, all types, tenant-scoped by the schema prefix, arbitrates concurrent inserts regardless of promotion. |

### 2.1 Schema (one tenant-scoped migration)

`entity_record_latest` (`priv/repo/migrations/20260906010001_create_entity_record_latest.exs`, schema
`record/latest.ex:21-33`) gains:

| Column | Type | Null | Note |
|---|---|---|---|
| `external_system` | `varchar(64)` | yes | |
| `external_id` | `varchar(255)` | yes | |

Constraints:
* `CHECK ((external_system IS NULL) = (external_id IS NULL))` - both or neither (name `entity_record_latest_external_ref_pair_chk`).
* Partial unique index `entity_record_latest_external_ref_idx` on `(entity_type, external_system, external_id)` `WHERE external_id IS NOT NULL`.
  No `deleted` predicate: a soft-deleted record keeps its reference (section 4.4). Two systems with the same id differ in
  `external_system`, so they do not collide; two types with the same pair do not collide (type is in the key).
* No backfill: every existing row is NULL/NULL. The index is partial, so existing rows cost nothing.

Registration: the migration follows the `if prefix()` pattern and MUST be appended to `@tenant_scoped_migration_manifest`
(`lib/letflow/tenant_provisioning.ex:506`; contract note at `:770-772`) so new AND existing tenants receive it (this is how
every prior tenant-schema change reached existing tenants). Latest version in the tree is
`20261018100002_add_admin_flagged_service_principal_to_users.exs`; the new file takes the next free timestamp at build time.
Tenant isolation: the tenant schema prefix is the isolation boundary, as for every table here; no `tenant_id` column.

### 2.2 Ecto schema

`Letflow.Entities.Record.Latest` (`record/latest.ex`): add `field :external_system, :string` and `field :external_id,
:string`. The insert changeset (`@insert_fields`, `latest.ex:39-45`) casts them as optional (not in `validate_required`);
`unique_constraint` on the new index name maps a violation to a changeset error with `constraint_name` `entity_record_latest_external_ref_idx`
(the existing `sequence_conflict?/1` pattern at `records.ex:1392-1397` shows how a named unique constraint is recognised).
The update changeset (`@update_fields`, `:48`) does NOT cast them: the reference is immutable once set (identity, like
`entity_type`/`record_id`, `latest.ex:70-73`).

### 2.3 Value rules (validated once, in a pure function)

`Letflow.Entities.ExternalRef` (new small module): `parse(term) :: {:ok, %{system: String.t(), id: String.t()}} | {:error, reason}`.
* Shape: exactly the object keys `"system"` and `"id"`, both strings; unknown keys, non-object, or either missing -> error.
* `system`: 1..64 bytes, `[a-z0-9][a-z0-9._-]*` (a short slug such as `1c`, `sap`, `wms-seed`). Lower-case only; no case folding is applied (a
  mixed-case system is rejected, not normalised, so two spellings can never be distinct yet "equal").
* `id`: 1..255 bytes, valid UTF-8, no NUL, not all whitespace. Compared byte-exact (no trim, no case fold). Numeric
  source ids are passed as strings.
* Reasons (atoms, all constant on the wire): `:external_ref_invalid`.

### 2.4 Event payload and projection

* `ENTITY_RECORD_CREATED` and `ENTITY_RECORD_UPDATED` payloads (`build_event_attrs/3`, `records.ex:837-850`) gain an optional
  top-level `"external_ref" => %{"system" => _, "id" => _}` ONLY when a ref is supplied. Payloads without it are byte-identical to today
  (backward compatible; existing events replay unchanged).
* `Record.Projector.apply_event/3` (`record/projector.ex:454-512`) is extended: CREATED sets the two columns from the payload key when present;
  UPDATED/DELETED carry the columns forward unchanged (never clear). So a rebuild reproduces the live projection (REQ-229 equivalence
  test is extended, section 8).
* The per-type promoted table dual-write (`records.ex:966-1045`) does not carry the ref (no change).
* `Latest` reads: `record_map/2` (`entities.ex:2859-2870`) adds `"external_ref"` only when non-nil; `entity_row_map/2`
  (`entities.ex:2824-2833`, query/export rows) is NOT changed in this requirement (OQ-3: filter/export by ref). With a nil ref the
  response keys are byte-identical to today.

## 3. Public signatures (design only)

New, in `Letflow.Entities.Records`:

* `upsert_record_by_external_ref(attrs :: upsert_attrs(), prefix :: String.t()) :: {:ok, upsert_result()} | upsert_error()` and the `/3` arity with `authority :: ManagedTypes.owner()` (the `/2` is `:tenant`, mirroring `records.ex:320-332`).
* `upsert_attrs`: `%{entity_type: String.t(), external_ref: %{system: String.t(), id: String.t()}, field_values: map(), actor_id: UUID, idempotency_key: String.t()}`. Same reserved-attribute and `sys:step:` refusals as the other commands (`reject_reserved_attributes/1`, `reject_step_key/1`, `records.ex:414-415`).
* `upsert_result`: `%{record: Latest.t(), outcome: :created | :updated | :unchanged, is_duplicate: boolean()}`.
* `upsert_error` adds to `command_error()`: `{:error, :external_ref_invalid}`, `{:error, {:external_ref_record_deleted, ref}}` (ref echoed is the caller's own, constant shape), `{:error, :external_ref_contention}`; all existing reasons (`{:definition_not_found, t}`, `{:record_payload_invalid, v}`, `:entity_type_managed`, `{:definition_changed, t}`, `:idempotency_key_reuse`, `{:entity_append_only, t}`) pass through.

New read helper in `Latest`: `get_by_external_ref(entity_type, system, id, prefix) :: {:ok, t()} | {:error, :not_found} | {:error, :invalid_schema_name}` - returns deleted rows too (like `get/3`, `latest.ex:84-98`); never raises.

Existing `create_record/2,3`, `update_record/2,3`, `delete_record/2,3` signatures and behaviour are unchanged except that `create_record` and `update_record` accept an optional `external_ref` in `attrs` (internal key; never set by the existing router paths, so they behave identically). `create_attrs()`/`update_attrs()` types gain `optional(:external_ref)`.

## 4. Upsert semantics

### 4.1 Algorithm (bounded optimistic loop, at most 3 attempts)

1. Validate (no query): `ExternalRef.parse/1`; reserved attrs; step-key.
2. Resolve the active definition and ownership exactly as the other commands (`fetch_active_definition`, `check_write_authority`, `validate_field_values`, `records.ex:337-339`). `validate_field_values` returns the NORMALISED values (strict decimals as canonical strings, `records.ex:1468-1474`; #2654 is merged), so the compare in step 4 uses normalised values and `decimal_strict` fields behave as on `create_record`. An `append_only` type (`ensure_mutable`, `records.ex:1451`) can take the CREATE path but returns `{:entity_append_only, t}` on the update path - an import of an existing ref into an append-only type is a per-entry error, never a silent skip.
3. `Latest.get_by_external_ref/4`.
4. Branch:
   * **Absent** -> create path: `create_record` with the ref (INSERT carries the two columns in the same Multi, `records.ex:870-880`). Outcome `:created`.
   * **Present and `deleted`** -> `{:error, {:external_ref_record_deleted, ref}}`; nothing appended (no resurrection: `update_record` itself refuses deleted records, `records.ex:420`, `ensure_not_deleted` `:1459`).
   * **Present, live, normalised `field_values` JSON-equal to the stored ones** -> `:unchanged`: no event, no write, no version bump. The compare reuses `json_equal?/2` (`records.ex:1329-1356`). This makes an unchanged re-import produce zero events.
   * **Present, live, different** -> update path: `update_record` (full replacement, `records.ex:406-437`) with `expected_last_event_global_seq` = the `last_event_global_seq` just read. Outcome `:updated`. The ref columns are unchanged (not castable, 2.2).
5. Failure handling inside the loop: a create-path unique violation on `entity_record_latest_external_ref_idx` (a concurrent import won the insert) or an update-path `:record_version_conflict` (`records.ex:949-956`) re-runs from step 3 (a lost-race create now finds the winner and becomes update/unchanged). After 3 attempts -> `{:error, :external_ref_contention}`. Both failures roll back their whole transaction (event, idempotency claim, projection), so a retry leaves no trace (`records.ex:829-830`, idempotency claim rolled back inside the same Multi).

### 4.2 Race arbiter and lock order (decision 0061)

* The arbiter is the partial unique index (inserts) plus the existing `check_record_version` row lock `FOR UPDATE` (`records.ex:949-956`) (updates). Both already sit AFTER the type's sequence-row lock taken by `EventStore.append_multi` steps (`event_store.ex:694-726`, comment at `records.ex:814`).
* The upsert introduces NO new lock and no new lock class, and never holds locks across attempts (each attempt is one existing single-type command transaction). It therefore takes only class 5 of decision 0061 (one entity type row) and cannot invert the global order (`0061` rule 1, items 5/8; rule 5 "new code that takes more than one row class" does not apply because it takes one). No amendment of 0061 is needed.
* Rejected: a pessimistic variant (`lock_instance_sequence/3`, `event_store.ex:737-746`, then lookup then compose) - it works but forces the lookup into a long-held outer transaction and needs the Multi composed inside it; not needed because the index already arbitrates. Kept as the fallback if the build finds the retry loop observable under load.
* Why the lookup outside the lock is safe: step 3's result is only a hint; the write step re-validates it under the lock (index for create, version check for update).

### 4.3 Events and versions

* Create: one `ENTITY_RECORD_CREATED` (payload carries `"external_ref"`). Update: one `ENTITY_RECORD_UPDATED` (payload also carries the ref for audit readability; refs are only ever set on CREATED, so the projector ignores it on UPDATED). Unchanged: no event.
* `entity_def_version` is the active definition's `logical_shape_version` at write time, as today (`records.ex:852-858`). `last_event_global_seq` is the version token.
* No client-supplied optimistic version in the import (OQ-4): the version read in step 3 is internal.

### 4.4 Soft-deleted records

A ref stays bound to its record after deletion (the index has no `deleted` predicate), so a later import of the same ref can neither create a second record nor revive the old one: it reports `external_ref_record_deleted` for that entry. The operator must decide (OQ-2). This keeps "one record per external id" true forever.

### 4.5 What an upsert may overwrite

Full replacement of `field_values`, as `update_record` (`records.ex:359-367`): fields omitted from the entry are removed (whole-document, not merge). Not overwritten: the ref, `record_id`, `entity_type`, `deleted`. Required-field, enum, bound and strict-decimal validation run unchanged (`validate_field_values`). Field grants/restrictions: today NO write path consults `FieldPolicy`/`FieldGrants` (grep: `field_policy.ex` is read/request-side only; `records.ex` does not reference it), so the import actor can write any field of a type it can reach, exactly as `POST`/`PUT` do. The upsert does not add a write-side field check; the update branch makes this matter more than create-only import did (section 7, OQ-5).

### 4.6 Audit

Every created/updated record has its event with `actor_id` = the authenticated user (`entities.ex:1234`, INV-1), in the event log. No separate audit-chain write; the "unchanged" outcome intentionally leaves no event. The per-entry result carries `outcome` so the importing operator has the record of what happened.

## 5. HTTP: `POST /entities/records/:entity_type/import`

### 5.1 Request

Additive optional members only; the existing gates and their order are untouched (cap -> schema-version -> entity_type match,
`entities.ex:1214-1225`, `:1237-1239`).

* Top level: `"upsert_by"` - absent (default) or the literal string `"external_ref"`; any other value -> 422 before any write (new check, placed after the entity_type match so ordering of existing errors is unchanged; checked by a new `check_upsert_by/1`).
* Per entry: `"external_ref": {"system", "id"}`. When `upsert_by` is present, every entry needs a valid one; a missing/invalid ref is a per-entry error `external_ref_invalid`, the rest proceed.
* `record_id` on an entry stays echo-only (`entities.ex:1348-1350`): NEVER addresses a record, in either mode.
* Without `upsert_by` the whole handler path is the code at `entities.ex:1361-1380` unchanged, and an entry's `external_ref` key is ignored like any other unknown entry key today (byte-identical; OQ-6 asks whether to instead create-with-ref). 

### 5.2 Handler flow with `upsert_by`

`import_one_entry` gains a clause chosen by the presence of `upsert_by`; `run_import` (`entities.ex:1329-1346`) keeps its shape (first entry inspected only for the definition_not_found -> 404 fold, then sequential per-entry). Before the loop, a pre-scan marks every entry whose `(system, id)` equals an EARLIER entry's: it is answered `duplicate_external_ref_in_request` (not written, regardless of equality). The first occurrence proceeds. This replaces the #2543 within-call dedup of same-`record_id` entries for upsert mode (the dedup key is the ref, not the source `record_id`).

Per entry the handler calls `Records.upsert_record_by_external_ref/2` (tenant-owned types only; the guard at `entities.ex:1229` still returns the constant 403 for managed types before the body is read).

### 5.3 Idempotency key (#2543) for upsert mode

* Server-derived, never client-supplied (the route has no `idempotency_key` member, and `Idempotency` stays the only reader of client keys, `idempotency.ex:23-24`). Key = `"entities-record-import:" <> import_request_id <> ":ext:" <> lower-hex SHA-256 of (system <> 0x00 <> id)` (<= 128 bytes; a raw id of up to 255 bytes could overflow `varchar(255)` if embedded). `import_request_id` is minted per HTTP call as today (`entities.ex:1240`).
* Consequence: two separate calls never share a key, so the idempotency key is NOT what makes re-import idempotent - the external ref is. A byte-identical re-POST finds every record by ref and answers `unchanged` with zero events (AC1).
* Within one call a ref appears once (pre-scan), so the key is never reused with a different request; `:idempotency_key_reuse` cannot arise from a ref collision. A retried attempt (4.1 step 5) reuses the same key; the rolled-back transaction released the claim. If the caller-visible reason `idempotency_key_reuse` (`entities.ex:1425`) ever appears in upsert mode it is a defect, not a user error.
* Without `upsert_by`: today's derivation (`entities.ex:1384-1390`) is untouched.

### 5.4 Partial failure and cap

**Per-entry report, not whole-file rollback; cap stays 200 (`@import_record_cap`, `entities.ex:1284`), 413 above it.** Rationale: (a) it is today's contract, `create_record` "commits its own transaction per call" and is "never composed into an outer Multi" (`entities.ex:1322-1324`); (b) whole-file rollback would hold the type's sequence row and index for up to 200 writes, extending the lock hold that decision 0061 is shrinking, and it would change the response contract; (c) idempotency by ref makes a re-run of a partially failed file safe and convergent - that, not atomicity, is the recovery path. Larger seed sets are sent as several <= 200 requests. A file containing one bad entry still writes all good ones; the response lists each.

### 5.5 Response and schema version

* Status/shape unchanged: 200 `{"results": [...]}` (`entities.ex:1244`). Entry statuses `ok` / `error` unchanged. In upsert mode an `ok` entry additionally carries `"outcome": "created" | "updated" | "unchanged"` and `"external_ref": {system, id}`; an `error` entry's `reason` gains the types `external_ref_invalid`, `external_ref_record_deleted`, `external_ref_contention`, `duplicate_external_ref_in_request`, `entity_append_only` (constant, no detail; mapped in `import_reason_json/1`, `entities.ex:1411-1449`). Without `upsert_by` the response is byte-identical.
* `record_export_schema_version` is NOT bumped: it is an exact-match gate on `"entities/record-export/v1"` (`entities.ex:1226`, `:1305-1310`) shared with the export document; the change is additive request members, and a v1 document without them behaves as before. A bump would reject every existing export/import round trip for no gain. (If the supervisor prefers an explicit marker, a distinct `upsert_by` presence is already the marker.)
* Export is unchanged in this requirement (OQ-3), so an export-then-import round trip is byte-for-byte as today.

## 6. Compatibility, existing tenants, exam module

* No `upsert_by`: import request handling, derived keys, results are byte-identical (regression test, section 8).
* Existing tenants: the migration adds two NULL columns and a partial index over zero rows; online-safe, no backfill, picked up through the manifest (2.1). Rollback of the code leaves the nullable columns harmless.
* Exam module (`lib/letflow/modules/exam/*`, managed types written with `Owner` authority and `idempotency_match: :target`, `records.ex:84-87`): untouched; it never passes `external_ref`. `entity_record_latest` readers that select explicit columns are unaffected; code that builds `%Latest{}` structs (`duplicate_result/1`, `records.ex:1376-1390`) leaves the new fields nil, which is correct (a duplicate replay of a ref-less create).
* Replay/rebuild: extended as in 2.4; event payload `"external_ref"` is additive.

## 7. Permissions and SECURITY-REVIEWER scope

* Route-level gate unchanged: `:EntitiesRecordsImport` (`authorization.ex:1036`, `:1372`), tenant resolved from the request (`prefix!/1`), actor from `auth_context` (INV-1), managed types refused by `guard_tenant_write`.
* New exposure: `EntitiesRecordsImport` is documented as a separate grant from `EntitiesRecordsWrite` and deliberately riskier (`authorization.ex:117-124`), but it has been create-only. The upsert UPDATE branch lets an Import-only holder overwrite existing records, which previously needed `EntitiesRecordsWrite` (`PUT`, `authorization.ex:999-1005`). Recommendation (OQ-5, needs the supervisor): when `upsert_by` is present, ALSO require `:EntitiesRecordsWrite` in-handler via `Letflow.Api.Authorization.evaluate_access/2` (the export-unredacted pattern, `entities.ex:2444`), 403 for the whole request before any write. No new permission atom. If the supervisor rules "Import alone suffices", record it in the PR.
* SECURITY-REVIEWER triggers: migration on a tenant data table; new unique index across the tenant's types; tenant-data write path with a new update branch; response shaping (`record_map`, import results); cross-tenant behaviour of the lookup (it is `prefix`-scoped, INV-1/INV-5: the lookup runs only in the caller's schema, so a ref from another tenant is simply absent). INV-5 folding: `external_ref_record_deleted` reveals only that the caller's OWN tenant has a deleted record with that ref.
* INV-7/8: no SQL string built from data (Ecto only; the index/columns are migration literals); no user data in logs; the `import_reason_json` catch-all stays for anything unmapped.

## 8. Test plan (reproduce-first where a baseline exists)

Reproduce-first: on the base, a failing test shows (a) importing the same two-entry file twice yields four records (the defect the requirement exists to fix; asserted on the unchanged route first). Then each AC:

| AC | Test (ExUnit, real Postgres, tenant schema, no mocks) |
|---|---|
| AC1 import twice -> one record per external id | Import file of N refs twice with `upsert_by`; second response all `unchanged`; `entity_record_latest` count == N; event count unchanged after the second call. Variant: second file changes a field -> `updated`, still N rows, one new UPDATED event each. |
| AC2 record without external_ref accepted | (a) `upsert_by` absent, entry without ref: created exactly as today. (b) `POST` single create and `PUT` unaffected, response has no `external_ref` key. (c) mixed file in upsert mode: entry without ref -> per-entry `external_ref_invalid`, others written. |
| AC3 two systems, same id | Refs `{1c,"42"}` and `{sap,"42"}` both created as two records; re-import updates each independently; same pair in two entity types also both created. |
| AC4 partial failure | File of 5 with 2 invalid (bad enum; missing ref): HTTP 200, 3 `ok` + 2 `error` with reasons, 3 records exist; re-posting the corrected file converges (idempotent). 201 entries -> 413 with nothing written. First entry `definition_not_found` -> 404. Duplicate ref within the file -> second entry `duplicate_external_ref_in_request`, nothing for it written. Deleted ref -> `external_ref_record_deleted`, no event. Append-only type, existing ref -> `entity_append_only`. |
| AC5 two concurrent imports -> one record | Two processes import the same ref set in parallel behind a start barrier (bounded, <= 4 workers per the machine limits); assert exactly one row per ref, both responses all `ok` (one `created`, one `updated`/`unchanged`), no 5xx. Forced-overlap variant: hold the type sequence row from a third connection, queue two creates, release, assert one wins by the index and the other converges (and report deadlock/lock-timeout through the Repo telemetry event, per 0061 rule 5, so a retry cannot hide one). Direct index test: two raw inserts with the same triple -> unique violation; same system/id different type -> both succeed; the pair check constraint rejects `(NULL,'x')`. |
| AC6 same external_ref in two tenants | Two tenants, same `(type, system, id)` -> two records, one per schema; tenant A's import never changes tenant B's row; a lookup under A's prefix cannot see B's. |
| AC7 idempotency-key interaction (#2543) | (a) Second byte-identical POST: different derived keys, still `unchanged` (the ref, not the key, dedupes). (b) Derived key length for a 255-byte id is <= 255 and accepted. (c) Within one call two entries same ref different values -> `duplicate_external_ref_in_request`, never `idempotency_key_reuse`. (d) Without `upsert_by`: the existing #2543 tests (same `record_id`, same/different values) pass unchanged. (e) A forced contention retry on the same key does not trip `idempotency_key_reuse`. |
| AC8 backward compatibility / no upsert_by | Golden-file comparison of the response and events of an existing import test against a pre-change recording (byte-identical); managed type -> constant 403 with and without `upsert_by`; entry `external_ref` ignored without `upsert_by`. |
| Replay | Extend the REQ-229 live-vs-rebuilt equivalence test with ref-carrying records: `rebuild_projection` reproduces both columns; a record updated twice keeps its ref; a deleted record keeps it. |
| Decimals | Strict-decimal field: `"12.5"` normalises to the scale-padded string; re-import of `"12.50"` is `unchanged` (compare after normalisation). |
| Permission | Import-only caller, `upsert_by` set (if OQ-5 ruling is "also Write") -> 403, nothing written; Import+Write -> allowed; no `upsert_by` -> Import alone works as today. |
| Ref validation | Unit tests for `ExternalRef.parse/1` (case, length, NUL, unknown keys, non-string id). |
| Migration | Tenant provisioning test: a fresh tenant and an upgraded existing tenant both have the columns, check constraint and index (manifest entry present). |

## 9. PR split, risks, open questions

### PR split

| PR | Content | Size |
|---|---|---|
| PR-1 | Migration + manifest entry + `Latest` fields/changesets + `Latest.get_by_external_ref/4` + `ExternalRef` + payload key + `Projector` carry + `record_map` conditional key + projector/index/tenant-provisioning tests | M (about 400 lines incl. tests) |
| PR-2 | `Records.upsert_record_by_external_ref/2,3` (loop, outcomes, errors) + unit/concurrency tests (AC3,5,6 at the domain level) | M |
| PR-3 | Router: `upsert_by`, per-entry flow, pre-scan, derived key, results/reasons, permission check per OQ-5, moduledoc table row, HTTP tests (AC1,2,4,7,8) + docs (`docs/` API reference entry) | M |

PR-1 and PR-2 can merge independently (no behaviour change until PR-3). Each PR needs a RELEASE-VALIDATOR re-run of its ACs; PR-1 and PR-3 go through SECURITY-REVIEWER.

### Risks

* Optimistic loop vs heavy contention: bounded at 3, then a per-entry `external_ref_contention` with a safe retry. Fallback: the pessimistic variant in 4.2.
* A tenant-schema migration on a hot table: partial index over zero rows, nullable columns; low.
* "Unchanged" skips events: audit shows nothing for an unchanged re-import; deliberate, reported in the result.
* Update branch widens what Import can do (7): mitigated by OQ-5.
* Orphan drift if a future code path writes `entity_record_latest` without the ref: the projector and the three command paths are the only writers (the grep of writers: `records.ex`, `record/projector.ex`); the replay-equivalence test guards it.

### Open questions for the supervisor

* OQ-1: are the WMS masters tenant-owned types (HTTP import reaches them) or module-managed (only the module handler can, via the same primitive)? Design supports both; it changes only which caller seeds data.
* OQ-2: soft-deleted ref on re-import - refuse per entry (this design) or revive? Reviving needs a new "undelete" event type, out of scope.
* OQ-3: expose `external_ref` in query/export rows and as a filter (needed by IN-06 reconciliation, MD-01 exception queue)? Not in this requirement; separate follow-up.
* OQ-4: accept a client `expected_last_event_global_seq` per entry (stale-file protection)? Not in this design.
* OQ-5: require `:EntitiesRecordsWrite` in addition to `:EntitiesRecordsImport` when `upsert_by` is present (recommended), or accept Import alone?
* OQ-6: without `upsert_by`, an entry's `external_ref` is ignored (byte-identical). Alternative: create-with-ref and no lookup. Which is wanted for the seed path (D12 sets `upsert_by`, so low impact)?
* OQ-7: should single `POST`/`PUT` accept `external_ref` (so the UI can set it)? Not in scope; the primitive already supports it.
* OQ-8: the issue text could not be fetched in this session; confirm the eight ACs in the task match the issue's list.
