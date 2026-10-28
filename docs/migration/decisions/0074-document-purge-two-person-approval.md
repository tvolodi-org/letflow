# 0074 -- Versioned documents, slice 2 part 2: purge execution with two-person approval, shared bytes, trigger exception; archive dropped (amends 0056 D7, D9)

Status: PROPOSED by the designer of GH #2677 (task T-0856, REQ-509), 2026-10-28. Not yet ratified:
the record binds only after the owner or REVIEWER signs it (see Sign-off). REQ-603 (GH #3389) is
not claimed before that. (Number 0074: 0073 is reserved by T-0834; highest on origin/main is 0072.)

Amends: [0056](0056-versioned-documents.md) D7 (the purge direction becomes BINDING for REQ-603),
D9 (three reserved event names become BINDING with payloads). Consumes:
[0063](0063-versioned-documents-retention-and-hold.md) S1, S5, S6 (eligibility, hold, lock order).
Settles inputs of: [0057](0057-wms-customer-draft-reconciliation.md) D15 and D19.
Everything else in 0056 and 0063 is unchanged. This record writes no code, seed, migration or test.

## Context

Sources, cited by section:

- 0056 D7: the direction for `purge_requests`, `DocumentsPurge`, two-principal separation in the
  database, the guarded session setting `letflow.purge_request_id`, the shared byte store (threat
  T16) and the stated residual. D7 is DIRECTION; this record makes it binding.
- 0057 D15: retention is FOREVER by default, action `keep | archive | purge`, "purge only through
  an approval task", a legal hold overrides and blocks any purge, every purge writes an audit event.
- 0057 D19: an offboarded tenant is frozen read-only, gets a complete export, and its documents are
  purged "only on explicit written request and only after retention allows (default: never)".
- 0063 S5: the hold columns, the `SELECT ... FOR UPDATE` on the `documents` row before `on_hold` is
  read, and the lock order (`documents` row after entity-type rows, before the audit chain row).
- 0063 S6: the eligibility predicate (`superseded` and `cancelled` only, hold excludes, period
  elapsed, fail-safe on an unknown closing time). 0063 S1 gives the closing time. 0063
  "Consequences" obliges a forced-overlap test for a new path that takes two row classes.

Facts read on main (2026-10-28), which the rules below depend on:

- `repository_artifacts` is keyed by `content_hash`; `instance_attachments.content_hash` and
  `entity_record_attachments.content_hash` and `artifact_versions.content_hash` reference it with
  `ON DELETE RESTRICT` (`priv/repo/migrations/20260901000002_create_instance_attachments.exs`,
  `20260911000001_create_entity_record_attachments.exs`,
  `20260830030001_create_repository_artifacts.exs`). So the foreign keys already forbid deleting bytes
  that an attachment or an artifact version references. That answers the question 0056 D7 marked
  NOT VERIFIED.
- `document_versions.artefact_hash` is a plain `text` column with NO foreign key
  (`20261022100001_create_document_tables.exs`). The database therefore does NOT protect bytes that
  another document version references; the purge function must count those references (S5).
- `document_versions.content_hash` is the hash of the canonical `content` JSON, not a key of
  `repository_artifacts`. A purge request binds both `content_hash` and `artefact_hash` of the target.
- `documents.current_version` has a composite foreign key to `document_versions (document_id, id)`
  and `document_versions.superseded_by_version` a composite foreign key to the same table, both
  without `ON DELETE` action (so they restrict). `guard_documents()` forbids clearing
  `current_version`, so a version that is still the current pointer (also a cancelled one) cannot be
  deleted, and a version named by another version's `superseded_by_version` cannot be deleted. A third
  foreign key, `document_external_registrations (document_id, version_id)` to `document_versions (document_id, id)`,
  also has no `ON DELETE` action (`20261022100001_create_document_tables.exs`), so a version with an external
  registration cannot be deleted; that table also refuses DELETE (P6d). These three are the only foreign keys
  into `document_versions` (grep of `REFERENCES` in the migrations; the only one into `documents` is
  `document_versions.document_id`, a parent link that purge never touches).
- `document_versions` and `documents` DELETE is refused by `document_refuse()` for every caller
  (`20261022100002_create_document_immutability_triggers.exs`, trigger_specs); `repository_artifacts`
  DELETE is refused by `repository_artifacts_immutable()`. Both are `ENABLE ALWAYS` for the document
  tables.
- `Letflow.Documents.Retention.eligible_version_ids/2` (`lib/letflow/documents/retention.ex`) and
  `Letflow.Documents.Hold` (`lib/letflow/documents/hold.ex`, `lock_document/3`) exist. The REQ-603
  implementer greps their exact shape on `origin/main` before building.

## Settled points

### P1. Scope and what purge deletes

Purge removes ONE `document_versions` row (and its bytes when unreferenced, P5). It never deletes
the `documents` row, a `document_types` row or a `document_sequences` row. The current version of a document
therefore always remains, so the `documents` row keeps a valid `current_version`; this keeps the
number reserved (the unique `documents_number_key` index) so a number is never reissued, and keeps
the audit chain intelligible. The `documents` DELETE trigger is NOT given an exception.

Three structural refusals apply on top of 0063 S6 (they are consequences of the foreign keys above):

- A version that `documents.current_version` still points to is not purgeable.
- A version named by another version's `superseded_by_version` is not purgeable (it is the closing
  evidence of that version, 0063 S1). Practical order: oldest version first.
- A version that has a row in `document_external_registrations` is not purgeable (its foreign key restricts,
  and the registration is evidence of an external system holding the number). No registration is ever deleted, so
  a registered version is never purgeable; this is decided here, not left open.

All three are refused with `:purge_target_referenced` (P4 step 6), before the database foreign key is reached, so no raw 23503 escapes (INV-8). Order: the structural check (step 6) runs BEFORE eligibility (step 7), at the request step as well (P-V2). An `issued` current version is therefore refused as `:purge_target_referenced`, not `:purge_not_eligible`.
The eligibility query of 0063 S6 may return such an id; the purge function is the stricter guard, and
the request step (P2) refuses them too so a request is never created for them.

### P2. Request lifecycle, columns, events

`purge_requests` (tenant schema, a new tenant table; REQ-603 moves the tenant-table pins):

| Column | Meaning |
|---|---|
| `id` uuid PK | the request id; the approval is bound to it |
| `tenant_id` uuid NOT NULL | kept inside the schema (INV-1) |
| `document_id` uuid NOT NULL, `version_id` uuid NOT NULL, `version_no` integer NOT NULL | the one target |
| `content_hash` text NOT NULL, `artefact_hash` text NULL | the hashes at request time |
| `reason_code` text NOT NULL | closed list, P9 |
| `requested_by` uuid NOT NULL, `requested_at` timestamptz NOT NULL | database clock |
| `expires_at` timestamptz NOT NULL | `requested_at` + TTL (P9), database clock |
| `approved_by` uuid NULL, `approved_at` timestamptz NULL | set once, together |
| `consumed_at` timestamptz NULL | set once |

No free-text column: the reason is a code only, so nothing free can reach an event (0056 D9). No
foreign key to `document_versions`: the row must outlive the purged version as evidence (the audit
chain holds the same ids).

CHECKs: `approved_by IS NULL OR approved_by <> requested_by`; `(approved_by IS NULL) = (approved_at IS NULL)`;
`consumed_at IS NULL OR approved_at IS NOT NULL`; `expires_at > requested_at`.

Trigger `purge_requests_guard` (BEFORE UPDATE, row, `ENABLE ALWAYS`, fixed messages, no value echoed):
only `approved_by`+`approved_at` (together, NULL to value, once) and `consumed_at` (NULL to value, once)
may change; every other column is frozen. BEFORE DELETE and BEFORE TRUNCATE are refused for every caller
and there is no exception, also not the purge path.

Lifecycle:

| State (derived, no state column) | Meaning | Entered by | Who | Event (same transaction) |
|---|---|---|---|---|
| requested | row exists, `approved_at` NULL, `expires_at` in the future | request | holder of `DocumentsPurge` | `document.purge_requested` |
| approved | `approved_at` set, not consumed, not expired | approve | a DIFFERENT holder of `DocumentsPurge` | `document.purge_approved` |
| consumed | `consumed_at` set | purge | the purge caller (any holder of `DocumentsPurge`; the purge needs the approval, not a third person) | `document.purged` |
| expired | `expires_at <= now()` (database clock) and not consumed | time passes; nothing is written | nobody | none (no row change, no job) |

Allowed transitions: requested to approved, approved to consumed. Expired is terminal and a new
request is needed; an approval is never renewed or extended. Consumed is terminal.

Request-time checks (each also re-checked at purge): the document exists in the caller's scope
(otherwise `:purge_request_not_found`, P7); the version exists and is eligible by 0063 S6 and the
document is not on hold (`:purge_not_eligible` / `:purge_on_hold`); P1 structural refusals. A second
open (unconsumed, unexpired) request for the same version is refused with `:purge_request_exists`
(an expiry-aware module-code check, made under the `documents` row lock; no unique index, because an expired
request must not block a new one and an index cannot read the clock).

Events (hash-chain, same transaction as the change, 0056 D9 rules; payload keys exact):

- `document.purge_requested`: `request_id, document_id, version_id, version_no, content_hash, reason_code, requested_by, expires_at`.
- `document.purge_approved`: `request_id, document_id, version_id, approved_by, requested_by`.
- `document.purged`: `request_id, document_id, version_id, version_no, content_hash, artefact_hash, artefact_deleted (boolean), artefact_reference_count (integer), reason_code, requested_by, approved_by, actor`.

No content, no free text, no PII. Refusals are NOT audit events: they are telemetry plus the
aggregated counter of 0056 D9 (`document.refusals_summary`), so a caller cannot flood the audit chain.

### P3. Two-person rule in testable form

(a) Database: the CHECK `approved_by <> requested_by` (above).
(b) Module code: the approver must hold `DocumentsPurge` (resolved in the caller's scope; the permission is
checked by the same authorization function the route plug uses, not a second ad hoc check). This cannot be
a database check; it is a STATED RESIDUAL. Refusal `:purge_approver_not_permitted`.
(c) The approver is not the requester even when the requester holds every tenant permission: the module
compares user ids and refuses with `:purge_self_approval` before the database CHECK is reached; the CHECK
is the second line.
(d) One approval is bound to one request id, hence to one document, one version and the `content_hash` and
`artefact_hash` recorded in the request. At purge the function loads the target by the request's
`version_id`, compares `document_id`, `version_no`, `content_hash` and `artefact_hash` with the request,
and refuses a difference with `:purge_target_mismatch`. A consumed request is refused with
`:purge_request_consumed` (replay).
(e) Expiry on the database clock: the comparison is `expires_at <= now()` evaluated by the database inside
the purge and the approve transaction (a SQL expression, never `DateTime.utc_now()` in Elixir). Refusal
`:purge_request_expired`, at approve and at purge. An approval does not extend `expires_at`.

Consequence to state to the owner: because requester and approver must be two different holders of
`DocumentsPurge` and the permission is TENANT_ADMIN only (P7; inside a customer tenant only TENANT_ADMIN holds it), a tenant with ONE administrator cannot
purge a document at all. This is intended.

### P4. The atomic purge step, lock order, typed refusals

`purge(prefix, scope, request_id, actor_id)` runs ONE transaction (bound-parameter `SET LOCAL lock_timeout`
like the other lock paths of 0061; 55P03, 40P01 and 57014 map to a typed `:purge_busy` error, INV-8):

1. Read the request WITHOUT a lock, scoped by tenant prefix, to learn `document_id` (absent in this tenant:
   `:purge_request_not_found`).
2. `SELECT ... FOR UPDATE` on the `documents` row (id, tenant prefix and caller scope in one query, as
   `Letflow.Documents.Hold.lock_document/3`, which is private on main; REQ-603 COPIES its query shape into the purge module and does not extract it, to keep `Hold` untouched). Absent or out of scope: `:purge_request_not_found`.
3. Re-check `on_hold` on the LOCKED row: `:purge_on_hold`.
4. `SELECT ... FOR UPDATE` on the `purge_requests` row; re-read it. Then, in this order: unapproved
   `:purge_not_approved`; consumed `:purge_request_consumed`; expired (database clock) `:purge_request_expired`;
   `approved_by = requested_by` `:purge_self_approval`; approver does not (any longer) hold `DocumentsPurge`
   `:purge_approver_not_permitted`.
5. Load the target version; compare document, version_no, `content_hash`, `artefact_hash` with the request:
   `:purge_target_mismatch`. A missing version (already purged by another path): `:purge_target_mismatch`.
6. P1 structural check (current_version target, superseded_by target, external registration present): `:purge_target_referenced`.
7. Eligibility under 0063 S6 for THIS version, evaluated by the same predicate with the database `now()`
   (the REQ-603 implementer reuses the predicate, not a copy; if `eligible_version_ids/2` cannot be
   narrowed to one id the implementer extracts the predicate into a shared fragment, in the same PR):
   `:purge_not_eligible`. This is the guard of P8 and does not rest on the caller.
8. Set the guard setting: `SELECT set_config('letflow.purge_request_id', <request id text>, true)`
   (transaction-local) and nothing else sets it (P6a).
9. Count references to the version's `artefact_hash` (P5), `DELETE` the `document_versions` row, delete the
   `repository_artifacts` row only when the count is zero, write `document.purged`, set `consumed_at` (one
   UPDATE of the request row). The audit append is the LAST step.

Lock order: entity-type rows (0061 class 5), then the `documents` row, then the `purge_requests` row, then the
tenant audit chain row (0061 class 6; 0063 S5 placement). The `purge_requests` row sits between the
`documents` row and the audit row; no other path takes a `purge_requests` row before a `documents` row.
Request creation takes the `documents` row first (step 2 form) and approval takes only the `purge_requests`
row then the audit row, so neither can invert the order.

New path that takes two row classes: REQ-603 ships the forced-overlap test of 0063 "Consequences" (barrier
row, lock-queue order, deadlock and lock-timeout reported through the Repo telemetry event), test P-L1.

Typed error table (one distinct name per refusal; the web layer maps them; not-found is shaped like absent):

| Error | When |
|---|---|
| `:purge_request_not_found` | request or document absent, or in another tenant, or out of scope (INV-5; same response as absent) |
| `:purge_not_approved` | request has no approval |
| `:purge_self_approval` | approver equals requester |
| `:purge_approver_not_permitted` | approver lacks `DocumentsPurge` |
| `:purge_request_expired` | database clock past `expires_at` |
| `:purge_request_consumed` | `consumed_at` set |
| `:purge_target_mismatch` | document, version, `content_hash` or `artefact_hash` differs from the request, or version absent |
| `:purge_on_hold` | `on_hold` true under the lock |
| `:purge_not_eligible` | 0063 S6 predicate false (default keep, period not elapsed, status not superseded or cancelled) |
| `:purge_target_referenced` | P1 structural refusal |
| `:purge_request_exists` | request step only: open request for the version |
| `:purge_busy` | lock timeout, deadlock, statement cancel |

After ANY refusal: the version row, its bytes, the request row and the audit chain are unchanged and no
`document.purged` exists.

### P5. Shared bytes (threat T16)

Bytes in `repository_artifacts` are deleted only when no reference remains. References are counted, inside the
purge transaction after the guard setting is set and BEFORE the delete of the version row, as:

1. the number of OTHER `document_versions` rows (all statuses, any document in the tenant schema) whose
   `artefact_hash` equals the target's `artefact_hash`;
2. the number of `instance_attachments`, `entity_record_attachments` and `artifact_versions` rows whose
   `content_hash` equals it.

The version row is deleted in every case; the `repository_artifacts` row is deleted only when both counts are
zero. The attachment and artifact-version foreign keys are `ON DELETE RESTRICT`, so they are the SECOND line
for kind 2 (the database refuses the byte delete); there is NO foreign key for kind 1, so the count is the only
guard there. A target with `artefact_hash` NULL (never rendered) skips the byte step. `artefact_deleted` and
`artefact_reference_count` go in `document.purged`. A reference table added later is added to the count in the
same PR that adds it (REQ-603 states this in a code comment next to the count and the test P-S4 below guards
the list by scanning migrations for `references(:repository_artifacts`).

### P6. Trigger exception

(a) Guarded setting. `letflow.purge_request_id` is set only by the purge function (P4 step 8) with
`set_config(name, value, true)` (transaction-local; it is gone at COMMIT/ROLLBACK).
(b) The rewrite. A new tenant migration replaces, with `CREATE OR REPLACE`, `repository_artifacts_immutable()`
and the trigger function behind `document_versions_guard_delete`. Today `document_versions` DELETE uses the
shared `document_refuse()`; the migration adds a DELETE-specific function `document_versions_guard_delete()`
(and repoints that one trigger, `ENABLE ALWAYS`). Neither function distinguishes UPDATE from DELETE by name:
`repository_artifacts_immutable()` is also the UPDATE trigger function, so the rewrite branches on `TG_OP`:
UPDATE is ALWAYS refused; DELETE is allowed only when the exception holds.
(c) The exception predicate (the same text in both functions): `current_setting('letflow.purge_request_id', true)`
is a valid uuid and a `purge_requests` row with that id exists with `approved_at IS NOT NULL`,
`consumed_at IS NULL`, `expires_at > now()` and
 - for `document_versions`: `version_id = OLD.id` and `document_id = OLD.document_id`;
 - for `repository_artifacts`: `artefact_hash = OLD.content_hash` (the hash of the row being deleted).
A missing, empty, malformed or non-matching setting means the delete is refused with the existing fixed message.
The functions read the request table through `TG_TABLE_SCHEMA` with `format('%I')` (never a literal schema name),
like `guard_document_types()`.
(d) Shared with attachments: the byte exception applies to the one byte table, so it also makes an attachment's
bytes deletable on this path. The only things that stop that are the reference count (P5) and the
`ON DELETE RESTRICT` keys. No other trigger gets an exception: `documents`, `document_types`,
`document_sequences`, `document_external_registrations` and `purge_requests` keep refusing DELETE.
(e) Residual (restated from 0056 D7): code running as the application role can call `set_config` itself. The
setting alone grants nothing without an approved, unexpired, unconsumed request row that targets exactly that
row or hash; a role that could also insert and approve rows could forge one, and the row can be forged only
with `approved_by <> requested_by` (CHECK). The detective control is the audit chain
(`document.purge_requested`, `document.purge_approved`, `document.purged`). The `purge_requests` guard trigger
stops an update that sets `approved_by` twice, but an application-role caller could INSERT a row already
approved; to close that, the guard also has a BEFORE INSERT trigger that refuses a row inserted with
`approved_by`, `approved_at` or `consumed_at` set. Application-role attributes (superuser,
`session_replication_role`) remain NOT VERIFIED as in 0056 and are not changed here; all triggers are
`ENABLE ALWAYS`.
(f) Existing tenants: the rewrite is a `CREATE OR REPLACE` on every tenant schema through the tenant migration
manifest (`if prefix() do` guard); with no setting present the behaviour for existing rows is identical to
today (refuse). Nothing is backfilled.

### P7. Permission and scope

`DocumentsPurge` is a TENANT-scope permission (INV-10) held by TENANT_ADMIN, and by PLATFORM_ADMIN as it is for every core permission
(`core_role_allows?(:PLATFORM_ADMIN, _)` in `lib/letflow/api/authorization.ex`, same as `DocumentHold`). No carve-out is made
(decided: option a). PLATFORM_ADMIN is effective only in the platform tenant, because the role is stripped from tenant
users elsewhere in `authorization.ex`; inside a customer tenant a platform user acts as a tenant user and cannot purge. It is not a platform operation
and no route in this record is platform-scoped (a platform user acting inside a tenant is a tenant user of that tenant, and
`docs/roles.md` rule: never grant PLATFORM_ADMIN to a tenant user). Roles-matrix row for `docs/roles.md`
(columns as the neighbouring `DocumentHold` row: PLATFORM_ADMIN and TENANT_ADMIN yes, others no, scope tenant):

```
DocumentsPurge                  yes            no               no               no          no           no        yes          no             tenant
```

(the column set copies the `DocumentHold` row at implement time; the implementer re-reads the header). The
permission is added to `route_policies` of the same module (REQ-603 criterion 8 mechanics: golden through
`mix letflow.permission_matrix --write`, tenant-auditor refused-set literal, count pins).

Cross-tenant (INV-5, INV-10): a request or approval naming a document or request id that exists only in another
tenant is refused with `:purge_request_not_found`, mapped to the same response as an absent id; the other tenant's
rows are unchanged. Test P-X1.

Routes: this record names NO route. REQ-603 decides route shapes under the same rules as 0063 S7 (404 for
out-of-scope or cross-tenant, 403 at the plug for a caller without the permission, 422 for a missing or unknown
`reason_code`, 409 for a state conflict) and states the route-count pins. Whether purge is reachable without a
route (module function only, called by an operator task) is left to REQ-603.

### P8. Not-eligible is refused by the purge function itself

A version that is not eligible under 0063 S6 (default `keep` with no period, period not elapsed, on hold, status
`issued`, `draft` or `discarded`) is refused by the purge function with `:purge_not_eligible` (or
`:purge_on_hold` for a hold), on a request that is otherwise valid (approved, unexpired, unconsumed, matching).
The guard runs at P4 step 7 under the row lock, using the database clock; it does not rest on the caller having
filtered with the eligibility query. Discarded drafts are NOT purged by this record (0063 S6, and see P11).

### P9. Starting values (marked, not decided)

Both are SETTINGS of the process owner, not rules in code; the owner confirms or replaces them.

- Approval time-to-live: STARTING VALUE 72 hours from `requested_at` (covers a weekend), read from application
  configuration at request time and stored as `expires_at`; changing the setting never changes an existing
  request. The setting name is proposed `LETFLOW_DOCUMENT_PURGE_TTL_HOURS`; the record "Settings" row for it
  is added in REQ-603's decision-record update, stating the reason (a new env var needs a stated reason: the
  TTL is an owner decision and must change without a deploy). The source for the figure: none (0056 D7 gives no
  value).
- Closed `reason_code` list for a purge request: STARTING VALUES `retention_elapsed`,
  `customer_written_request`, `offboarding_written_request`, `legal_order`, `data_error_correction`. Format-checked
  like the hold codes (`^[a-z][a-z0-9_]{0,63}$`) and membership-checked against this list; the list is a module
  constant so the owner can change it by a requirement. The list is the owner's (0063 "Not decided here").

### P10. Archive is dropped

Decision: archive is NOT built and is not defined. Reasons: no source defines a destination (0057 D15 names the
action but no medium, owner or read path); the content of an issued version is already immutable and readable;
building an unspecified move would be a second destructive path with its own trigger exception for no stated
need. Consequence for `retention_action = 'archive'` of 0063 S3: the value stays legal in the CHECK
(no migration; 0063 A5 pins it) but is INERT. Eligibility still returns such versions (0063 S6 lists `archive`),
and the purge function refuses them with `:purge_not_eligible` because purge requires
`retention_action = 'purge'` (P4 step 7 adds this to the predicate check: purge never runs on `keep` or
`archive`). The retention policy write route (REQ-536) is NOT changed here; whether to make `archive` unsettable
is a follow-up for the owner (Q6). If the owner later wants archive, it needs its own decision record and
requirement; criteria that record would have to meet are: a named destination, a reversible or irreversible
statement, who may archive, how an archived version reads, its events, and a second-person rule.

### P11. Tenant offboarding and REQ-580

- A document purge inside a live tenant (this record) removes one version and uses this request/approval.
- REQ-580 / 0072 D4 tenant purge drops the whole tenant schema (`DROP SCHEMA`), which does not fire row
  DELETE triggers and does not use `purge_requests`. It is a separate path and is not changed here. It does not
  use this two-person rule and is not "document purge on written request".
- 0057 D19 "purge only on explicit written request and only after retention allows (default: never)" for an
  offboarded tenant, read with this record: a document purge for a frozen tenant follows the same `purge_requests`
  flow and the eligibility of 0063 S6 (retention allows), with `reason_code` `offboarding_written_request`. The
  record does NOT decide the second principal in a frozen tenant, because no source says who it is (every user of
  a frozen tenant is read-only): Q4.
- A legal hold blocks both (0056 D7: it blocks purge and "tenant offboarding export deletion"). It blocks a
  document purge here (P4 step 3). Whether REQ-580's tenant purge refuses a tenant that has a document on hold is
  NOT decided here and not changed here: it is an owner question and a candidate amendment of REQ-580 (Q5).
  Until decided, the QA-only tenant purge of 0072 remains as specified (QA demo data only, 0072 D4).

### P12. Test list for REQ-603

One ID per refusal of P3 to P8, plus the structural ones. REQ-603 criteria map one to one to these.

| ID | Refusal / rule | Error | Notes |
|---|---|---|---|
| P-C1 | insert a row with `approved_by = requested_by` directly | CHECK violation | P3a |
| P-C2 | insert a row already approved or consumed | insert trigger refusal | P6e |
| P-C3 | update any frozen column; set `approved_by` twice; set `consumed_at` twice | trigger refusal | P2 |
| P-C4 | DELETE and TRUNCATE of a request row | trigger refusal | P2 |
| P-A1 | approver without `DocumentsPurge` | `:purge_approver_not_permitted` | P3b |
| P-A2 | approver equals requester holding every tenant permission | `:purge_self_approval` | P3c |
| P-A3 | approval reused for another document/version/hash (alter target after request) | `:purge_target_mismatch` | P3d; the fixture changes the version's hash through an unguarded test path or builds a second request |
| P-A4 | second purge with a consumed request | `:purge_request_consumed` | P3d replay |
| P-A5 | expired request, approve and purge, clock forced in the database (set `expires_at` in the past at insert) | `:purge_request_expired` | P3e |
| P-A6 | unapproved request purged | `:purge_not_approved` | P4 |
| P-E1 | default policy (`keep`, no period) | `:purge_not_eligible` | P8, called directly |
| P-E2 | period not elapsed | `:purge_not_eligible` | P8 |
| P-E3 | status `issued` not current, `draft`, `discarded` (an `issued` CURRENT version is P-R1) | `:purge_not_eligible` | P8, one test per status; structural check runs first (P1) |
| P-E4 | `retention_action = archive` | `:purge_not_eligible` | P10 |
| P-H1 | on hold, sequential | `:purge_on_hold` | P4 step 3 |
| P-L1 | forced overlap: hold set during an in-flight purge, barrier row, lock-queue order, deadlock and lock-timeout through the Repo telemetry event | blocks or `:purge_on_hold`, never both succeed | 0063 Consequences; `:purge_busy` on timeout |
| P-R1 | version is `documents.current_version` target (cancelled current, and `issued` current) | `:purge_target_referenced` | P1; one test per status, structural before eligibility |
| P-R2 | version named by another version's `superseded_by_version` | `:purge_target_referenced` | P1 |
| P-R3 | version has a row in `document_external_registrations` | `:purge_target_referenced`, no raw 23503 | P1 |
| P-S1 | bytes referenced by another document version survive; version row gone | no error, `artefact_deleted` false | P5 |
| P-S2 | bytes referenced by an attachment survive | same | P5, count and FK |
| P-S3 | bytes referenced by nothing are deleted | `artefact_deleted` true | P5 |
| P-S4 | scan migrations for tables with `references(:repository_artifacts` and compare to the counted list | test failure | P5 |
| P-G1 | DELETE of a version and of an artifact row without the setting | trigger refusal (existing messages) | P6 |
| P-G2 | setting equal to the id of an approved, unexpired, unconsumed request targeting exactly that row/hash | delete allowed | P6 |
| P-G3 | setting set to any other value, a malformed value, or a request for another row/hash, or an expired/consumed request | trigger refusal | P6 |
| P-G4 | the setting is not visible after the transaction ends | `current_setting(..., true)` empty | P6a |
| P-T1 | forced failure after the delete: version, event and `consumed_at` roll back together | rollback | P4 step 9 |
| P-T2 | audit append forced to fail (DROP TABLE audit_entries, the raise is rescued) | typed error, no change | `Audit.append_multi` raises |
| P-X1 | cross-tenant request and approve (two tenants), absent-id comparison byte for byte | `:purge_request_not_found` | P7, INV-5, INV-10 |
| P-X2 | permission matrix: `DocumentsPurge` tenant scope, TENANT_ADMIN and PLATFORM_ADMIN yes (platform effective only in the platform tenant), others no, golden regenerated; a PLATFORM_ADMIN acting in a customer tenant is refused | matrix test | P7 |
| P-V1 | event payload keys exactly, for the three events | key list | P2 |
| P-V2 | request step refuses a not-eligible, held or structurally referenced version and a duplicate open request | `:purge_not_eligible`, `:purge_on_hold`, `:purge_target_referenced` (incl. registered version), `:purge_request_exists` | P2 |
| P-V3 | unknown or malformed `reason_code` | validation error (422 at the route) | P9 |

Race-only rows: P-L1 covers the hold race with the barrier technique (not a pure race). Two concurrent purges of
one request are serialized by the `purge_requests` row lock; the second sees `consumed_at` and gets
`:purge_request_consumed`; it is covered sequentially by P-A4 and its lock order by P-L1.

## Open owner questions

| # | Question | Source |
|---|---|---|
| Q1 | Approval TTL value (starting value 72 hours is a proposal, P9) | 0056 D7 gives none |
| Q2 | Closed `reason_code` list for purge (starting list is a proposal, P9) | 0063 "Not decided here" |
| Q3 | Legal minimum retention period per document type; the product ships no figure | 0056 open point 5 (customer decision, Kazakhmys), 0057 D15 |
| Q4 | Second principal for a document purge in a frozen (offboarded) tenant | 0057 D19 does not say; P11 |
| Q5 | Whether the QA tenant purge of REQ-580 must refuse a tenant with a document on hold | 0056 D7 "blocks tenant offboarding export deletion"; REQ-580 silent |
| Q6 | Make `retention_action = 'archive'` unsettable (it is inert after P10) | P10 |
| Q7 | Whether discarded drafts are ever purged (this record: no) | 0063 S6, "Not decided here" |
| Q8 | Single-administrator tenants cannot purge (two holders needed): accept, or add a second role | P3 consequence |

## Consequences

- New tenant table `purge_requests` (moves the tenant-table list pins in `test/support/tenant_fixture.ex` and its count test),
  new permission `DocumentsPurge` (matrix golden, auditor refused set, count pins), three BINDING event names
  (the audit event name list wherever pinned), a replaced `repository_artifacts_immutable()` and a new
  `document_versions` DELETE guard function: all in REQ-603, not here.
- 0056 D7 becomes BINDING as amended by P1 to P6; D9 gains the three payloads of P2.
- A new path that takes two row classes: forced-overlap test P-L1 before REQ-603 merges (0063 Consequences, 0061 rule 5).
- 0061 is not amended; the `purge_requests` row is placed between the `documents` row and the audit row (P4).
- Documents are never fully removed: the `documents` row stays (P1).

## Sign-off

- Designer: T-0856 designer, 2026-10-28 (this document).
- CODE-DESIGN-VALIDATOR: PASS (design_gate attempt 2, T-0856; three attempt-1 blockers fixed, citations re-checked against main).
- REVIEWER: pending.
- Ratification: pending the owner or REVIEWER. Until then GH #3389 (REQ-603) is not claimed.
