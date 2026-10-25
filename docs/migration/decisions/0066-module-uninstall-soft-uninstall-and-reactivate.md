# 0066 -- Module uninstall: a soft, reversible, per-tenant status change; data, definitions and the `managed_by` stamp are kept; running work blocks it; hard purge is out

Status: PROPOSED by the developer of GH #3172 (REQ-549 slice 0, task T-0495), 2026-10-25. Needs SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice is its own requirement (D8).

Date: 2026-10-25

Amends: [0039](0039-platform-module-solution-layering.md) D5. The one sentence replaced is the bullet that begins **"No uninstall in S11."** (full text: "Removing a module safely means deciding what happens to its definitions and tenant data; that is not decided here. S11 builds install and list only. Uninstall is an open item in the stage file."). It is replaced by the rule of this record: uninstall exists as a soft, reversible status change (D1, D2). Until this record is ratified, 0039 D5 "No uninstall in S11" stands (core roadmap Wave 3 row; 0055 header).

What of 0039 D5 stays unchanged: the per-tenant install and its `tenant_modules` table (the row is kept, a status column is added, D1); the `depends_on` check at install; the installed pack and `on_install` in one transaction; `404`, not `403`, for a request to `/api/v1/modules/<id>/...` of a module that is not installed (an uninstalled module gets the same `404`); `:ModulesManage` gating install and settings writes; the SPA building routes and navigation from `GET /me` (an uninstalled module disappears from it, D5).

Also contradicts: REQ-549 text and 0039 D5 on who holds `:ModulesManage` (D6).

Depends on: [0039](0039-platform-module-solution-layering.md) (D5, R4); [0050](0050-foundation-modules-org-catalog-and-reference-contract.md) (D7, `managed_by`); [0055](0055-module-upgrade-migration-uninstall.md) (D1, D10, D11, open points 6, 9, 15); REQ-496 (GH #2530, `managed_by`, delivered, merge 4a911d40e).

## Sources

Opened for this record (all on `origin/main` at 2026-10-25):

- `docs/migration/core-roadmap-20261014.md`, Wave 3 row "Module uninstall".
- `docs/migration/decisions/0039-platform-module-solution-layering.md`, D5 and R4 (R4: "check dependents; keep data and definitions; remove the row only").
- `docs/migration/decisions/0055-module-upgrade-migration-uninstall.md`, D1 (journal `tenant_module_upgrades`), D10 (audit), D11 (the four constraints), facts 3, 11, 12, open points 6, 9, 15.
- `docs/migration/decisions/0050-foundation-modules-org-catalog-and-reference-contract.md`, D7 (`managed_by` write lock).
- `lib/letflow/modules/installs.ex` (`list_installed/1`, `installed?/2`, `module_installed?/2`, `installed_manifest_hash/2`, `install/3`, `fetch_rationale/1`).
- `lib/letflow/modules/tenant_module.ex` (columns `module_id, version, installed_at, settings, manifest_hash`; no status column).
- `lib/letflow/entities/handler_writes.ex` (`owner_recheck/3` and the comment above it), `lib/letflow/entities/managed_types.ex` (`refuse_reserved_first_creation/2`), `lib/letflow/modules/exam/exam.ex` (`on_install/2` seeding `entity_field_restrictions`), `lib/letflow/routers/tenant_modules.ex`, `docs/roles.md` (`ModulesManage`).
- `docs/requirements.yaml`, REQ-549.

## Open owner questions (not settled here)

**OQ-1. Data retention.** How long a tenant's records, events and definitions of an uninstalled module are kept before any purge, and whether a hard purge exists at all, is a legal and business rule the sources do not give (0039 and 0055 are silent; 0063 covers versioned documents only). Options:

1. keep until a platform admin purges;
2. keep for a fixed period set by the owner;
3. purge on uninstall.

Recommendation: keep, soft uninstall only (option 1 with no purge act built). No implementation slice that deletes tenant data is written until the owner answers (D8). D1 and D2 refer here for "how long".

**OQ-2. Second approver** for uninstall of a module with live data (0055 open point 6). Until the owner rules otherwise: one approver (D6).

## D1. What uninstall removes and what it keeps

**Decision.** Uninstall removes nothing from the tenant's data. It removes the module from reach and from lists, and refuses new work. Every row below is decided; only the retention period of data points to OQ-1.

| # | Item | Removed or kept | For how long |
|---|---|---|---|
| 1 | The module's router and screens | Removed from reach: `/api/v1/modules/<id>/...` answers `404`, byte-identical to a never-installed module (0039 D5); the SPA gets no entry from `GET /me` (D5) | While status is `uninstalled`; restored by reactivate |
| 2 | `tenant_modules` row | **Kept; a `status` column is added** (`active` or `uninstalled`, `Ecto.Enum`, default `active`). The row is not deleted | While the module is installed or uninstalled; the row goes only with a hard purge (out, D2) |
| 3 | Process definitions, variable schemas and entity definitions installed from the pack (the closed artefact set; packs have no separate form artefact, 0055 fact 6) | Kept, nothing deactivated or deleted. Process definitions cannot start new instances (D4); entity definitions stay active | Retention period: OQ-1 |
| 4 | Entity records and their event history | Kept untouched; readable only as D3 says | Retention period: OQ-1 |
| 5 | Process instances and tasks of the module's definitions | Kept. Uninstall is refused while any is open (D4); finished ones stay as history | Retention period: OQ-1 |
| 6 | Module settings (`tenant_modules.settings`) | Kept unchanged; not readable or writable through the module while uninstalled (`put_settings` is refused as for a not-installed module); restored by reactivate | While the row exists |
| 7 | `managed_by` stamp on the module's entity types | **Kept**, so generic writes stay refused with the uniform `403` after uninstall (0050 D7). On a hard purge only (out of this record) the stamp leaves with the type definition it belongs to; a purge never clears a stamp and keeps the type | Same as row 3 |
| 8 | Permissions and role grants the module added | Nothing to remove: grants are code-global, not tenant rows (0055 fact 3). The module's routes are unreachable (row 1) so its permissions grant nothing in this tenant. The `entity_field_restrictions` rows `on_install` seeded are kept (D3) | Until a hard purge (out) |
| 9 | Secrets the module references | Kept; no secret is deleted, rotated or read by uninstall (INV-4). Module code does not run, so nothing resolves them | While the row exists |
| 10 | Installed version (`version`, `manifest_hash`) | Kept as at the time of uninstall, so reactivate can detect a code change (D2) | While the row exists |

**Status column versus deleting the row (0055 open point 15).** Decision: a `status` column, the row is kept. Reasons: (a) reactivate needs the installed `version` and `manifest_hash` (row 10) and the settings (row 6); a deleted row loses them and makes reactivate indistinguishable from a fresh install, which can skip an upgrade; (b) `module_installed?/2` is shared by the install dependency check and by `installed?/2` (`installs.ex`), and a status makes the "active" meaning explicit instead of implicit in row existence; (c) 0039 R4's "remove the row only" is the direction tested; it was rejected because of (a). The column belongs to the implementation migration and is registered in the tenant provisioning list (D7).

**Run-time recheck.** `owner_recheck/3` in `lib/letflow/entities/handler_writes.ex` decides "installed and enabled" by row existence only (its comment: "Uninstall (decision 0055) must delete the row or add a status this function then checks"). Under this record `Installs.installed_manifest_hash/2` returns `{:error, :not_installed}` for a row whose status is `uninstalled`, exactly as for a missing row, so `owner_recheck/3` rejects an uninstalled module's write handler and the step is refused with the existing `module_write_module_not_installed` reason. The same status check applies to `installed?/2`, `list_installed/1` and `put_settings/3`.

**Test a later slice must add (slice 1, D8).** In `test/letflow/engine/module_write_runtime_stamp_test.exs`, next to "a module that is no longer installed is refused: module_not_installed" (which deletes the row): a test named "a write handler of an uninstalled module is refused", which sets `status: :uninstalled` on the row (the row still exists), runs a module write line and asserts the refusal `module_not_installed` with no record written.

Source: 0039 R4; 0055 D11 and open point 15; `handler_writes.ex` `owner_recheck/3`; `installs.ex`; `tenant_module.ex`; 0050 D7.

## D2. Soft uninstall and reactivate

**Decision.** Uninstall is reversible. It sets `status` to `uninstalled` in one transaction (with the audit entry and journal row, D6, D7). Reactivate sets it back to `active`; it restores reach (D1 row 1), list visibility (D5) and the module's ability to take new instances (D4). It restores nothing else, because nothing else was removed.

- **Version is kept.** Reactivate is refused with `{:error, :upgrade_required}` when the row's `manifest_hash` differs from the compiled manifest hash (`Catalog.manifest_hash/1`) or the row has no hash (a module installed before the column existed). This is the same comparison `owner_recheck/3` uses. A reactivate therefore cannot skip an upgrade (0055). The module upgrade runner and its fleet driver (0055 D12) skip rows whose status is `uninstalled`; upgrading and then reactivating is the path. Until the upgrade runner exists, a module whose code changed while uninstalled stays uninstalled.
- **Reactivate preconditions:** every `depends_on` module is `active` (same check as install), `:ModulesManage` rules of D6, mandatory rationale.
- **Hard purge is out of this record.** No purge act is decided or built. If the owner answers OQ-1 with a purge, it is a new record (it deletes tenant data: 0055 D8.1 forbids a lossy step except through an explicit purge act with its own record) and its own slice.

Reasons: data and definitions are the tenant's; deleting them is the one irreversible action and needs the owner's retention rule (OQ-1); a status change gives every recovery path for free.

Source: 0039 R4; 0055 D8.1, D11; REQ-549 D2.

## D3. Orphaned-data reads

**Decision.** The read rule chosen: **keep exactly the pre-uninstall `TypeAccess`, `entity_field_restrictions` and ownership filters**; uninstall adds no read path and no widening. After uninstall the module's records are reachable only through the generic entity routes, under the same `TypeAccess` rules (`lib/letflow/entities/type_access.ex`) and the same `entity_field_restrictions` rows that applied before; module-private routes and their ownership filters (for example the exam session `:not_owner` check in `lib/letflow/modules/exam/anti_cheat.ex`) are gone with the router and expose nothing. No named "orphan read" permission is created: restricting to a new permission would be a new read path whose scoping must be proven (INV-6), and nothing needs it.

**INV-2 property for the exam answer keys (a later test must prove).** Uninstall never deletes or edits an `entity_field_restrictions` row (D1 row 8). Property: for a caller with TASK_WORKER scope, `POST /entities/query` and `POST /entities/query/aggregate` on the exam question type return the same response (answer-key fields absent) before and after uninstall, and after reactivate; the count of `entity_field_restrictions` rows for the exam types is the same in all three states; no route returns another user's exam session.

**INV-5.** A caller who may not read the module's data gets `not-found`, indistinguishable from forbidden and from an unknown type or record: the response to a read of a type or record the caller has no access to is byte-identical to the response for a record that does not exist. Uninstall does not introduce a distinguishable reply (no "module uninstalled" error to a non-authorised caller).

Source: 0055 D11 bullet 2; `exam.ex` `on_install/2`; `type_access.ex`; security-invariants INV-2, INV-5, INV-6.

## D4. Running work

**Decision.** Uninstall is refused while open work exists; new work is refused after.

| Case | Resulting state | Reason shown to the caller |
|---|---|---|
| Request to start a NEW instance of a process definition owned by the module (rule below) | No instance, no event, no task is created | Uniform `404` not-found, byte-identical to an unknown definition, to every caller: a module's absence is not information to leak (0039 D5, INV-5). The cause (`module_uninstalled`) goes to the server log and the audit trail only |
| An OPEN instance of the module's definitions at uninstall time | Uninstall is refused; the instance continues to run untouched. It is not cancelled and not suspended | To the uninstaller (who holds the authority, D6): `409` with stable code `open_work_exists` and counts of open instances and open tasks only, no ids |
| An OPEN task of those instances | Same refusal; the check counts open tasks and open instances | Same as above |
| A process step that writes a module-managed type (0054 step-writes-entity) after uninstall | The write is refused by `owner_recheck/3` (D1); no record is written; the step fails by the existing step-failure path | The existing stable reason `module_write_module_not_installed`. It arises for an instance of a process that is NOT the module's own (the module's own instances were blocked above) |


**Which definitions are the module's (rule).** A definition version belongs to a module when its `process_definitions.owner_module` column (stamped only by `Definitions.create_owned/3` during a module install, `lib/letflow/definitions/owner_stamp.ex`) equals that module id. A start is refused when the definition version the start would pin has `owner_module` set to a module whose `tenant_modules` row has status `uninstalled`. **Later versions made by the tenant:** a version of the same definition name that the tenant created or edited carries no stamp (`owner_module` is NULL), so it is NOT blocked and starts normally; the tenant owns it. Uninstall never blocks by definition name, only by the stamp, and the ownership of a stamped version is not transferred. Reactivate makes stamped versions startable again.

**Open work (the `open_work_exists` precondition) uses the same rule:** an open instance counts when the definition version it is pinned to has `owner_module` equal to the module; an open task counts when it belongs to such an instance. Instances pinned to an unstamped tenant version of the same name are not counted and do not block uninstall.
Concurrency: the start path takes the `tenant_modules` row `FOR SHARE` and uninstall takes it `FOR UPDATE`, so a start and an uninstall serialize on Postgres row locks (no process per instance, REQ-045). The lock order against the engine locks is checked against 0061 in slice 2 (D8); a violation is a defect of that slice, not a reason to change this decision. Definition activation that carries a module-write line of an uninstalled module is already refused (`module_write_module_not_installed`, `module_write_activation_test.exs`).

Reasons: cancelling work destroys tenant data and has no undo; blocking leaves the choice with the admin, who finishes or cancels instances through the existing instance routes first.

Source: 0055 D11 bullet 1; 0054; `handler_writes.ex`.

## D5. Visibility and dependency

**Decision.**

1. `GET /me` and `Installs.list_installed/1` list only `active` modules; an uninstalled module is absent (0055 D11 bullet 3, fact 12; `lib/letflow/routers/me.ex`). No route lists uninstalled modules in this record; the uninstall and reactivate calls take the module id.
2. An uninstalled module does NOT satisfy another module's `depends_on` at install: the shared `module_installed?/2` means "row exists and status is `active`.
3. Uninstall is refused while an `active` module depends on it: `409` `dependents_installed` with the dependent module ids (to the authorised uninstaller). Reactivate of a module whose own dependency is uninstalled is refused likewise.
4. 0055 D11's fourth constraint (depends_on satisfaction) is answered by item 2; new instances blocked by D4; orphaned reads by D3; `GET /me` and `list_installed` by item 1.

Reasons: a hidden module that still satisfied a dependency would let a module run on top of one that is out of reach; the shared helper is changed in one place.

Source: 0055 D11 bullets 1-4; `installs.ex` `module_installed?/2`, `check_dependencies_installed/2`.

## D6. Authority and audit

**Decision.**

- **Who (decided).** Uninstall and reactivate are tenant-scope routes, gated by the existing `:ModulesManage` permission, exactly like install (`routers/tenant_modules.ex`; `docs/roles.md` matrix row `ModulesManage`: `TENANT_ADMIN` and the platform tenant's `PLATFORM_ADMIN`; 0055 fact 11). No new permission and no platform-operator gate is added. `PLATFORM_ADMIN` exists only in the platform tenant (roles charter), so its use of the route acts only on the platform tenant's own modules; a customer tenant uninstalls through its own `TENANT_ADMIN`. **Contradiction recorded:** REQ-549 and 0039 D5 word `:ModulesManage` as PLATFORM_ADMIN only; main's roles matrix gives it to `TENANT_ADMIN` too, and a PLATFORM_ADMIN-only rule cannot be combined with the tenant-from-auth-context rule below (it would let no customer tenant uninstall). This record follows the roles matrix and the install route; the REQ-549 wording is superseded on this point. The extra safeguards that make this acceptable for a tenant admin are the mandatory rationale, the refusal while open work or dependents exist (D4, D5), the audit entry, and the flag default off. A platform operator uninstalling on behalf of a named customer tenant would be a platform-scope route that takes a tenant id; it is not decided here, would need its own record, INV-10 handling and an owner decision, and is out of the slices of D8.
- **Tenant from the auth context.** The route carries no tenant id in the path, query or body; the tenant prefix comes only from `conn.assigns.scoped_opts`, which comes from `auth_context.tenant_id`, as `install` does (INV-1, 0055 D8.5). A cross-tenant negative test (INV-10) is required in the first implementation slice: uninstalling a module in tenant A changes nothing in tenant B (B's `tenant_modules` row, `GET /me`, routes, data), and a body or header carrying B's tenant id is ignored.
- **Approval.** One approver with a mandatory non-blank rationale (reuse `Installs.fetch_rationale/1`), as 0055 open point 6 fixed for now. A second approver for a module with live data is OQ-2, not settled here.
- **Audit.** A hash-chain audit entry is written in the same transaction as the status change (`Audit.append_multi/4`, as 0055 D10): module, from/to status, actor, rationale verbatim, counts only, never record content. A failed audit write rolls back the status change.

Source: 0039 D5; 0055 D10 and open point 6; `routers/tenant_modules.ex`; `docs/roles.md`; security-invariants INV-1, INV-10.

## D7. Journal and migration

**Decision.** The implementation migration (never in this record) adds `tenant_modules.status` (`Ecto.Enum` `active|uninstalled`, `NOT NULL`, default `active`) and, once the 0055 D1 journal exists, adds the `kind` values `uninstall` and `reactivate` to `tenant_module_upgrades` (0055 D1: "added by the uninstall record"). Both are registered in the tenant provisioning migration list in `lib/letflow/tenant_provisioning.ex` so new tenants get them (INV-1(b)). **Existing rows:** every existing `tenant_modules` row becomes `active` (the column default; no backfill rewrite needed and no module changes visibility at deploy). The migration is already live on QA by auto-CD when it merges (`cd.yml`); the default makes that deploy a no-op for tenants. Uninstall writes a journal row of `kind: uninstall` (reactivate `kind: reactivate`) with actor and rationale, in the same transaction as D6.

Source: 0055 D1, D11 last bullet; `tenant_provisioning.ex` migration list.

## D8. Implementation slices

Each slice is its own requirement, sized to one change, depends on REQ-549 (this record, once ratified) and REQ-496, and has SECURITY-REVIEWER as a mandatory gate (every slice touches the tenant-data path). New flag `modules_uninstall_enabled` defaults off (new flags default off); it is turned on only after slice 2 has merged.

| Slice | Content | depends_on | Tests |
|---|---|---|---|
| 1 | Migration for `status` (+ provisioning registration, existing rows `active`); `Installs` semantics (`installed?/2`, `list_installed/1`, `installed_manifest_hash/2`, `put_settings/3`, `module_installed?/2`); `uninstall/3` and `reactivate/3` with audit (D6) and `upgrade_required` (D2); routes behind the flag | REQ-549, REQ-496 | U1 module route `404` after uninstall, identical to never-installed; U2 `GET /me` hides it; U3 the D1 recheck test "a write handler of an uninstalled module is refused"; U4 reactivate restores reach; U5 reactivate refused with `upgrade_required` on hash mismatch; U6 dependents refuse uninstall (`dependents_installed`) and an uninstalled module does not satisfy `depends_on`; U7 a role without `:ModulesManage` gets `403` (and the same for reactivate), blank rationale refused; U8 audit entry in the same transaction (rollback on failure); U9 **INV-10 cross-tenant negative test**; U10 provisioning list contains the migration (`tenant_provisioning` test) and existing rows read `active` |
| 2 | Open-work precondition (`open_work_exists`), new-instance block with uniform `404`, row-lock serialization of start vs uninstall (checked against 0061) | REQ-549, REQ-496, slice 1 | W1 open instance refuses uninstall; W2 open task refuses; W3 start after uninstall is `404` identical to unknown definition; W4 step write of a managed type fails with `module_write_module_not_installed`; W5 race: start and uninstall serialize (race-only, not forceable without a hook; stated, not skipped silently) |
| 3 | Orphaned-read proof: tests that pin D3 (no code change expected; fixes only if a test fails) | REQ-549, REQ-496, slice 1 | R1 answer-key property of D3 before/after uninstall/reactivate; R2 `entity_field_restrictions` row count unchanged; R3 outsider reply byte-identical to not-found (INV-5) |
| 4 | Journal kind values `uninstall` and `reactivate` in `tenant_module_upgrades` (+ provisioning registration) | REQ-549, REQ-496, slice 1, and the 0055 D1 upgrade-journal requirement (no REQ id yet; added when that requirement is registered) | J1 journal row written with the transition; J2 kinds registered for new tenants |
| 5 | SPA admin screen to uninstall/reactivate | REQ-549, REQ-496, slice 2 | frontend unit tests; `npm run check` |
| not written | Hard purge | needs the owner's answer to OQ-1 and a new record | none: no slice that deletes tenant data exists until then |

## Consistency with existing decision records

- 0039: D5 amended as stated in the header; the 404 rule, per-tenant install and `:ModulesManage` for install are kept; R4's "remove the row only" is replaced by "keep the row, add a status" (D1).
- 0050 D7: `managed_by` stays on after uninstall (D1 row 7).
- 0055: D11's four constraints are answered (D3, D4, D5); open points 6 (OQ-2) and 15 (D1) are answered or carried; the journal kinds are D7. D8.1 (no lossy step outside an explicit purge record) is kept (D2).

## Not decided here

- Data retention and any hard purge (OQ-1); a second approver (OQ-2).
- The exact error status numbers beyond those named; a platform-scope operator uninstall naming a customer tenant (D6).
- The upgrade runner and the tenant `x_` layer.

## Threat cases for SECURITY-REVIEWER

1. Cross-tenant uninstall or reactivate through a tenant id in the body, path or header (INV-1, INV-10).
2. A role without `:ModulesManage`, or a caller of tenant A acting on tenant B, uninstalling a module (D6).
3. A distinguishable reply revealing an uninstalled module to an outsider (INV-5).
4. Exam answer keys readable after uninstall (INV-2, D3).
5. A write handler or process step writing a module-managed type after uninstall (D1 recheck, D4).
6. Reactivate skipping an upgrade or restoring a stale module version (D2).
7. Start-versus-uninstall race creating an instance of an uninstalled module (D4).

## Sign-off

- SECURITY-REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
- REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
