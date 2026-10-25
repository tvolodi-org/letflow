# 0070 -- Tenant-owned record types: a second per-type write grant, a core-owned scope declaration, module references by record id, and generated lists and forms derived from the definition only

Status: PROPOSED by the developer of GH #3205 (REQ-566 slice 0, task T-0520), 2026-10-25. Needs SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice is its own requirement (see D6).

Date: 2026-10-25

Number: 0070, not 0069. On 2026-10-25 the number 0069 was free on main but already held by the unmerged branch of task T-0519 (`0069-solution-versioning-and-per-tenant-overrides.md`). Taking 0070 avoids a third duplicate number (0066 and 0067 each exist twice already). The gap is deliberate. If T-0519 is abandoned, this file may be renumbered to 0069.

Requirement: REQ-566 (GH #3205).

Depends on: REQ-517, REQ-518, REQ-519 (scope enforcement, Stage 2), REQ-394 (TypeAccess), REQ-231 (FieldGrants), REQ-496.

Scope: the five gaps that [0053](0053-tenant-scripted-rules.md) "Customization beyond scripts", candidate (a), lists for a tenant-owned type to be a first-class record type, and the D-section that settles each:

1. module references by id -> D4;
2. reference pickers and related lists -> D5;
3. generated lists and forms -> D5;
4. per-type WRITE permission -> D2;
5. a [0051](0051-org-scoped-role-grants-and-enforcement.md) scope declaration -> D3.

Relation to 0050, 0051 and 0053: this record **amends no sentence of 0050, 0051 or 0053.** It relies on 0050 D2, D3.1 to D3.5 and D7 (`managed_by` lock), 0051 D5, D6, D7, D11 and D12, and 0053 candidate (a). Two strict extensions are flagged for REVIEWER, each as an extension and not an amendment: (1) D3 adds a core-owned table as a third source of scope declarations, next to the sentence in the `ScopeDeclaration` moduledoc "never read from a tenant definition" (the table is not the tenant definition JSON); (2) D4 runs a core check for tenant types where 0050 D3.6 says "no FK in slice 1" (the no-FK rule itself is kept). If REVIEWER rules either an amendment, an amending record is needed before the slice that depends on it starts.

## Sources

Files and records opened for this record:

- `docs/migration/core-roadmap-20261014.md`, row "Customization beyond scripts" (tenant-owned record types).
- REQ-566 as registered in `docs/requirements.yaml`.
- [0050](0050-foundation-modules-org-catalog-and-reference-contract.md) D2, D3 (D3.1 to D3.6), D7, D8; [0051](0051-org-scoped-role-grants-and-enforcement.md) D5, D6, D7, D11, D12; [0053](0053-tenant-scripted-rules.md) candidate list.
- `lib/letflow/entities/record_access.ex`, `lib/letflow/entities/type_access.ex`, `lib/letflow/entities/restrictions.ex`, `lib/letflow/entities/scope_declaration.ex`, `lib/letflow/entities/managed_types.ex`.
- `lib/letflow/entities/step_writes.ex` (`check_type_access/2`), `lib/letflow/entities/handler_writes.ex`.
- `lib/letflow/routers/entities.ex` (record routes, `POST /query`, `POST /restrictions/import`), `lib/letflow/routers/entities/record_attachments.ex`.
- `docs/agents/instructions/security-invariants.md`, `docs/roles.md`, `priv/permission_matrix/effective.golden`.

Facts read in the code that the decisions rely on:

- `Letflow.Entities.RecordAccess.write/3` is called first in record create, update, delete and import. It consults `ManagedTypes.owner_of/2`, `TypeAccess.authorized?/3`, the active definition and `FieldGrants.load_restrictions/3` and decides hidden, then managed, then open. `Records` itself stays ungated.
- `TypeAccess` has no read/write distinction: a grant covers both. A type with a restriction row denies a user without a grant for write already, through the same gate.
- Tables `entity_type_restrictions` and `user_entity_type_grants` are authored only by `Restrictions.import_restrictions/2` (route `POST /restrictions/import`, permission `EntitiesRestrictionsManage`, TENANT_ADMIN only). It upserts with `on_conflict: :nothing`.
- `ScopeDeclaration` reads module manifests only (`:scope_declarations`); a type no manifest names is `:undeclared` and returns no data to a scoped caller. 0051 D6 adds that the definitions API refuses altering declarations.
- `POST /query` is permission `EntitiesQuery` with `scope: :filter`.
- `PROCESS_DESIGNER` holds `EntitiesDefinitionsWrite` in `effective.golden`.

## Decisions

### D1. Tenant isolation and new data-access paths

**Decision.** Every new table lives in the tenant schema (`:prefix`, with `tenant_id` kept inside each row, INV-1); no platform, worker or admin path is exempt. No new route takes a tenant identifier: the tenant comes from the auth context only. Where a route did take one, INV-10 would require a cross-tenant negative test. A cross-tenant or unknown type answers exactly as an absent one (INV-5), reusing the `:hidden` value of `RecordAccess`.

Expected new data-access paths and the INV-6 proof each slice must carry:

- the write-grant read in `RecordAccess.write/3` and `StepWrites.check_type_access/2`: two-tenant test, same type name, a grant in tenant A does not open tenant B;
- the scope-declaration set route and the `ScopeDeclaration` third source: cross-tenant negative on the route; a declaration in tenant A is not read for tenant B;
- the reference validation read: another tenant's target id is refused as absent.

**Reasons.** Tenant isolation is the first invariant; naming the paths now lets the security review check them against a list instead of discovering them.

**Source.** `security-invariants.md` (INV-1, INV-5, INV-6, INV-10); `record_access.ex`; `type_access.ex`.

### D2. Per-type write permission

**Decision.** Options: (1) a second pair of tables mirroring `TypeAccess` (write restrictions and write grants); (2) a `mode` column on the existing `user_entity_type_grants` and `entity_type_restrictions`; (3) a permission list inside the definition JSON. Chosen: **(1)**.

Rules:

- Default-allow like `TypeAccess`: no write-restriction row means write is governed by `TypeAccess` exactly as today.
- On a write-restricted type, a write needs the user to pass `TypeAccess` read AND hold a write grant. A write grant does not imply read (a user with a write grant and no read access still gets `:hidden`); read access never implies write.
- Composition order: the `managed_by` lock first and absolute (a write restriction or grant naming a module-managed type is refused at import with the managed 403 and never stored), then `TypeAccess`, then the write grant, then `FieldGrants` (field level, unchanged), then scope (0051 D6).
- Denial shape: a caller who passes `TypeAccess` read but lacks the write grant gets the route-level constant 403 (the resource is known to them); a caller who fails `TypeAccess` gets the absent answer (INV-5).
- Who grants: the existing permission `EntitiesRestrictionsManage` (TENANT_ADMIN only), through new `write_restrictions` and `write_grants` lists on `POST /restrictions/import`. No new permission, so `effective.golden` is not expected to move; the implementing slice verifies that.
- Existing types and users: no backfill and none needed. The new tables start empty, so with no row anywhere write behaviour is exactly today's. A tenant admin who adds a write restriction must also add the write grants of current writers; the import response reports the users who stop writing.
- Write paths covered: `POST`, `PUT` and `DELETE` on `/records/:entity_type`; `POST /records/:entity_type/import`; the record-attachment write routes (`record_attachments.ex`, which go through `RecordAccess.attachment` and its write counterpart); `StepWrites.check_type_access/2` (subject: the completer on the human path, the activator on a service origin); `HandlerWrites`.
- Left out: definition create and activate (`DefinitionAccess`) stay under `TypeAccess` only, since a definition write is not a record write. `Records` stays ungated.

**Reasons.** Rejected (2): it changes the meaning of existing rows (each existing grant would need a backfill to read-write and a unique-index change, and `import_restrictions/2` upserts against those indexes). Rejected (3): authorisation in tenant-editable JSON that a `PROCESS_DESIGNER` (`EntitiesDefinitionsWrite`) edits is the self-service hole 0051 D6 closes for scope. Option (1) is additive and changes nothing for an existing tenant.

**Source.** `record_access.ex`, `type_access.ex`, `restrictions.ex`, `step_writes.ex`, `handler_writes.ex`, `routers/entities/record_attachments.ex`, `routers/entities.ex`, `effective.golden`, 0050 D7.

**Later tests.** **D2-write-denied** (read access without a write grant is refused on a write-restricted type, on every path listed), **D2-default** (no row: unchanged behaviour), **D2-xtenant** (D1 proof), **D2-managed** (a managed type refuses the import entry).

### D3. Scope declaration for tenant-owned types

**Decision.** The source does not settle this: `ScopeDeclaration` reads manifests only. Options: (a) a core-owned tenant table of declarations (type, kind `column` or `tenant_wide`, field), set only by a tenant-wide TENANT_ADMIN through one new admin-plane route; (b) a fixed `:tenant_wide` for every tenant-owned type; (c) stay `:undeclared`. Chosen: **(a), with (c) as the default until a declaration is set.**

Rules:

- A type with no declaration stays `:undeclared`: a scoped caller gets no data (fail closed). Unscoped callers and tenants with enforcement off are unaffected (0051 D12), so no tenant changes behaviour on deploy.
- The route is admin-plane with a `:tenant_wide` resource scope (0051 D11). A declaration is immutable once set, except by an audited replace.
- A `column` declaration is accepted only if the active definition has a `constraints` entry naming that field, because activation promotes only those fields to indexed columns.
- A tenant cannot declare, widen or remove the declaration of a module-managed type: the route refuses any name for which `ManagedTypes.owner_of/2` or a manifest `:scope_declarations` names it, with the managed 403.
- `ScopeDeclaration.for_types/2` gains a third source (the core table), used only for types no manifest names and no module manages. This is extension (1) in the header.
- The 404 for an out-of-scope record is unchanged (0051 D7).
- Whether the slice re-derives the route-inventory pins for this route is for the slice's design to state; this record does not settle the values.

**Reasons.** Rejected (b): an automatic tenant-wide exemption lets a scoped caller read everything, widening exactly what 0051 D6 forbids. Rejected (c) as the end state: a tenant-owned type would be unusable under enforcement. The table is not the tenant definition JSON, which keeps the point of 0051 D6 (a process designer cannot change who sees what).

**Source.** `scope_declaration.ex`, `managed_types.ex`, 0051 D5, D6, D7, D11, D12.

**Later tests.** **D3-undeclared** (no declaration: scoped caller gets no data), **D3-managed** (a managed type is refused), **D3-xtenant** (route cross-tenant negative, INV-10), **D3-column** (no `constraints` entry: refused).

### D4. Module references by id

**Decision.** A field of a tenant type declares a reference as a pair (module id, entity type) on a string field holding the target `record_id`. On every referencing write (all D2 paths) core calls the module's public lookup and `active?` through the module catalog contract (0050 D2, D3.5) and refuses a dangling, retired or other-tenant target with one generic 422 that does not separate the cases (INV-5). Core never reaches into a module table (0050 D8); it uses the module's public API only. Tenant types hold ids, not snapshots, and a rename never rewrites (0050 D3.1 to D3.4). No FK is promoted: 0050 D3.6 is kept for this record, and the core-run check is extension (2) in the header; FK promotion is left to a later record.

How a module registers a lookup for a tenant type to call is not settled by the source. Q4 below proposes a manifest key `:reference_targets` as explicit per-type opt-in; a module that does not opt in cannot be referenced.

**Reasons.** A reference by immutable id with validation in the owning module keeps module data behind its own API and gives tenants a reference that survives rename and retirement.

**Source.** 0050 D2, D3, D8; `routers/entities.ex` record routes.

**Later tests.** **D4-dangling** (missing, retired and other-tenant targets give the same response), **D4-optin** (a module without opt-in is not a valid target).

### D5. Lookups, related lists, generated lists and forms

**Decision.**

| Need | Route | Why no new data path |
|---|---|---|
| Reference picker | the existing `POST /query` (`EntitiesQuery`, `scope: :filter`) on the target type, projecting `record_id` and display fields | `TypeAccess` read, field authorisation (INV-2) and the scope filter of the target type apply by construction |
| Related list | the same query with an equality filter on the reference field | same |
| Generated list and form | none; derived by the web client from the active definition | no server data path |

"Generated" means derived from the active definition only (field order, types, constraints, enum values, reference targets). No stored layout overrides exist in this item. Per-tenant form, list and print-template overrides are out of scope (REQ-550, [0067](0067-tenant-x-extension-layer-over-module-entity-types.md) D1 "Override kinds split", [0068](0068-per-tenant-print-template-overrides.md)). A new route is added only if the query path cannot return the display subset; none is expected.

**Reasons.** Reusing `/query` means a picker cannot show a user a record or field the user could not read otherwise.

**Source.** `routers/entities.ex` (`POST /query`), 0050 D3, 0067 D1, 0068.

**Later tests.** **D5-picker** (a picker never returns a field or record the caller cannot read), **D5-related** (the related list honours scope).

### D6. Implementation slices and order

None is filed or built here. Each is its own requirement, with `depends_on` this record; SECURITY-REVIEWER is a mandatory gate for each (tenant data, INV-1, INV-2, INV-10).

1. **Slice A, write permission (D2).** Migration with two tables (the tenant table-list pin and its count move), the `RecordAccess`, `StepWrites` and `HandlerWrites` gate, the import lists, route pins re-derived.
2. **Slice B, scope declaration (D3).** Table, admin-plane route, `ScopeDeclaration` third source. Also depends on REQ-517 to REQ-519. The slice re-derives the route-inventory pins.
3. **Slice C, module references (D4).** Manifest key and the core check on writes. Also depends on the 0050 module slices.
4. **Slice D, web (D5).** Reference picker, related list, generated list and form. Depends on A, B and C.

Order: A and B are independent and either may go first; then C; then D.

## Open owner questions

1. **Q1 Scope declaration route (D3).** Recommended: (a) core table, set by TENANT_ADMIN, `:undeclared` default. Alternatives: (b) fixed tenant-wide, rejected above; (c) never declare.
2. **Q2 Write model (D2).** Recommended: option (1), second table pair. Alternatives: (2) mode column, (3) definition JSON.
3. **Q3 Permission for write grants (D2).** Recommended: reuse `EntitiesRestrictionsManage`. Alternative: a new permission, which also moves `effective.golden` and the tenant-auditor refused set.
4. **Q4 Reference registration (D4).** Recommended: manifest key `:reference_targets`, opt-in per module type.

## Tests the implementation slices must add

D2-write-denied, D2-default, D2-xtenant, D2-managed, D3-undeclared, D3-managed, D3-xtenant, D3-column, D4-dangling, D4-optin, D5-picker, D5-related (placement in D6 by slice: A has D2-*, B has D3-*, C has D4-*, D has D5-*), plus the INV-6 two-tenant proof per path named in D1.

## Threats for SECURITY-REVIEWER

- A write grant leaking across tenants, or a restricted type writable without a grant on any path in D2 (INV-1, INV-5).
- A tenant declaring or widening the scope of a module-managed type, or a tenant-wide declaration exposing records to a scoped caller (D3; 0051 D6).
- A reference check that reveals whether another tenant's or a retired record exists (D4; INV-5).
- A picker or related list returning fields or records beyond the caller's read access (D5; INV-2).
- Existing writers losing access silently when a write restriction is added (D2).

## Sign-off

- SECURITY-REVIEWER: pending, not yet reviewed (content of D1, D2, D3, D4).
- REVIEWER: pending, not yet reviewed.
