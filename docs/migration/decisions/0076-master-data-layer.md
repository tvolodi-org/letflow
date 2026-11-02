# 0076 -- Assets A0 master data layer: ownership, storage rules, isolation, and read contract

Status: PROPOSED by CODE-DESIGNER for REQ-642 / GH #3582 (task T-1098), 2026-11-02. Not binding until REVIEWER or owner sign-off. Decision number check at implement time: highest on `origin/main` and open `origin/team/*` branches is 0075, so 0076 is free.

Date: 2026-11-02

Related: REQ-642 (GH #3582), REQ-643, REQ-644, REQ-645, REQ-646, REQ-647, REQ-648, REQ-649, REQ-660, REQ-665, REQ-666, REQ-667, REQ-668, REQ-674; decisions 0006, 0023, 0050, 0051, 0073.

This record writes no code, migration, route, permission, seed, or test. It defines the phase A frame only.

## Sources

- Owner decisions D-060, D-061, D-062, D-063 (2026-10-31), `ai-dala-portfolio/DECISIONS.md`
- `ai-dala-portfolio/architectures/assets.md` (sections "Three modules and one common layer", "The two trees")
- `letflow-team/project/assets-gap-analysis.md` (section 2, risk 5)
- Owner decision D-066 (2026-11-02, "Storage of trees and master data"), `ai-dala-portfolio/DECISIONS.md`
- `letflow-team/project/tree-and-master-data-storage.md` (sections a..d)
- Owner decision D-067 (2026-11-02, "Access model for the assets application"), `ai-dala-portfolio/DECISIONS.md`
- `letflow-team/project/assets-access-model.md` (sections 0, 4, 6)
- `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` (D2)
- `docs/migration/decisions/0023-entity-storage-hybrid.md` ("The promotion rule")
- `docs/migration/decisions/0050-foundation-modules-org-catalog-and-reference-contract.md` (D1, D2, D3, D6, D7, D8 and D-066 amendment)
- `docs/migration/decisions/0051-org-scoped-role-grants-and-enforcement.md` (D1, D2, D3, D6, D7, D11, M4)
- `docs/migration/decisions/0073-domain-neutral-ledger-primitive.md` (D6, OQ-R4 facade dependency)
- `lib/letflow/modules/org/org.ex`
- `lib/letflow/modules/locations/locations.ex`
- `lib/letflow/modules/catalog_items/catalog_items.ex`
- `lib/letflow/modules/read_api.ex`
- `lib/letflow/scope_node_paths.ex`
- `lib/letflow/entities/definition/ddl.ex`
- `lib/letflow/entities/query/compiler.ex`
- `lib/letflow/entities/scoped_lookup.ex`
- `lib/letflow/tenant_provisioning.ex`
- `lib/letflow/modules/exam/parent_rollout.ex`
- `lib/mix/tasks/letflow.check_boundaries.ex` (Rule 4 direction)

## Context on main

The "common master data" of D-061 currently lives in foundation modules (0050 D1), not in WMS or Assets modules:

- `org`: `org_legal_entity`, `org_site`, `org_unit`, `org_unit_membership`
- `locations`: `location_node`
- `catalog_items`: `catalog_item`, `catalog_uom`, `catalog_counterparty`

The org scope path index is `scope_node_paths`, written by `Letflow.ScopeNodePaths.write/2`.

## Rulings

### R1. Ownership and module direction

The master data layer is the set of foundation modules `org`, `locations`, `catalog_items`, and `codes` (new), extended in place. It is **not** a single replacement module.

Reason: replacing existing master types with one new module would change both the prefixed type names (0050 D6) and immutable `managed_by` stamps (0050 D7) of deployed types.

Ownership table:

| Area / type family | Owning module | Why / note |
|---|---|---|
| Employees | `org` | D-061: employees are records, not user accounts |
| Positions | `org` | 0050 D1 already positions org under foundation |
| Org-unit-to-location link | `locations` | Keeps tree coupling local to locations; answers REQ-625 open item 6 |
| Codes (barcode/QR/RFID text) | `codes` | New foundation module; target stays declarative (type + id), validated in code |
| Units of measure | `catalog_items` | Common catalog master data |
| SKUs | `catalog_items` | Common catalog master data |
| Lots | `catalog_items` | Common catalog master data |
| Organization tree | `org` | Scope tree remains org-scoped; path index is the core `scope_node_paths` table |
| Location tree | `locations` | Independent tree, parent-link storage |

Dependency direction:

- `locations` depends on `org`
- `codes` depends on nothing
- no master-data module depends on WMS, Assets, or procurement
- consumers (WMS/Assets/procurement) depend on master-data modules, never the reverse (boundary Rule 4)

### R2. Storage per tree (D-066)

The two trees do **not** share one algorithm.

1. **Org tree keeps materialised path** in `scope_node_paths`, written only by `Letflow.ScopeNodePaths.write/2`.
2. **Bound is 40** (A2 / REQ-649). Derivation:
   - btree entry limit: 2704 bytes
   - max node id: 64 bytes (`@max_node_id_bytes` in `scope_node_paths.ex`)
   - path length upper bound: `1 + 65 * d`
   - at depth 40: `1 + 65 * 40 = 2601` bytes
   - with uuid ids (36 bytes): about `2704 / 37 ≈ 72` levels fit
   - therefore "12" from 0051 D3 was a recommendation, not a physical limit, and is superseded
3. **Ancestor array (`uuid[]` + GIN)** is recorded as a later option only; not built in phase A.
4. **Location tree uses parent link only**:
   - `location_node.parent_id` promoted column
   - real foreign key to `location_node` inside locations pack
   - indexed
   - no stored ancestor path
   - no stored depth
   - no depth bound
   - subtree read by recursive query over `parent_id`
   - cycle/move/retire rules enforced in module write functions (A3a/A3b)
5. No shared tree-path helper module is introduced.
6. Location tree never writes `scope_node_paths` and locations are never scope nodes of 0051.

### R3. Tree independence and tenant isolation

Independence rules:

1. No shared table between org tree and location tree.
2. No shared entity type between org tree and location tree.
3. A4 link is the only cross-tree read.
4. Org unit and location are separate references on business rows; one is never derived from the other.

Isolation rules:

5. Master rows live only in tenant schemas and are reached by authenticated-tenant prefix (INV-1).
6. No `tenant_id` column in tenant-schema tables (0006 D2).
7. Links and code assignments may target records only within the same tenant schema.
8. Read prefix comes from authenticated tenant context, never request input.
9. A future route that takes tenant identifier must include INV-10 cross-tenant negative test.

### R4. Read contract for consumers (WMS, Assets, procurement)

1. Consumers read master data only through owning-module read API under their own `depends_on`:
   - `lookup/2`
   - `active?/2`
   - `org.member?/3`
2. References are immutable record ids, never business codes (0050 D3.1).
3. Ledger master checks remain owed to 0073 slice L7 through the OQ-R4 facade; not built by this record.
4. No new read function names are introduced in this record as currently-available API.
   - `resolve/2` (codes) and `active_employee?/2` (employees) are future functions owed to their owning phase-A entries; they are not treated as present-on-main here.

### R5. Change table (existing artefacts)

Each row states unchanged vs planned change and how existing QA tenants are handled.

| Artefact | Status in A0 | Change owner entry | Existing QA tenants handling |
|---|---|---|---|
| `org_legal_entity` | Unchanged in phase A | — | Not upgraded in phase A; upgrade slice owed later |
| `org_site` | Unchanged in phase A | — | Not upgraded in phase A; upgrade slice owed later |
| `org_unit` | Unchanged in phase A | — | Not upgraded in phase A; upgrade slice owed later |
| `org_unit_membership` | Unchanged in phase A | — | Not upgraded in phase A; upgrade slice owed later |
| `location_node.node_kind` | Unchanged in A3a/A3b unless later requirement amends | A3 (REQ-645/646) if changed | Existing installs not upgraded automatically |
| `location_node.org_site_id` | Planned removal | A3a (REQ-645) | Existing installs not upgraded automatically |
| `location_node.parent_id` | Planned promoted FK + index; no path/depth fields added | A3a (REQ-645) | Existing installs not upgraded automatically; upgrade slice owed |
| `location_node.location_type` | Unchanged unless A3 amends | A3 (REQ-645/646) if changed | Existing installs not upgraded automatically |
| `catalog_item` | Extended for A6a (SKU context) | A6a (REQ-647) | Existing installs not upgraded automatically |
| `catalog_uom` | Extended for A6a | A6a (REQ-647) | Existing installs not upgraded automatically |
| `catalog_counterparty` | Unchanged by current A6a scope | — | Existing installs not upgraded automatically |
| `Letflow.ScopeNodePaths` | Path storage unchanged; bound set to 40 | A2 (REQ-649) | Existing installs not upgraded automatically |

Cross-row rule for every changed row above:

- decision 0055 module upgrades are not built on main
- module install is first-install only
- therefore changed definitions/keys reach fresh installs only
- phase A is tested on freshly provisioned tenants
- upgrade slices for already-installed tenants are owed later

### R6. Master-data storage rule (D-066 + 0023; supersedes 0050 D3.6 for new/changed phase-A types)

Master data stays in managed entity types. Hand-written tables are reserved for data that is not records (for example ledger postings and `scope_node_paths` security index).

Numbered rules:

1. Standard fields are queried (real typed columns).
2. Same-pack references are `foreign_keys` and become promoted uuid columns with `REFERENCES ... ON DELETE RESTRICT`.
3. Same-pack references include an index unless already covered by a leading unique key.
4. Business codes / unique keys are unique constraints (unique indexes).
5. Cross-pack references and any-type references remain declarative ids validated in write logic through owning-module read API (`lookup/2`, `active?/2`).
6. Columns remain nullable; requiredness is validator-level.
7. FK proves row existence only; active-state and business constraints remain module-write checks.
8. In each `pack.json`, referenced types come before referencing types.

Keys per entry:

| Type | Field | Target | Form | Owning entry |
|---|---|---|---|---|
| `org_position` | `org_unit_id` | `org_unit` | FK in same pack | A1 / REQ-643 |
| `org_employee` | `org_unit_id` | `org_unit` | FK in same pack | A1 / REQ-643 |
| `org_employee` | `position_id` | `org_position` | FK in same pack | A1 / REQ-643 |
| `location_node` | `parent_id` | `location_node` | FK in same pack | A3a / REQ-645 |
| `location_org_unit_link` | `location_id` | `location_node` | FK in same pack | A4 / REQ-644 |
| `location_org_unit_link` | `org_unit_id` | `org_unit` | Declarative, checked in code | A4 / REQ-644 |
| `code_assignment` | `code_id` | `code_tag` | FK in same pack | A5 / REQ-648 |
| `code_value_change` | `code_id` | `code_tag` | FK in same pack | A5 / REQ-648 |
| `code_assignment` / `code_value_change` | target reference | any target type | Declarative, checked in code | A5 / REQ-648 |
| `catalog_lot` | `item_id` | `catalog_item` | FK in same pack | A6a / REQ-647 |

Upgrade path for already-deployed tenants:

- New keys reach fresh installs only.
- Installed tenants keep current definitions until module-upgrade slices are built.
- Upgrade shape is `Letflow.Modules.Exam.ParentRollout` style: per-tenant transaction under schema lock, dry-run, idempotent, promote columns and create constraints atomically.
- Where a deployed column type must change (for example text to uuid), additive-only promotion blocks direct change (`{:error, {:column_type_conflict, ...}}`), so upgrade slice must use copy-forward/versioned-table approach.
- No phase-A entry builds these upgrade slices.
- Existing org types (`org_legal_entity`, `org_site`, `org_unit`, `org_unit_membership`) keep declarative-string references in phase A.

### R7. Visibility model (D-067)

Grant model stays 0051:

- One function = one group with one `role_scope_grants` row per covered unit.
- A named "scope set" abstraction is not built in phase A; if needed later, it requires its own amendment of 0051 D1.
- No new reader role is added.

Visibility is declared in module manifests through `:scope_declarations`:

- `:tenant_wide`
- `{:column, "org_unit_id"}`
- undeclared (scoped callers see none)

VISIBILITY TABLE:

| Type | Visibility class | Declaring entry |
|---|---|---|
| `org_legal_entity` | tenant-wide | A1 / REQ-643 |
| `org_site` | tenant-wide | A1 / REQ-643 |
| `org_unit` | tenant-wide | A1 / REQ-643 |
| `org_position` | scoped by org unit | A1 / REQ-643 |
| `org_employee` | scoped by org unit | A1 / REQ-643 |
| `org_unit_membership` | undeclared (open question) | — |
| `location_node` | tenant-wide | A3a / REQ-645 |
| `location_org_unit_link` | scoped by org unit | A4 / REQ-644 |
| `catalog_item` | tenant-wide | A6a / REQ-647 |
| `catalog_uom` | tenant-wide | A6a / REQ-647 |
| `catalog_counterparty` | tenant-wide | A6a / REQ-647 |
| `catalog_lot` | tenant-wide | A6a / REQ-647 |
| `code_tag` | tenant-wide | A5 / REQ-648 |
| `code_assignment` | tenant-wide | A5 / REQ-648 |
| `code_value_change` | tenant-wide | A5 / REQ-648 |
| Asset cards, receipt/transfer/count documents | scoped by org unit | Later Assets entries |
| Balances and movements | scoped by ledger scope slot (org unit) | Phase B |

Additional visibility rulings:

1. `org_legal_entity`, `org_site`, `org_unit` are tenant-wide so all tenant users can read names/tree paths. These three hold only identifying fields; a field added later to one of them becomes tenant-wide and needs its own decision.
2. Code-scan routes must check scope on target and return same 404 for out-of-scope target as unknown code.
3. Module read functions (`lookup/2`, `active?/2`, `member?/3`) apply no scope themselves; caller routes own scope enforcement.
4. Declarations are immutable once merged (0051 M4 and D6); each declaring entry pins full map in tests.
5. REQ-519 is pending, so phase-A tests verify declarations and compiler/filter behavior, not scoped router responses.
6. Current uuid-scope-column predicate defect is acknowledged; REQ-674 is its fix and must merge before tenant scope enforcement is turned on.
7. Scoped balance-read behavior is phase B work.

Open-not-decided in D-067 and kept open here:

- whether `org_unit_membership` should be declared
- whether "positions are scoped by org unit like employees" remains an assumption or is ratified

## Owner answers recorded (source: D-065, 2026-11-02)

These are owner choices this record carries as binding inputs for later entries:

1. Org depth bound is 40 (A2 / REQ-649).
2. A movement whose org unit and location are not linked is refused (A4 / REQ-644).
3. A unit with remaining balance cannot be retired (A2 / REQ-649).
4. BIN is 12 digits and validated (REQ-660).
5. Inventory Object is its own record type; serial number is one field, not the object itself.
6. Materially responsible person and actual user store employee record ids under those names.
7. Employee records are visible only where employee org unit is visible.
8. Codes use records + assignment history; released tags can be reassigned, permanently retired tags cannot.
9. D-066 tree storage and master-data storage rulings are accepted.

## Open questions (not decided by this record)

1. Whether location tree keeps `location_node` with expanded kinds or moves to a new type family (A3 scope).
2. Tenant-wide serial uniqueness in ledger (0073 OQ-23).
3. Whether org tree ever migrates from path to ancestor array (D-066 records it as a later option only).
5. Whether `org_unit_membership` gets a scope declaration: not decided. It stays undeclared, so a scoped caller reads none.
6. Whether `org_position` is scoped by org unit like employees: not decided. It is a UAT assumption, to be confirmed by the process owner.
4. Module-upgrade slices for tenants that installed `org`, `locations`, or `catalog_items` before phase A.

## Consequences and phase-A merge ordering notes

1. A0 (this record) merges before A1..A6 entries.
2. A1 (REQ-643) before A2 (REQ-649), because both amend decision 0050 in ordered sections.
3. A3a (REQ-645) before A3b (REQ-646), and A3b before A4 (REQ-644), due to shared `locations` surfaces.
4. A5 (REQ-648) and A6a (REQ-647) wait for A0 only.
5. Phase-A implementation/UAT is on freshly provisioned tenants; existing QA tenants are not upgraded by phase-A slices.

## Sign-off

- CODE-DESIGNER: proposed in T-1098, 2026-11-02.
- CODE-DESIGN-VALIDATOR: pending.
- REVIEWER: pending.
- Owner ratification: pending.
