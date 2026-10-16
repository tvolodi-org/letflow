# 0050 -- Foundation modules `org` and `catalog_items`, and the cross-module reference contract

Status: Accepted: ruled by the user's advisor session (letflow-ec) under the user's delegation, recorded by the supervisor; the user accepted the core changes in principle 2026-10-14.
Date: 2026-10-14. Drafted by `ORCH`. Owner: `ORCH`.
Interprets (does not amend): 0039 D8 (foundation module "when a second module needs them"), see Context.
Consistent with, and does not change: 0026, 0027, 0029, 0039 D1-D7.
Companion drafts: 0051 (org-scoped role grants; adds core changes) and 0052 (pack install activation; adds a core change).

Rulings applied: D8 (projection accepted with amendment) and OP9 (module-managed write lock accepted, interim option (c) rejected except time-boxed) per advisor session letflow-ec, Q9, relayed by the supervisor 2026-10-14. Also applied, supervisor rulings 2026-10-14 under the user's delegation: the catalog module id is `catalog_items` (not `catalog`, which collides with the core registry `Letflow.Modules.Catalog`); a third public read function `member?/3` is accepted; references are declarative-only in slice 1 (KNOWN LIMIT, D3.6). Open points 1, 7, 8 and 9 are removed as resolved; the remaining numbers are kept so cross-references stay valid.

## The decision as given

Binding architect decisions, relayed by the supervisor on 2026-10-14 from the user's advisor.
Recorded as given; not independently verified by the writer:

> Foundation now as slice 0 with TWO modules: `org` (legal entity, site, org unit as a tree
> with parent, optional position, user-to-org-unit membership row) and `catalog` (item, UoM,
> counterparty); `locations` arrives with the warehouse slices, `assets` with CMMS. Plain
> entity types in each module's pack plus a small public read API (lookup, active?); no new
> core tables. Reference contract: reference by immutable record id (a business code is unique
> but never used as an FK); retire = active=false, no new document may reference a retired
> record, existing references stay valid, no hard delete; rename = normal update; legal
> documents (purchase request, З-forms, СНТ) store a snapshot of name/UoM/BIN at posting; a
> referencing module validates via the foundation module's lookup through depends_on; if entity
> fields have no reference type, store the id string and validate in the module (no new core
> reference type for slice 1). Minimum for the purchase request: legal entity, org unit (with
> site), item (code, name, base UoM, active), UoM, free-text line for works/services;
> counterparty at slice 2; no employee record (requester = Letflow user + membership row).

## Context

0039 D8 says shared concepts (organisation, department, employee) move into a foundation
module (e.g. `org`) "when a second module needs them, not before", and that nothing is built
"until a real client solution needs it" (`0039:196-201`). Today there is ONE module (`exam`;
`priv/modules/exam/` is the only module directory) and NEITHER planned consumer exists.

This record therefore INTERPRETS D8 rather than plainly applying it: the trigger is read as
"two named, funded consumers", not "two installed modules". The target is a suite (ERP, CMMS,
HR, logistics, manufacturing) for one customer (Kazakhmys); procurement (purchase request,
approval) and WMS (goods receipt) are the first two consumers and both need the same legal
entity, org unit, item and UoM. Both consumers are PLANNED, not built. D8's "never
speculatively" half still binds: `locations`, `assets`, `position` and `counterparty` are not
built in slice 0 (D1). The reading is recorded here as the amendment statement and is DECIDED: the user's suite
(ERP, CMMS, HR, logistics, manufacturing) for Kazakhmys is the demand, and the consumers (procurement,
WMS) are planned (open point 7 closed). To avoid confusion with this record's own D8 (the
projection), "0039 D8" always means the foundation-module rule of 0039.

## Deviations from the relayed wording

1. ACCEPTED DEVIATION (advisor session letflow-ec, Q9): "no new core tables" is relaxed for ONE
   core-owned security index, the `scope_node_paths` projection (D8). The relayed wording stays
   binding for everything else: no other new core table.
2. The 0039 D8 trigger is read as "two named consumers" (Context; DECIDED, open point 7 closed).
3. Module id `catalog_items` replaces the relayed name `catalog` (supervisor ruling, collision
   with `Letflow.Modules.Catalog`); the relayed quote above is kept verbatim.

### Security MUST: confirmed by the advisor (Q10)

SECURITY-REVIEWER (review of 0051, M4) tightens the advisor's OP9 ruling. Written into D7 below; CONFIRMED by
the advisor (letflow-ec, Q10, relayed 2026-10-14):

4. M4: the ruling said changing or removing `managed_by` through the definitions API "must be refused or be
   a platform-scope action". Tightened to: refused, flatly, for any tenant caller (the definitions API
   refuses create / update / activate / deprecate / delete of a definition whose type name is held by a
   managed type, uniform 403), and `managed_by` itself is declared by module code / manifest, never by
   tenant-writable definition JSON, and is immutable once set (D7).
5. F1 (REVIEWER): the lock covers EVERY foundation entity type, not only `org_unit` and
   `org_unit_membership` (the ruling named those two and said the lock is general). Otherwise D3.2
   "no hard delete" has no enforcement for the other types in slice 1 (no FK backstop, D3.6).

## Decision

### D1. Two foundation modules, slice 0

* `org` (built in slice 0): `org_legal_entity`, `org_site`, `org_unit` (tree via a parent id),
  `org_unit_membership` (Letflow user id to org unit id). No employee entity. The `parent`
  field is a `:string` id in slice 1 (declarative-only references, D3.6 KNOWN LIMIT); a
  self-referential FK is legal (`validator.ex:620-642`) but is not used in slice 1.
* `catalog_items` (module id; built in slice 0): `item`, `uom`. Entity types are `catalog_item` and `catalog_uom` (D6).
* NOT built in slice 0, listed for naming only: `position` (org) and `counterparty` (`catalog_items`,
  slice 2 per the architect). Neither gets an entity definition, pack entry or table until a
  requirement consumes it.
* `catalog_items` `depends_on: ["org"]` only if an entity needs a legal-entity reference; otherwise
  `depends_on: []`. Open point 3.

Each is an application module under D1/D2 of 0039: manifest, `pack` at
`priv/modules/<id>/pack.json`, entity definitions beside it (the shape `exam` already uses,
`docs/guides/adding-an-application-module.md:176-180`).

### D2. Public read API per foundation module

Each foundation entry module exposes `@doc`-documented functions, minimum `lookup(prefix,
id)` returning the record or `{:error, :not_found}` and `active?(prefix, id)` returning a
boolean. `org` additionally exposes `member?(prefix, user_id, org_unit_id)` (is the user a
member of the org unit; supervisor ruling 2026-10-14, ACCEPTED). Consumers call them only through `depends_on`, which the boundary check allows
(`lib/mix/tasks/letflow.check_boundaries.ex`: Rule 3 documented at lines 35-36, code at
line 230). A consumer may also reach the foundation's entity records through core's public
record API; the lookup is the supported path because it is the place the "active" rule lives
(D3.2).

### D3. Reference contract

1. **Immutable id.** A reference is the target's `record_id` (uuid). A business code
   (item code, BIN) is declared `unique` (constraint type `:unique` only,
   `validator.ex:238-243`) but is never the referenced key.
2. **Retire, never delete.** Retire sets `active=false` through a normal update. No new
   document may reference a retired record (checked via `active?`, D2); existing references
   stay valid. No hard delete: enforced in slice 1 by module code AND by the `managed_by` write lock on every foundation type (D7). A database backstop
   (`ON DELETE RESTRICT`, `lib/letflow/entities/definition/ddl.ex:59-70`) exists only where an
   FK is promoted, which slice 1 does not do (D3.6 KNOWN LIMIT).
3. **Rename is an ordinary update.** The id does not change, so references do not break.
4. **Snapshot for legal documents.** Purchase request, З-forms and СНТ copy name, UoM and
   BIN into the document at posting. Later renames never rewrite a posted document.
5. **Validation lives in the referencing module.** It calls the foundation module's `lookup`
   / `active?` at write time, through `depends_on`.
6. **Reference storage in slice 1: declarative-only (KNOWN LIMIT).** Store the id as a
   `:string` field and validate in the module via `lookup`/`active?`. No new core reference
   type and NO database FK in slice 1, because activation promotes only fields named in a
   `constraints` entry (0052 fact 5; `ensure_column_promotions/2`, `definitions.ex:482-518`).
   Consequences accepted: the database does not stop a dangling or hard-deleted target;
   integrity rests on module code and on retire-only; a cross-pack FK is not proven (NOT FOUND
   below). A later slice may promote FKs; that needs its own record.

### D4. Minimum surface for the first consumer (purchase request)

legal entity; org unit (with its site); item (code, name, base UoM, active); UoM; a
free-text line for works/services (no item). The requester is a Letflow user plus a
membership row; there is no employee record.

### D5. Install order

Installation honours `depends_on`: the foundation module is installed before any consumer
(`docs/guides/adding-an-application-module.md:190-195`; `installs.ex` rejects an install
whose `depends_on` is unsatisfied). A solution lists foundation modules first or relies on
dependency-order install (D6 of 0039). Retire/rename/snapshot rules are enforced in module
code, not in pack content, consistent with 0029 (scripts and rules stay out of packs).

### D6. Entity-type naming rule (decided, not open)

Entity types are tenant-wide by bare name, and activating a definition demotes every other
definition of the same name (`lib/letflow/entities/definitions.ex:376-393`). A tenant that
already has its own `item` type would be silently superseded by a module install. Rule: every
entity type a module ships is prefixed with the module's declared entity prefix (the module id,
except `catalog_items`, whose prefix is `catalog_` so the types read `catalog_item` and
`catalog_uom`): `org_legal_entity`, `org_site`, `org_unit`, `org_unit_membership`,
`catalog_item`, `catalog_uom`. `exam` predates the rule and
is not renamed. 0052 D6 additionally makes install fail if a same-name definition already
exists. The prefix rule is a precondition for 0052.

### D7. Org tree integrity and write path (requirement on the `org` module)

The org tree is a security boundary once 0051 lands (node position decides who sees what), so
it cannot be an ordinary freely writable entity:

* Intended: `org_unit` and `org_unit_membership` are written only through `org` module routes
  that require `:UsersGroupsRolesManage` (held by `TENANT_ADMIN` and `PLATFORM_ADMIN`,
  `docs/roles.md:86`).
* **Known gap (verified, motivates the ruling): nothing today stops generic writes to these
  types.** `lib/letflow/entities/type_access.ex` is READ-side only (REQ-394). Generic record
  writes are gated only by the coarse `:EntitiesRecordsWrite` / `:EntitiesRecordsImport`
  permissions (routes `lib/letflow/routers/entities.ex:293,297,301,314`), which
  `docs/roles.md:99` gives to `PLATFORM_ADMIN`, `PROCESS_OPERATOR` and `TENANT_ADMIN`
  tenant-wide. A `PROCESS_OPERATOR` could PATCH `org_unit.parent`, bypassing `move_org_unit`,
  the cycle rule and the audit.
* **DECISION (advisor session letflow-ec, Q9, OP9 ACCEPT): a general core "module-managed
  entity type" write lock.** An entity type definition carries a flag `managed_by:
  <module_id>`. Generic create / update / delete / import on such a type returns 403; only
  the owning module's own path writes it. The lock is applied to EVERY foundation entity type: `org_legal_entity`,
  `org_site`, `org_unit`, `org_unit_membership`, `catalog_item`, `catalog_uom` (REVIEWER F1). Without it,
  generic `DELETE /entities/records/:type` (`:EntitiesRecordsWrite`, `PROCESS_OPERATOR`) and a PATCH of
  `active` stay open for the types left out, and D3.2 "retire, never delete" (and the 0051 D1 rule "an
  `org_unit` cannot be deleted while a grant references it") would be convention only. Foundation records
  are written through the owning module's routes/actions (permissions per route are for the designer;
  `org_unit` and `org_unit_membership` need `:UsersGroupsRolesManage`). The lock is general: the WMS
  stock-movement ledger will need the same lock. Today the flag does not
  exist (`grep managed_by lib`: no hits; NOT FOUND). Placement notes for the designer
  (verified): modules call `Records.create_record/2` / `update_record/2` directly (exam:
  `lib/letflow/modules/exam/anti_cheat.ex:258`, `session.ex:1064`), so the lock cannot be an
  unconditional refusal inside `Records.*`; it sits at the generic HTTP handlers
  (`entities.ex:293,297,301,314`) at minimum, with the module path identified by caller, not by
  request data. Core change; adds to the 0051 core footprint.
  * **How `managed_by` is declared (REVIEWER F2, SECURITY M4).** The pack JSON shape is closed, so the
    declaration is not a free tenant-writable field: it comes from the owning module's code / manifest
    (the module declares the type names it manages; the install step stamps them on the definition) and
    is IMMUTABLE once set. Whether this needs a new validator field or a pack-schema change: for the
    designer (NOT VERIFIED; no `managed_by` exists today).
  * **Tamper-proofing (M4).** `EntitiesDefinitionsWrite` is held by `PROCESS_DESIGNER`, and activating a
    same-name definition demotes the existing one (`definitions.ex:376-393`). The definitions API
    (create `POST /definitions` `entities.ex:261`, activate `POST /definitions/:name/activate`
    `entities.ex:257`, and any other definitions write route) therefore REFUSES (uniform 403 body) any
    create / update / activate / deprecate / delete of a definition whose type name is held by a managed
    type, and refuses creating a NEW type whose name collides with a managed type of ANY installed module, and refuses removing or altering `managed_by` (and the 0051 D6 scope-column / `tenant_wide`
    declarations, which follow the same rule). A test per route: `PROCESS_DESIGNER` cannot supersede
    `org_unit`, `org_unit_membership` or any other managed or scope-aware type. 0052 D6's install-time
    same-name check does not cover post-install API activation; this rule does.
  * **Paths the lock must cover (F2).** Not only the HTTP handlers: a process step that writes an entity
    (REQ-484, planned, unregistered; NOT VERIFIED in code) and 0053 hook 2 (scripted rules) are engine /
    module-side write paths and must also refuse managed types, with the owning module path identified by
    caller, not by request data. 0051 T12/T13 scope rules apply to the same paths.
* **Interim option (c) (audit plus periodic integrity check, no lock) is REJECTED**, except as
  an explicit, time-boxed interim with an end date recorded in the requirement. 0051 must NEVER
  be enabled on a tenant while (c) applies. Option (b) (tree outside generic records) is not
  chosen.
* Who may re-parent: only that permission, via a dedicated `move_org_unit` action, never by
  patching the `parent` field through the generic API.
* Cycle prevention: the action rejects a move that makes a node its own ancestor (the
  self-referential FK, `validator.ex:620-642`, does not prevent cycles), and rejects a
  parent that is retired. A test must cover a direct and a transitive cycle.
* The `org` move action enforces the depth bound 0051 D3 relies on (12).
* Every insert/move/retire is audited (0051 D8).

* **Amendment 2026-10-16 (GH #2596): the single exception to the insert-only stamp.** The stamp is written at insert, with ONE exception: the platform stamp of the exam module's six frozen runtime types (`certificate`, `session`, `session_answer`, `session_event`, `session_question`, `session_question_score`), NULL to `'exam'` only, through `Letflow.Entities.ManagedTypes.Stamp` (`lib/letflow/design/gh2596-exam-managed-types.md`). The supervisor ruling of 2026-10-16 supersedes the earlier "all 16 exam types": the ten exam authoring types stay unmanaged until an exam authoring write surface exists.

### D8. Interface to core (advisor session letflow-ec, Q9: ACCEPTED, with amendment)

0051 needs core to answer "ancestors of node" and "descendants of node set". Core must not
depend on a module-owned table (0039 D3; `check_boundaries.ex` Rule 5; a core FK into
`entity_org_unit` cannot exist before promotion). DECISION: a core-owned projection
`scope_node_paths` (node id, materialised path, depth) in the tenant schema; core queries only
its own table (one indexed query). The alternative (a core behaviour that `org` implements) is
not chosen. Amendment:

* The projection is written ONLY by a core function, called by the `org` module's create /
  move / retire paths in the SAME database transaction as the `org_unit` write. No other
  writer; no module-side SQL on the table.
* A core consistency check (orphans, cycles, depth over the bound of 12) ships as (1) a
  mix-check test and (2) an admin endpoint. The endpoint's permission atom is for the designer
  (proposal: `:UsersGroupsRolesManage`, `docs/roles.md:86`); the check is read-only.
* ACCEPTED DEVIATION from "no new core tables": a core-owned security index (Deviations 1).
* Residual divergence risk (projection vs entity) is bounded by D7's write lock plus the
  same-transaction rule, and detected by the consistency check.

## Capabilities relied on (cited on this branch)

| Capability | Evidence |
|---|---|
| Entity field types: `:string :integer :decimal :boolean :date :datetime :enum :json :localized_text`. No reference/uuid type | `lib/letflow/entities/definition/validator.ex:50-60` |
| Named unique constraints over several fields; unique-only | `validator.ex:238-243`; `lib/letflow/entities/definition/ddl.ex:408-435`; example `priv/modules/exam/entity_definitions/exam_manual_question.json:44-49` |
| `foreign_keys` with `field` + `references_entity`; shape validated | `validator.ex:205-231`; FK field coverage `validator.ex:362-377` |
| Self-referential FK now legal (needed for the org-unit tree) | `validator.ex:620-642` (Rule 9 lifted, REQ-324) |
| FK column is physical `uuid` pointing at `record_id`; `ON DELETE RESTRICT` | `lib/letflow/entities/definition/ddl.ex:268-285`, `:59-70` |
| FK targets resolved by entity-type name only (`table_name_for_entity_type`) | `lib/letflow/tenant_provisioning.ex:1796-1806` |
| Pack installs entity definitions and in-pack FKs already work | `priv/modules/exam/entity_definitions/answer_option.json` (fk to `question`); `solution_pack.ex:946` |
| `depends_on` enforced at install, `on_install/2` after pack | `docs/guides/adding-an-application-module.md:190-195`; `lib/letflow/modules/installs.ex:70-86` (`install/3` at 73, `on_install` call at 82) |
| Boundary check lets module `a` reference module `b` iff `b` in `a`'s `depends_on` | `lib/mix/tasks/letflow.check_boundaries.ex:21-36` (Rule 3 code at 230) |
| Catalog validates `depends_on` names a registered module | `lib/letflow/modules/catalog.ex:215-225` |
| Dependent-module fixture exists | `test/support/modules/fixture_dependent/fixture_dependent.ex:24` |
| Record write API | `lib/letflow/entities/records.ex:160,192,226` (create / update / delete) |
| Eight closed roles (count) | 0046 D10 (0013's own title still says five) |

### NOT FOUND

* **NOT FOUND: a cross-pack FK exercised anywhere.** Every FK in `priv/modules/exam/` targets
  an entity in the same pack. The mechanism resolves by entity-type name
  (`tenant_provisioning.ex:1796-1806`) with no module scoping, so it plausibly works when the
  target is installed and promoted first (D5), but no test or pack proves a `references_entity`
  crossing module packs, and the validator does not check the target exists
  (`validator.ex:205-231` checks shape only).
* **NOT FOUND: a module exposing a read function to another module.** No module `depends_on`
  another in production (`exam` has none; the only dependent module is the test fixture,
  `fixture_dependent.ex:24`). The `@doc`-vs-`@doc false` convention (`0039:104`) is stated
  for core, not for module-to-module.
* **NOT FOUND: a single-record read helper.** `records.ex` has only create/update/delete
  (`:160,192,226`); reads go through the query compiler (`query/compiler.ex:155`). D2's
  `lookup` therefore has to be built on the query path.
* **NOT FOUND: an `active` flag convention.** No platform notion of "retired" for entity
  records exists; `delete_record` is the only lifecycle verb (`records.ex:226`). `active` is a
  plain `:boolean` field per entity under D3.2.
* **NOT FOUND: a uuid-typed or reference-typed entity field** (`validator.ex:50-60`); hence
  the `:string` id (D3.6).
* **NOT FOUND: a `managed_by` / module-managed flag** (D7 decides it; `grep managed_by lib`: no hits).
* **NOT FOUND: a mechanism making a module's entities visible only to its dependents.** Entity
  types are tenant-wide by name; D6 closes the collision risk by naming rule only.

## Consequences

* 0050 itself adds no core table, migration or core code: slice 0 is two module directories,
  their packs, their entry modules and tests. Stated honestly, though, slice 0 DEPENDS on core
  changes made by the companion records, if they are accepted: 0051 adds a core grant table,
  `Letflow.Api.Scope` and (per D8) a core path projection; D7 adds the core `managed_by`
  write lock; 0052 changes `installs.ex` and `module.ex`. Without them slice 0 can still ship the entities but not scoped access or
  activated, promoted types at install.
* Consumers pay a lookup per reference write; acceptable at procurement volumes.
* Snapshotting makes posted legal documents immune to later renames and retirements.
* Retire-only means catalogs grow; a later archive feature is possible but not decided here.
* `locations` and `assets` are deferred; a consumer needing a warehouse or asset before
  those modules exist must carry a free-text reference, not invent a local entity.

## Consistency with existing decision records

| Record | Relationship |
|---|---|
| 0039 D1-D7 | followed: each foundation module is a normal application module, install per tenant, no uninstall |
| 0039 D8 | interpreted, not amended: trigger read as two named consumers; DECIDED, see Context |
| 0039 D3 | core must not depend on module tables: D8 above |
| relayed "no new core tables" | relaxed for one core-owned security index (D8); accepted deviation |
| 0026 | entity definitions travel in the pack `entity_definitions` section; no new pack section |
| 0027 | unaffected |
| 0029 | unaffected: lookup/active rules are reviewed code, not pack scripts |
| 0025 | `ON DELETE RESTRICT` would be the DB backstop for "no hard delete" but needs FK promotion, which slice 1 does not do (D3.6 KNOWN LIMIT) |
| 0013 / 0046 | no new role; module permissions follow the 0039 D4 `role_grants` rule; eight roles per 0046 D10 |

## Open points

REVIEWER / architect:

2. Whether `lookup`/`active?`/`member?` take `prefix` first (INV-1 shape) and how they are typed; and
   whether a `@doc`-documented function on a module entry file counts as "public" under 0039 D3.
3. Whether `catalog_items` depends on `org` or the two stay independent. Default: independent.
4. (Closed by D6: prefix rule.) 1, 7, 8 and 9 are removed as resolved (D3.6, Context, D8, D7).
5. Where the "active" filter is enforced for UI pickers (module router, or core query filter);
   whether a retired record may still be read by id. Default: readable by id, hidden from pickers.
6. Whether membership needs a unique constraint on `(user_id, org_unit_id)` and how the user id
   is stored (string id, no reference type). Default: unique constraint, string id.
7. (Closed: the 0039 D8 reading is decided, Context. Number kept.)

## Sign-off

Proposed by `ORCH` from decisions relayed by the supervisor on 2026-10-14; rulings applied as
stated above; not independently verified by the writer except where file:line citations are given.

REVIEWER sign-off:
