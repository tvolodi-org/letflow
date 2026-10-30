# 0066 -- Generic saved views over records (list views; slice 0, decision only)

Status: PROPOSED by the designer of REQ-554 (task T-0500), 2026-10-25. Needs SECURITY-REVIEWER and
REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice is its own requirement.
The issue number recorded for REQ-554 in `docs/requirements.yaml` (`gh: 3153`) is the closed issue of
REQ-538, not a live issue for this record; the operator registers issues and fixes the `gh` values.

Date: 2026-10-25

Depends on: REQ-315 (`POST /entities/query/aggregate`, used only by the deferred pivot slice);
REQ-554 (this record); REQ-555 (backend slice) and REQ-556 (web slice), which build on it.
Not this: the exam results list of decision 0031 / REQ-350; joined types (REQ-300) are excluded (D2).

## Problem

Wave 3 of `docs/migration/core-roadmap-20261014.md` ("Generic list, pivot and graph views and a report
builder over entities") needs a decision before any code: who sees a saved view, what a view stores, how
it is read, who may change it, and where it lives. A wrong answer here creates a second read path over
tenant data, which is the main risk this record closes.

## Decisions

Each decision gives its source, or is marked ASSUMPTION for the process owner to confirm.

### D1. Sharing is tenant-wide

Every caller of the tenant who may read the entity type sees every saved view of that type. There is no
owner-private view. ASSUMPTION (the BA's working assumption in REQ-554), to be confirmed by the process
owner. Per-user views are deferred; they would need an owner column and a visibility rule.

### D2. One entity type per view

A view belongs to exactly one entity type. Source: REQ-554 and REQ-555 descriptions. Views over joined
types (REQ-300) are out of scope.

### D3. A stored view is replayed through `POST /entities/query`; no second read path

A view stores ordered columns, a filter (the clause list `POST /entities/query` accepts) and a sort. The
list screen replays it as an ordinary `POST /entities/query` call, so `Letflow.Entities.RequestAccess.check/4`,
`Query.Compiler`, `Allowlist`, `Cursor` and `FieldGrants` apply exactly as for a hand-built query (source:
REQ-554). No view route returns record data. Write-time validation of a view uses the same allowlist and
clause rules. Because the view is replayed under the caller's own grants, a stored view never widens
access (INV-2).

### D4. Permissions

- Read views: the existing `EntitiesQuery` permission (the policy key of `POST /entities/query`).
- Create, edit, delete views: a new tenant-scope permission `EntitiesViewsManage`, held by TENANT_ADMIN
  only (platform admin through the unconditional platform clause). Source: REQ-554 candidate and REQ-555
  criteria. ASSUMPTION: TENANT_ADMIN-only is for the process owner to confirm.

This record only names the permission; REQ-555 adds it (roles row in `docs/roles.md`, permission-matrix
golden). The names match REQ-555, so this record changes nothing in REQ-555 or REQ-556.

### D5. Storage in the tenant schema

Views live in a table of the tenant schema (schema-per-tenant `:prefix`, `tenant_id` kept in the table),
name unique per entity type, with the stored columns, filter and sort and the actor and timestamps of
creation and last change (INV-1, INV-6). The migration belongs to REQ-555, not to this record.

### D6. Not-found and forbidden are indistinguishable

A view of a type the caller may not read, of another tenant, or an absent id returns the identical 404
(INV-5). No view route takes a tenant identifier (INV-10).

### D7. Audit

Create, update and delete write an audit event in the same transaction; a refused write writes none.

## Tests the build requirements must carry

| ID | Invariant | Test |
|---|---|---|
| V1 | INV-10 cross-tenant negative | A TENANT_ADMIN of tenant B reads, updates and deletes a view that exists only in tenant A and gets the same 404 as for an absent id, with a byte-identical body; the tenant A row is unchanged. |
| V2 | INV-2 field redaction | A view naming a field the caller has no grant on, replayed through `POST /entities/query`, redacts that field exactly like a hand-built query; no view route response contains a record value. |
| V3 | INV-5 not-found | A view of an unreadable type, of another tenant, and an absent id return the same status, headers and body. |

REQ-555 additionally carries: a storage isolation test (INV-1, INV-6), a 422 test per invalid write case,
the permission-matrix and golden update, and the route-count pin updates.

## Deferred slices

Each is its own later requirement, registered separately by the BA; all of them are now registered.

- Slice 2: pivot view over `POST /entities/query/aggregate` (REQ-315); registered as REQ-598.
- Slice 3: graph view; registered as REQ-613.
- Slice 4: report builder; registered as REQ-619 and delivered (PRs #3461 and #3468, GH #3453).
- Slice 5: web report builder over the slice 4 backend; registered as REQ-634 and delivered (parts A and B).

Also deferred: per-user views (D1), joined types (D2), view versioning, and views across tenants.

## Assumptions for the process owner

1. D1: tenant-wide sharing rather than per-user.
2. D4: `EntitiesViewsManage` held by TENANT_ADMIN only.

## Sign-off

- SECURITY-REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
- REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
