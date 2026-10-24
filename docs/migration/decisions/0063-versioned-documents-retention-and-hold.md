# 0063 -- Versioned documents, slice 2 part 1: retention policy and legal hold (amends 0056 D1, D4, D7, D8, D9)

Status: PROPOSED by the designer of GH #2675 (task T-0363), 2026-10-24. Not yet ratified:
the amendment binds only after the owner or REVIEWER signs it (see Sign-off). REQ-508 may be
re-validated against this record once it is ratified.

Amends: [0056](0056-versioned-documents.md) D1 (the `document_types` column list), D4 (the
`document_types` trigger row, and the `documents` mutable columns), D7 (retention and hold
become BINDING for REQ-508 only), D8 (two permission names), D9 (two event payloads).
Clarifies: [0057](0057-wms-customer-draft-reconciliation.md) D15 (retention: FOREVER by
default, per type, counted from creation or from closing). Everything else in 0056 is unchanged.
Purge and archive execution (0056 D7, purge_requests, two-person approval) stay out of this
record; they belong to REQ-509 (GH #2677).

## Context

GH #2588 (REQ-500, decision 0056 slice 1) is on main (commit 978a7bbca). Read against that
code, the following holds, and REQ-VALIDATOR's round-2 points are settled below:

- `document_versions` has `issued_at`, `cancelled_at`, `discarded_at` and
  `superseded_by_version`, but **no `superseded_at`** (`priv/repo/migrations/20261022100001_create_document_tables.exs`).
- `document_types` has **no `retention_class` column** on main. The name exists only in the
  0056 D1 prose. Nothing in `lib/` or `priv/` refers to it (`grep -rn retention lib/letflow/documents`
  returns nothing).
- `guard_document_types()` (`priv/repo/migrations/20261022100002_create_document_immutability_triggers.exs`)
  refuses **every** UPDATE of a `document_types` row once a `documents` row of that type exists,
  on every column. This is the trigger that the exemption below relaxes.
- `documents` has no hold column yet.
- No document permission (`DocumentsRead`, `DocumentsIssue`, `DocumentHold`, ...) and no document
  route exist in `lib/letflow/api/` on main. Slice 1 delivered the model only.

## Settled points

### S1. Where the "left `issued`" time comes from (no new column)

For a version `v` that is no longer `issued`:

- `v.status = 'cancelled'`: the time it left `issued` is `v.cancelled_at`.
- `v.status = 'superseded'`: the time it left `issued` is `issued_at` of the version named by
  `v.superseded_by_version`. D4 makes the supersede and the issue of the next version ONE
  transaction, so this is the server-clock instant at which `v` stopped being current.

Consequence: no `superseded_at` column is added, and the D4 trigger on `document_versions` is
NOT changed. The cost is one self-join on `(document_id, superseded_by_version)`, which is a
composite foreign key on main, so it is indexed by that key.

### S2. D15 interpretation (0057 D15, "counted from creation or from closing")

- **Creation** = `document_versions.issued_at` of THAT version (server clock, D2). A draft's
  `inserted_at` is NOT creation: a draft carries no legal effect and no number.
- **Closing** = the time the version left `issued` (S1).
- The `retention_from` value chooses between them: `issued` counts from creation,
  `superseded_or_cancelled` counts from closing. Retention is per VERSION (0056 D7 purges per
  version), so each version of a document has its own clock.

### S3. D1/D4 exemption for exactly three columns; what happens to `retention_class`

- `retention_class` is **dropped from the 0056 D1 list**. It was never created, so nothing is
  renamed or dropped in the database. Its role is taken by three columns, below.
- New `document_types` columns (migration in part (a)):
  - `retention_period_days integer NULL CHECK (retention_period_days IS NULL OR retention_period_days > 0)`.
    NULL means `forever`. A nullable integer is used instead of a `'forever'` sentinel string, so
    "forever" cannot be spelled two ways. Default NULL.
  - `retention_from text NOT NULL DEFAULT 'issued' CHECK (retention_from IN ('issued', 'superseded_or_cancelled'))`.
  - `retention_action text NOT NULL DEFAULT 'keep' CHECK (retention_action IN ('keep', 'archive', 'purge'))`.
  The defaults mean every existing type is `forever` and `keep`. `ADD COLUMN` with a constant
  default does not fire the row trigger, so existing types are unaffected.
- The exemption is column-aware, in `guard_document_types()`. The existing "hit" check stays:
  when a document of the type exists, the UPDATE is refused UNLESS the set of changed columns is
  a subset of `{retention_period_days, retention_from, retention_action}`. Written as the D4
  precedent does it:
  `IF (to_jsonb(OLD) - ARRAY['retention_period_days','retention_from','retention_action']) IS DISTINCT FROM (to_jsonb(NEW) - ARRAY[...]) THEN RAISE ...`.
  The other seven columns (`numbering_scope`, `number_prefix`, `number_pad`,
  `legal_entity_required`, `restricted_fields_allowed`, `declared_fields`, `template_ref`, and
  `key`/`tenant_id`/`owner_module`/`inserted_at`) stay frozen. DELETE and TRUNCATE stay refused.
- Policy changes apply to the FUTURE eligibility computation only (S4). No document row, version
  row or hash changes. The policy is read live, not copied into each version, because copying it
  would need three more columns on every version row and a trigger change on `document_versions`.
  Recorded as a residual: a version's retention is whatever the type says at the moment the
  eligibility query runs.

### S4. Audit of policy changes, and whether shortening needs more than a permission

- Each policy UPDATE writes `document.retention_policy_changed` in the SAME transaction (0056 D9
  rule). Payload: `type_key`, `before` and `after` (the three values), `reason_code`, `actor`. No
  free text (0056 D9: payloads carry ids, counters and reason codes only). The mandatory reason is
  a closed code list (`reason_code`), see S5.
- Permission: `DocumentsRetentionManage` (TENANT scope; see S7). Held by TENANT_ADMIN only (0046 D5:
  TENANT_ADMIN holds every tenant-scope permission; no other role does).
- Shortening a period, or setting `retention_action` to `purge`, needs NO second principal in
  this record. Reason: this slice executes nothing. A policy change only changes what the
  eligibility query returns. The destructive step is REQ-509, which requires a second principal
  (0056 D7: `approved_by <> requested_by` in the database). The residual is named: a single
  TENANT_ADMIN can shorten a period now and rely on REQ-509 for the approval; the audit event
  makes the shortening visible.

### S5. Legal hold (0056 D7, adopted; reason shape decided here)

- `documents` gains (part (a) migration, so the eligibility query can read it):
  `on_hold boolean NOT NULL DEFAULT false`, `hold_set_at`, `hold_set_by`, `hold_reason_code`,
  `hold_reason_note`, `hold_cleared_at`, `hold_cleared_by`, `hold_clear_reason_code`,
  `hold_clear_reason_note`, all NULL by default. CHECK: `on_hold` implies `hold_set_at`,
  `hold_set_by` and `hold_reason_code` are set.
- Reason = a closed `reason_code` (enum set fixed in the product code and listed in the
  permission docs; this record fixes the mechanism, not the list) PLUS a required, non-blank
  `reason_note` (free text). The note is stored on the row only and is NEVER in an event payload.
  Set and clear each need both (422 otherwise), in the same transaction as their event.
- Set and clear are separate steps (0056 D7). A clear needs its own code and note.
- Events: `document.hold_set` (document_id, reason_code, actor) and `document.hold_cleared`
  (document_id, reason_code, actor). Both written in the same transaction as the column change.
- A hold is document-level. A hold on a type is not modelled (0056 D7 says so; a type-level hold
  is an operator bulk set, out of scope).
- Hold does not change any version row. The guard on `documents` lets `on_hold` and the hold
  columns change; no new trigger is needed.

### S6. Which version statuses are eligible

Eligible: `superseded` and `cancelled` versions only. Each has left `issued` and therefore has a
closing time (S1).

Not eligible, with the reason:

- `issued` (including the current version): the live legal document. Its clock is still running
  or it has not been closed. Even with `retention_from = issued` and a period that has passed, a
  current issued version is never eligible. Only once it is superseded or cancelled does it
  become eligible.
- `draft`: never issued, no number, no legal effect, no creation time as defined in S2.
- `discarded`: never issued (`draft -> discarded` is the only way in), so it has no creation time
  as defined in S2. Discarded drafts are not purged by this slice; a separate record decides
  whether they ever are.

A version whose document is on hold (`documents.on_hold`) is never eligible (S5).

Eligibility predicate (the query of part (a); `now` is an injected parameter so tests can fix the clock):

```
closed_at(v)  = CASE v.status
                  WHEN 'cancelled'  THEN v.cancelled_at
                  WHEN 'superseded' THEN nxt.issued_at      -- nxt = the version named by superseded_by_version
                END
reference(v)  = CASE t.retention_from
                  WHEN 'issued' THEN v.issued_at
                  ELSE closed_at(v)
                END
eligible(v)   = t.retention_period_days IS NOT NULL
            AND v.status IN ('superseded', 'cancelled')
            AND NOT d.on_hold
            AND reference(v) + make_interval(days => t.retention_period_days) <= :now
```

Note: `retention_from = issued` takes `v.issued_at`, which exists for every superseded or
cancelled version (CHECK on main: an issued row has `issued_at`). The query returns version ids
and performs no action (REQ-508 executes nothing).

### S7. Route security

Routes (all under the tenant API, `/api/v1`):

| Route | Permission | Scope | Notes |
|---|---|---|---|
| `PUT /documents/types/:key/retention` | `DocumentsRetentionManage` | tenant-wide grant required | body: `retention_period_days` (null = forever), `retention_from`, `retention_action`, `reason_code` |
| `POST /documents/:document_id/hold` | `DocumentHold` | document scope (0051 via `issuing_org_unit_id`) | body: `reason_code`, `reason_note` |
| `POST /documents/:document_id/hold/release` | `DocumentHold` | document scope | body: `reason_code`, `reason_note` |

- Order of checks, for every route: (1) the permission check at the plug, which does not depend
  on the id and so gives the same 403 for any id, existing or not; (2) ONE scoped query on
  `(id, tenant prefix)` that also applies the caller's scope; (3) the action in the same
  transaction as its audit event.
- **404 for an out-of-scope document**: a document outside the caller's scope, a document of
  another tenant and an absent id return the same 404, with the same headers and body (INV-5;
  0056 D8). Scope is `issuing_org_unit_id` resolved through the caller's 0051 grants.
- **No permission: 403** at the plug (INV-5: the refusal does not reveal whether the id exists).
- `GET`-style reads of retention policy are not added in this slice. The policy is part of the
  type's own reads, which are a slice 1 concern.
- **TENANT classification (INV-10)**: `DocumentsRetentionManage` and `DocumentHold` are TENANT
  scope in `permission_scope/1` (`lib/letflow/api/authorization.ex`). The atom list, `core_permissions`
  and the `@permission_scope` map must each name them; a permission without a scope fails the
  suite (`authorization.ex`, the ISS-0993 section 5 rule). Neither is ever granted to
  PLATFORM_ADMIN or another tenant's role; the `docs/roles.md` row for TENANT_ADMIN is the only
  holder (0046 D5).
- **INV-10 cross-tenant negative test**: none of the three routes takes a tenant identifier; the
  tenant is the request's database-resolved prefix. The required test: a TENANT_ADMIN of tenant B
  calls each route with a document id (or type key) of tenant A and receives the same 404 (or
  403 for a caller without the permission) as for an absent id, with a byte-identical body.
- Refusals (403, 404, 422 on a missing reason) are telemetry only; successful changes are the
  only audited actions (0056 D9 refusal rule).
- Permission names and the matrix row are fixed here: `DocumentHold` and `DocumentsRetentionManage`
  (the record of 0056 D8 reserved `DocumentHold`; `DocumentsRetentionManage` is new). The
  implementing requirement adds both to the permission matrix (`docs/roles.md`) and the golden.

### S8. D15 and the existing D8 permission set

0056 D8 says the slice-1 permissions (`DocumentsRead`, `DocumentsDraft`, `DocumentsIssue`,
`DocumentsCancel`) are BINDING. None of them is on main (`grep -rn DocumentsCancel lib/` finds
nothing). This record does not depend on them: REQ-508 adds its two permissions on the same
additive shape as `:AttachmentLinksIssue`. Whether the slice-1 permissions land in the same
change or a separate one is for the REQ-508 implementer to state; this record does not decide it.

## Split (required by the sizing criterion)

REQ-508 is split in two, and each part is a shippable change.

**(a) Policy columns, eligibility query.**
- Migration: the three `document_types` columns (S3), the `documents` hold columns (S5, no routes),
  the `guard_document_types()` exemption (S3).
- `Letflow.Documents` retention module: the eligibility query (S6), with an injected `now`.
- The policy write function: UPDATE of the three columns plus `document.retention_policy_changed`
  in one transaction. No route yet.
- Tests: defaults `forever`/`keep` return no version; 30 days from `issued` (a version 31 days
  old is eligible, 29 days old is not); 30 days from `superseded_or_cancelled` (eligible only 30
  days after it left issued); a held document's versions are never eligible; trigger test both
  ways (the three columns change; each of the other seven fails); audit payload carries before and
  after.

**(b) Hold and routes.**
- The hold set and clear functions with `document.hold_set` / `document.hold_cleared`, mandatory
  code and note (422 without).
- `DocumentHold` and `DocumentsRetentionManage` in `authorization.ex` (TENANT scope), the matrix row
  in `docs/roles.md`, and the golden.
- The three routes of S7, with the 404 and 403 tests, and the INV-10 cross-tenant negative test.

Part (b) reads the `on_hold` column that part (a) adds, so (a) lands first.

## Tests (acceptance criteria to test IDs)

- A1 (left-issued time): superseded version's closing time equals the superseding version's
  `issued_at`; cancelled version's closing time equals `cancelled_at`. Part (a).
- A2 (D15 interpretation): a version issued 31 days ago with `retention_from = issued` is eligible;
  with `superseded_or_cancelled` the same version is not eligible until 30 days after it closed.
  Part (a).
- A3 (exemption): UPDATE of each of the three columns succeeds once a document of the type exists;
  UPDATE of each of the other seven fails. Part (a).
- A4 (eligible statuses): `issued` (current and not), `draft` and `discarded` are never returned
  even with an elapsed clock. Part (a).
- A5 (defaults): `forever`/`keep` returns no version ever. Part (a).
- A6 (audit): each policy change writes `document.retention_policy_changed` with before and after
  in the same transaction. Part (a).
- A7 (hold): set and clear each need a code and a note (422 without); both write their event in
  the same transaction; a held document is never eligible; clear restores eligibility. Part (b).
- A8 (routes): out-of-scope document = 404 identical to absent; caller without the permission =
  403 at the plug; INV-10 cross-tenant negative test for all three routes. Part (b).
- A9 (classification): `DocumentsRetentionManage` and `DocumentHold` are `:tenant` in
  `permission_scope/1`; neither is held by PLATFORM_ADMIN in the matrix test. Part (b).

## Not decided here (for the owner)

- The closed `reason_code` list for hold and policy changes. The mechanism is fixed (S5); the list
  is a product list.
- Whether a shortening should later need a second principal even before REQ-509 (S4 says no).
- Whether the slice-1 permissions of 0056 D8 land with REQ-508 or in their own change (S8).
- Whether discarded drafts are ever purged (S6 says no; a later record decides).

## Consequences

- `retention_class` leaves the 0056 D1 list; no database object is removed.
- The `document_types` UPDATE trigger gets one exemption, tested both ways.
- `document.retention_policy_changed`, `document.hold_set` and `document.hold_cleared` join the
  0056 D9 BINDING events list (the first two are new names, the third was reserved).
- REQ-509 (purge) consumes the eligibility query of S6 and the hold column of S5; it must check
  `on_hold` again at purge time under the row lock (0056 D7).

## Sign-off

- Designer: T-0363 designer, 2026-10-24 (this document).
- Ratification: pending the owner or REVIEWER. Until then GH #2675 stays blocked.
