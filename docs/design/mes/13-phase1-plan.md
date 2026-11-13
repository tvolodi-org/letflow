# MES phase 1: build plan

Task T-1835, 2026-11-13. **DESIGN ONLY.** No code, no migration, nothing real changed, nothing on QA, demo or production.
Owner's written go of 2026-11-13 (phase 1 authorized; MIT recorded, no license file added here: the LICENSE action stays with the PM).
Sources read: `docs/design/mes/05`, `07` (section 5), `09`, `10`, `11`, `12`; `docs/design/core-extraction-design.md` sections 1, 3, 6, 7; the code named in each section.
Simple English on purpose. Labels: **[V]** verified by reading the named file today (or a test of docs 09 to 11);
**[G]** guess or assumption, to be checked by the task named next to it.

## 1. Short answer

| Question | Answer |
|---|---|
| How many tasks? | 21: 18 build tasks in 4 lanes (unit data, lot and location data, stock, `mes_core`), plus K0 (record), X1 (ops), X2 (UAT). Each is one PR or one task. |
| What is the one hard rule on order? | Only ONE task at a time may change the real stock module (policy, handlers, registration, version): tasks S1, S2 in section 5, strictly in that order. |
| What did reading the code change in the plan? | Three things, all **[V]**: (1) a handler's `posts_ledger` may name only a registration of the **same** manifest, so `mes_core` cannot post to the stock ledger from its own handler (section 6); (2) a declarative upgrade step can only change a field of existing records, never insert records, so the old-lot backfill must be a field on the lot (section 7); (3) adding an enum value to an existing field is upgrade class B, an optional new field is class A, so the customer marker is a new yes/no field, not a new `location_type` value (section 8). |
| Does anything reach demo or production? | Not by this plan. But a main build with a version bump reaches the demo when infra next promotes it, and the lot backfill would change demo lot rows. See section 12, caveat C1: the owner or infra must hold the demo promote until they accept it. |
| What needs the owner first? | Nothing blocks starting lane 1 (units). The decision record 0087 (task K0) must be accepted before S1 (section 6). |

## 2. Owner answers of 2026-11-13, and where each lands

| Owner answer | Lands in |
|---|---|
| A.1 old lots: backfill as released, then no status = held | Section 7, tasks L1 and S2 |
| A.2 customer-location marker | Section 8, task L2 |
| A.4 posting-kernel decision record first | Section 6, task K0, draft `docs/migration/decisions/0087-mes-posting-without-third-copy.md` |
| A.6 unit per item; physical attributes incl. density; conversion table (1 big tank = 3 small tanks; 1 big bag = 2 middle bags = 1 tonne) | Section 4, tasks U1 to U3 |
| B go on with phase 1; MES open (MIT) | Whole plan. No license file is added. |

## 3. Task list, in order

Every task also needs its own `requirement` entry first (a BA task per row; the engine files the issue). Sizes are T-shirt guesses **[G]**
(S = days, M = about 1 to 2 weeks for one developer). "Real stock policy" = changes `lib/letflow/modules/stock/` ledger policy, handlers,
registration or version.

| ID | Task | Lane | Size | Touches real stock policy | Depends on |
|---|---|---|---|---|---|
| K0 | Decision record 0087 accepted (REVIEWER + SECURITY-REVIEWER sign-off; owner reads it); done by T-1838 | docs | S | no | this plan |
| U1 | Unit dimension on `catalog_uom` and physical attributes on `catalog_item` (density and more) | catalog | S | no | none |
| U2 | Conversion table record type and the pure converter | catalog | M | no | U1 |
| U3 | Conversion read route (on request only) | catalog | S | no | U2 |
| L1 | Lot quality status field on `catalog_lot`, backfill step, one writer, permission, audit | catalog | M | no | none (do after U-lane PRs, same module) |
| L2 | Customer-location marker on `location_node` | locations | S | no | none |
| S1 | Stock: causes `consume` and `produce`, batch reference, two handlers, version bump | stock | M | **YES (1st)** | K0 |
| S2 | Stock: composed posting guard (freeze first, then lot rule), setting `lot_hold_enabled` default false, hold rule list | stock | M | **YES (2nd, after S1 is merged and U1 to L2 PRs merged)** | S1, L1, L2 |
| M1 | `mes_core` skeleton: manifest, depends_on, empty permission set, roles table in docs | mes_core | S | no | none (can start at once) |
| M2 | Recipe and recipe version, ingredient lines with unit and tolerance, approval freeze | mes_core | M | no | M1 |
| M3 | Work order and batch record, number scheme, status flow | mes_core | M | no | M2 |
| M4 | Batch consume and produce (calls the S1 handlers), output lot born `quarantine`; plus a small `mes_core` ledger registration, posting handler, `post` permission, `depends_on: stock` (0087 D1a) | mes_core | M | no (uses S1) | S1, M3, K0 |
| M5 | Switch on at install: `mes_core` install sets `lot_hold_enabled`, re-runs the backfill | mes_core | S | no (uses S2) | S2, M1 |
| M6 | QC sample, result lines with limits, release, hold, reject decision (uses the L1 writer) | mes_core | M | no | L1, M3 |
| M7 | Trace forward and backward: two routes, no screen | mes_core | M | no | M4 |
| M8 | Batch report as one printable document | mes_core | M | no | M3, M6 |
| M9 | Deviation record and signature object with meaning text | mes_core | M | no | M3 |
| M10 | Roles: operator, shift lead, QC analyst, QA releaser (permission grants, `docs/roles.md`) | mes_core | S | no | M6 |
| M11 | Certificate of quality per lot | mes_core | S | no | M6, M8 |
| X1 | Upgrade rehearsal on a QA copy of every QA tenant, then the QA fleet run per module (operator task) | ops | S | no | after each version-bumping merge, see section 10 |
| X2 | `uat_design` scenarios for lots, hold, trace, conversion | UAT | S | no | M7, M6 |

Web screens (batch, lot status, trace, conversion helper) are **not** in this list: they need their own tasks with the screenshot
matrix, one per screen family, after the routes exist. Not sized here **[G]**.

Total: about 12 to 16 weeks for one small team **[G]**, the range of `07` section 5; nothing re-measured.

## 4. Units, physical attributes and the conversion table (owner A.6)

### 4.1 What exists today

* A unit is a record `catalog_uom` (code, name; unit scale and conversion factors are "REQ-504, not here") and an item is `catalog_item`
  with fields `code, name, base_uom_id, kind, active, external_ref_*, tracking_policy`. **[V]** `lib/letflow/modules/catalog_items/catalog_items.ex`
  moduledoc; `priv/modules/catalog_items/pack.json` field list.
* A stock line may use only the item's own base unit: `Letflow.Modules.CatalogItems.item_uom_valid?/3` is true only when the unit equals the
  item's `base_uom_id` ("slice 1 allows only the base unit"). **[V]**
* The ledger pins one unit per balance key at first touch; a leg with another unit is refused `unit_mismatch`. **[V]**
  `lib/letflow/design/gh2657-wms-stock-ledger-core.md` line 216 and 473; proved in P1 L11 and P2 U1..U3.
* The ledger quantity column is `numeric(30,9)`. **[V]** same design file, line 216.
* REQ-504 (pending, design only) says "conversion factors applied to the base unit at posting". **[V]** `docs/requirements.yaml`, REQ-504.
  The owner now says conversion only on request, never silent. **This plan overrides that part of REQ-504 for MES** and the BA must not
  copy "conversion at posting" into the new entries. The scale and rounding parts of REQ-504 are not built and not touched here.

### 4.2 Design

| Part | Design |
|---|---|
| Where it lives | In module `catalog_items` (the shared master), not in `mes_core`: other modules need the same attributes. Version bump of `catalog_items` per PR. |
| Unit dimension | New optional enum field `dimension` on `catalog_uom`: `mass`, `volume`, `count`, `other`. Absent = `other`. Needed so a density step is only tried between a mass unit and a volume unit. |
| Physical attributes of an item | New optional decimal fields on `catalog_item`: `density_kg_per_l` (positive), `net_mass_kg` and `net_volume_l` (mass or volume of **one base unit**, for items whose base unit is a pack, for example one bag). All optional, no default. A decimal is a string on the wire (0057 D4 **[V]** per REQ-504 text). Adding an optional field is upgrade class A **[V]** `lib/letflow/modules/upgrade_plan.ex` (`optional_field_added`). |
| Conversion table | New managed type `catalog_uom_conversion` with `item_id` (optional; empty = valid for every item), `from_uom_id`, `to_uom_id`, `factor` (positive decimal string; 1 `from` = `factor` `to`), `active`. Unique per (item, from, to). Items with a value but no row are not converted. A new type in a pack is presumed class A **[G]**: task U2 proves it with U1 on a copy. |
| How packaging units are written | Only as rows. 1 big tank = 3 small tanks: `BIG_TANK -> SMALL_TANK, factor 3` (generic or for one item). 1 big bag = 2 middle bags = 1 tonne: rows `BAG_BIG -> BAG_MID, 2` and `BAG_BIG -> TONNE, 1` for the item (the bag content depends on the product), plus the generic `TONNE -> KG, 1000`. Tank, bag, tonne are ordinary `catalog_uom` records, no special type. |
| The converter | A pure function `convert(item, quantity, from_uom, to_uom)`: first an item row, then a generic row, direct or inverse, then a path of at most 3 rows. The density step (mass and volume) is allowed only when the item has `density_kg_per_l` and the two unit dimensions are mass and volume; it goes through kg and litres, the end units found by table rows. Exact decimal arithmetic. The answer lists every step used (`via`: row, factor), so nothing is hidden. Two paths with different results: refused `conversion_ambiguous`. No path: refused `conversion_not_found`. A missing density: refused `density_missing`. Result with more than 9 decimals is rounded half up to 9 (the ledger scale) and flagged `rounded: true` **[G]**: the number 3 is the ledger scale, the path cap of 3 rows is a UAT-style assumption, to be confirmed by the process owner. |
| On request only, never silent | The converter has no caller in any posting path. A read route (task U3) answers a question "how much is this in that unit"; it writes nothing. A screen may show the answer and let the user type the base-unit quantity; the document line carries the base unit only. |
| Effect on the ledger unit-per-key rule | None. The ledger still sees one base unit per item and one pinned unit per key. A tank item in litres stays in litres; the same product in kg is a different item or a conversion on request (P2 U3 shows kg and litres kept apart **[V]**). A change of an item's base unit after stock exists stays refused by `unit_mismatch` **[V]**. Not built: keeping the "entered in big bags" original on a document line; the owner may ask for it later **[G]**. |
| Mass balance | The P3 mass balance sketch refuses a litre level without a density **[V]** (doc 11 M3). In phase 3 it reads `density_kg_per_l` from the item. Not in phase 1. |
| Security | The conversion table and attributes are tenant-wide masters (scope `:tenant_wide`, like the other `catalog_*` types **[V]** `catalog_items.ex`). Writes go through the module's import and one permission; a route that reads takes the tenant from the token only (INV-1). |

### 4.3 Tasks U1, U2, U3

**U1 attributes.** Acceptance: (1) a unit and an item accept the new optional fields through the import and a read; (2) a non-positive or non-decimal
value is refused with the field name; (3) existing records read back unchanged; (4) U1/U2 upgrade plan on a tenant with the old pack reports class A, no step.
Tests: import test per field (valid, zero, negative, text, missing), a read golden for an old record, an upgrade plan test (class A), the pack and import pins
(`grep -rn catalog_item test/` first), the `manifest_hash` golden of `catalog_items` moved on purpose.

**U2 conversion table and converter.** Acceptance: (1) the owner's two examples convert exactly (3 small tanks per big tank; 2 middle bags and 1000 kg per big bag with a
generic tonne row); (2) item row beats generic row; (3) the inverse row works; (4) density path works mass to volume and back, refused without density, refused between
two mass units; (5) ambiguous loop refused; (6) 9-decimal rounding flagged; (7) no posting path calls the converter (a source scan test).
Tests: table-driven converter test with literal expected decimals, a loop test, a density test, the source scan, a cross-tenant read test of the table (INV-1, INV-6),
unique-row test.

**U3 route.** Acceptance: (1) a read route with item, quantity, from, to returns the answer with `via`; (2) nothing is written, no ledger call; (3) a caller of
another tenant never sees a row (INV-1; INV-5 not-found equals forbidden); (4) the five refusal codes of U2. Tests: router tests per code, the route-count pins
(`grep -rn "__authz_routes__\|length(snapshot)" test/` first), a cross-tenant negative test.

## 5. The stock lane: what touches the real stock policy

Rule (owner and `07` section 10): one task at a time changes the real stock module. Order: **S1, then S2**. No U, L, M task edits any file under
`lib/letflow/modules/stock/`, `priv/modules/stock/` or the stock registration. M4 and M5 only call what S1 and S2 added.
Before queuing S1 the operator checks the queue for any other task on those paths (core-extraction rule 8 **[V]**).

### S1 consume and produce (the real policy change)

* Policy `Letflow.Modules.Stock.LedgerPolicy`: add causes `consume` (one negative leg at `from`, like `issue`) and `produce` (one positive leg at `to`, like `receipt`),
  both with a batch reference in the existing header field `related_document_id` (P1 did it with 37 changed lines **[V]** doc 09 s3). The causes also go in the
  registration `causes:` map (`consume` sign rule `negative`, `produce` `positive`). `@one_leg` and the moduledoc table change.
* Two stock handlers (name them in the task, for example `consume_into_batch`, `produce_from_batch`), both `posts_ledger: "stock"`, because of the rule in section 6.
  Handler code stays thin and uses the core `Letflow.Ledger.HandlerPost`, no copy of `Stock.Documents` code.
* Version `0.17.0` becomes the next free version **[V]** current value in `stock.ex`: re-take at implement time after the last merge of main.
* Inert: the causes can only be reached through the two new handlers, and nothing calls them until M4 **[G]**: task S1 proves it by a route scan.
* Acceptance: (1) every old cause gives exactly the same answer as before (a canary of 21 commands as P1 E1, literals taken from origin/main before the change);
  (2) consume and produce post, reverse, and reconcile clean; (3) a consume below zero is refused `insufficient_balance`, nothing written; (4) old entries still verify
  with their stored registration hash (P1 L6); (5) the hash and version moved and the golden is updated; (6) U1 plan reports the step-less upgrade, U2 applies it, rollback works
  (P1 U1, U2, U4 shape); (7) the permission matrix golden is regenerated.
* Tests: P1 policy tests E1, C1..C5, L1..L6 ported to the real module; hash test H1/H2; upgrade test U1..U4 shape on a tenant with the old row; handler registration pins
  (`write_handler_registration_surface_test`, `documents_registration_test`, `kinds_registration_test`, `assets_registration_test`, `card_import_test` per the product notes **[V]** skill text);
  `permission_matrix --write` and its test.

### S2 composed guard and hold rule

* Replace the guard `{Letflow.Modules.Stock.FreezeGuard, :check}` by one composed module `Letflow.Modules.Stock.PostingGuard` that **calls the freeze check first, then the lot rule**
  (P1 did exactly this **[V]** doc 09 s6.2). The registration has one guard slot **[V]** `lib/letflow/modules/ledger_registration.ex`. Guard order bug is what test L7 catches.
* Lot rule, starting list from doc 12 row 7: a lot whose status is not `released` cannot go out by `issue`, `hand_over`, `consume`, `kind_change_out`, or a `transfer` whose to-side location
  carries the customer marker (L2). **The rule is a guess** (doc 09 s5) and the owner may change the list. No status field (null) means **held**, but only when `lot_hold_enabled` is true.
* Setting `lot_hold_enabled` in the stock `settings_schema` (exists today for `count_freeze_limit_minutes` **[V]** `stock.ex`), default `false`. With false the lot rule is skipped and the guard
  is the old freeze guard in behaviour: nothing changes for any tenant that does not install MES.
* Reads: the status from `catalog_lot` (L1) and the marker from `location_node` (L2) by prefix only, typed binds, no SQL string interpolation (INV-1, INV-6, INV-7). A missing column or an error fails closed:
  `{:failed, ...}` and nothing is posted (P1 L9 **[V]**).
* Acceptance: (1) with the setting false, a matrix of every cause and lot status posts exactly as before; (2) with true, the 12-case matrix of P1 L7 (held cases refused with a label `lot-quarantine` or `lot-rejected`, nothing written;
  allowed cases post, reversal included); (3) the freeze still wins when both apply; (4) a lot of tenant B is not held by a status of tenant A; (5) a missing column fails closed; (6) status change and posting race: the status writer takes the exclusive hold, so they serialize (P1 L10).
* Tests: P1 L7 (4 tests), L8, L9, L10 ported; the freeze tests of `freeze_guard` run unchanged against the composed guard; a `posting_guard_test` seam test; the hash golden; the same upgrade tests as S1.
* Not tested before, so tested here: the guard on the **real HTTP and engine path** (P1 limit **[V]**): at least one test posts an issue of a held lot through a real document route and gets the typed 409 `posting_held` (alias per `Failure.map/2`).

## 6. The posting-kernel decision (owner A.4): where `mes_core` posts from

Draft record: `docs/migration/decisions/0087-mes-posting-without-third-copy.md` (this task). `docs/decisions/` does not exist; all 86 records live in `docs/migration/decisions/`, so the draft is there (assumption, flagged in the summary).

Finding **[V]**: `WriteHandlerSpec` says `posts_ledger` is "the name of a registration of the **same manifest's** `:ledger` map" and `Letflow.Modules.Catalog` rule 10 checks that
(`lib/letflow/modules/write_handler_spec.ex`). So a `mes_core` handler cannot post to the `stock` ledger. The options and the recommendation are in the record. In short:
**(a)** the two posting handlers live in `stock` (S1) and `mes_core` calls them; **(b)** a separate `mes` ledger (cannot consume stock lots, refused); **(c)** change the catalog rule so a manifest may name another module's registration (a core change, bigger blast radius).
The recommendation is (a). It means no third copy of posting code: the handlers are thin, `mes_core` has no document kind, and the extraction of the shared kernel (core-extraction section 6 row "Kernel") stays HELD and separate.
**Verified in K0 (T-1838) [V]:** a `mes_core` definition may call a `stock` handler only under decision 0082 (cross-module posting lines: `stock` in `mes_core` `depends_on`, handler registers `posts_ledger`, stock installed at its compiled hash, and **a posting line of `mes_core` itself on the same node**). The last condition costs M4 a small `mes_core` ledger registration and posting handler (record 0087, D1a). Flagged for the PM. Record 0087 is accepted.

## 7. Legacy lots: backfill (owner A.1)

Owner: backfill old lots as `released`, then no status = held.

Finding **[V]**: a declarative upgrade step has a closed vocabulary `set_default`, `backfill_from_constant`, `copy_field` (`StepSpec`, `StepExec`): it changes a field of **existing** records and cannot insert a record.
A separate status table would need a code runner, which the step vocabulary names but the apply refuses (`upgrade_needs_runner`) **[V]** `step_spec.ex`.
Therefore the status is **a field on the lot** (`catalog_lot.quality_status`, enum `quarantine | released | rejected`, optional) and the backfill is one declarative step `backfill_from_constant` with value `released`.

| Part | Design |
|---|---|
| Field | L1 adds `quality_status` to `catalog_lot` (class A, optional field **[V]**). Not in the allowlist of `update_lot/4` (only `producer mark expiry_date external_ref_*` are allowed **[V]** `lots.ex`), so no existing route can set it. |
| Backfill | One step of `catalog_items` (the version of L1): `backfill_from_constant` of `quality_status = "released"`. It runs in the upgrade (U2 apply, batches via `StepExec`, one `ENTITY_RECORD_MIGRATED` event per record, no per-record audit **[V]** `step_exec.ex`). Whether it touches only lots whose field is empty is **[G]**: task L1 must prove it on a lot that already has a status (candidate query in `StepRecords.candidates_query/4`, not read here). If it overwrites, the step is wrong and L1 stops. |
| Idempotent | Run twice (U2 twice, or a rollback and apply): the second run changes no row. Tested in L1. |
| Lots born after | A lot created later has no status. With `lot_hold_enabled` false nothing reads it. With it true it is held until a releaser sets it (incoming goods wait for release). Output lots of a batch are born `quarantine` by M4. |
| Tenants that install MES later | M5 re-runs the same constant backfill at install time (lots created between the upgrade and the install), through the L1 writer or the same step vocabulary; **[G]** whether an `on_install` hook may do this is checked in M5. Fallback: an operator script, idempotent, run before the setting is switched on. |
| Writer | `CatalogItems.Lots.set_lot_status/4` (L1): allowed moves `none -> quarantine`, `quarantine -> released | rejected`, `released -> quarantine`; `rejected` is terminal (the P1 rule **[V]** L8, T1). A reason text is required for `quarantine` and `rejected`. One audit entry per change (below). It takes `Ledger.hold_exclusive!(prefix, "stock")` first, with a ledger id string, no module alias. **[G]** that `catalog_items` may call the core ledger function without a boundary violation: L1 runs `mix letflow.check_boundaries`; fallback: the writer moves into `stock` and writes the field through the lots API. |
| Permission and audit | New permission `CatalogLotStatusSet`, no default role grant except TENANT_ADMIN and PLATFORM_ADMIN (as `CatalogLotsWrite` **[V]**); module roles (M10) get it, not STOREKEEPER (release is a separate duty from moving stock). Audit action `catalog_lot.status_set` with lot id, from, to, reason, actor, in the same transaction (`Audit.append_multi`). The reason text is not a secret; no tenant data beyond the lot. A role grant needs the permission matrix golden (`mix letflow.permission_matrix --write`) and the tenant-auditor refused-set literal. |
| Acceptance | (1) old lots read `released` after U2, new lots read empty; (2) second run changes nothing; (3) the move table is exact, `rejected -> released` refused; (4) no status through `update_lot` or an import row (a lot import with `quality_status` is refused, or ignored by decision in the task); (5) a user without the permission gets 403 and nothing changes; (6) one audit entry per change; (7) cross-tenant: a lot id of tenant B answers not-found. |
| Tests | Backfill test with three lots (empty, released, rejected); a plan test (class A, one step); a writer move matrix; the permission 403 test; the audit test; the exclusive-hold race test (P1 L10 shape); a cross-tenant test; the lot import pins (`lot_import`, `card_import_test`). |

## 8. Customer-location marker (owner A.2)

* Today `location_node` has `location_type` enum `pick, ship, reject, quarantine, custody, outdoor, ...` and no customer value **[V]** `priv/modules/locations/pack.json`.
* Adding an enum value to an existing field is class B ("deliberately over-strict ... never applied silently") **[V]** `upgrade_plan.ex` `classify_entity` docstring, and the fleet driver "never sends `ack_destructive`" so a class B plan needing it fails per tenant **[V]** `fleet.ex` moduledoc (this is **my reading** that class B needs the acknowledgement; U1 on a copy settles it).
* Design (L2): a new optional boolean field `customer_location` on `location_node` (class A, **[V]** rule), absent = false, settable through the existing node update and import, one `locations` version bump.
  No change to the stock guard summary (owner choice (a), doc 12 row 2). The guard S2 reads the field of the to-side location of a `transfer`.
* Acceptance: (1) a node saves and reads the field; (2) a non-boolean value is refused; (3) old nodes read as not customer; (4) the import and update accept it; (5) the tree and links code do not change behaviour.
* Tests: node write and read, import pin, old-record golden, plan test (class A). Security: the field is a tenant master, tenant-wide read as the other node fields; no new route.
* Risk (owner paper): a missed marker lets a held lot leave by transfer to a customer. Mitigation in the UAT: scenario X2 transfers a held lot to a marked and to an unmarked customer node; the BA records that the marker is a data duty of the tenant admin.

## 9. Flags and defaults: off or inert until a tenant installs the MES module

| New behaviour | Default | What switches it on | Verified |
|---|---|---|---|
| `consume` and `produce` causes | present in the policy; only the two new handlers use them | nothing calls them until a `mes_core` batch exists (M4) | [G] route scan in S1 |
| Lot rule in the posting guard | off: `lot_hold_enabled` false | `mes_core` install (M5) sets true; an admin can set it back | [G] setting write path in M5 |
| New fields (`dimension`, density, `quality_status`, `customer_location`) | empty, optional | a person fills them | [V] class A |
| `quality_status` backfill | runs once per tenant at upgrade, sets `released` on existing lots | the upgrade of `catalog_items` | [G] semantics in L1 |
| Conversion route | read only, no caller in posting | a person asks | [G] source scan in U2 |
| `mes_core` module | not installed anywhere | a tenant admin installs it; no tenant gets it by this plan | [V] as for stock ("No tenant gets it installed", `stock.ex` moduledoc) |

No new environment variable. The only new setting is `lot_hold_enabled`, stated reason: the rule must be off for every tenant that does not use MES.

## 10. Manifest hash, U1/U2, and who gets what

* The manifest hash covers module `id`, `version`, entity types, scope, the whole `ledger` map (policy module and function, causes, guard), and each write handler `name`, module, function, `targets`, `args`, `posts_ledger` **[V]** `lib/letflow/modules/manifest_hash.ex` and core-extraction s3.
  It does **not** cover pack content or handler code. So a pack-only change needs a version bump to be seen **[V]** (same file; the discipline "bump `:version` whenever handler code changes").
* Modules whose version moves: `catalog_items` (U1, U2, L1; each PR bumps), `locations` (L2), `stock` (S1, S2). `mes_core` is new and installed nowhere.
* Effect after a deploy of main to QA: an installed tenant answers 409 `upgrade_required` on writes of that module until U1 (plan) and U2 (apply) ran **[V]** doc 12 row 5 and core-extraction s3. The boot upgrade is off by default
  (`LETFLOW_MODULE_UPGRADE_ON_BOOT`, `config/runtime.exs` **[V]**); do not switch it on.
* Path (task X1, operator, after every version-bumping merge): (1) `POST .../upgrade/plan` per tenant and module on a **QA copy**, read class, steps, `fits_one_transaction`; (2) the fleet driver `Letflow.ModuleUpgrade.Fleet.start/2` for the module, one tenant at a time, bounded batches of 25, halts after consecutive failures, tenant windows respected **[V]** `fleet.ex`; a plan that needs an acknowledgement shows as a failed tenant and the tenant admin decides.
  (3) afterwards a second plan says `up_to_date`.
* Rollback exists per tenant (P1 U4 **[V]**).
* Not tested (carried over from doc 09): the direction "tenant on real stock, build with new compiled content" and module `assets` (depends on stock). S1 closes the first with a real test; the `assets` test is added to S1 (install `assets`, run U1/U2, one asset posting).
* Because each PR bumps a version and QA auto-deploys main **[V]** (product notes), batch the merges of one module: merge the catalog PRs together in a row, then one fleet run, to cut the 409 windows. Never two stock version bumps in one day without a fleet run between.

## 11. What runs in parallel

| Together | Rule |
|---|---|
| Lane U (U1, U2, U3) with lane L (L1, L2) | Different modules (L2 is `locations`); U and L1 are both `catalog_items`, so U1, U2, U3, L1 are **sequential** among themselves (pack, version and pin collisions). L2 runs beside them. |
| Stock lane S1, S2 | Strictly one at a time; **no** other stock edit while either is open. S2 waits for L1 and L2 merged. |
| `mes_core` lane M1 to M3 and M9 | Parallel with the whole catalog and stock lanes. They touch only `lib/letflow/modules/mes_core/` and new pack files. M2, M3 are sequential (same entity pack). |
| M4 | After S1 merged. M5 after S2 merged. |
| X1 | One module at a time. |
| Two tasks that add a permission or a tenant table | Never in the same round (about 15 pinned spots, product notes **[V]**): L1, M2, M3, M6, M9 are pairwise sequential unless one adds no permission or table. |
| K0 | Parallel with U1 and L2. |

Suggested waves: **W1** K0, U1, L2, M1. **W2** U2, M2. **W3** U3, L1, M3. **W4** S1 (stock lane free), M9, M6. **W5** S2, M4, M7. **W6** M5, M8, X1, X2. **W7** M10, M11. (Guess about calendar **[G]**.)

## 12. Security review points and caveats

Security review is mandatory for tasks that touch a tenant-data path: U2, U3, L1, L2, S1, S2, M2 to M9. Points:

* INV-1: every new read is by tenant schema prefix only; no `tenant_id` argument. The guard reads status and marker by the prefix it is given. Test: status and marker of tenant A never affect tenant B (P1 L9 shape).
* INV-6: each new data-access path proves its scoping with a test: the converter (U2), the status read in the guard (S2), the trace SQL (M7: the P2 proof used a validated schema name and refused `public`, `tenant_x`, an injection string **[V]** doc 10 T6; the real build uses `Ecto` prefix, not a string).
* INV-2 and INV-5: the guard label `lot-quarantine` is shown to a caller who may post. Open from doc 09 s9 **[V]**: a caller must not probe the status of a lot of another org unit by posting a line with that lot id; the status is tenant-wide, so S2 decides: the label shows only the status word, never the lot code or note, and a lot id unknown to the tenant gets the same refusal as before (not-found equals forbidden). Test in S2.
* INV-7: typed binds only; the table and column names are constants.
* INV-8: a guard raise fails closed (P1 L9); a missing column too.
* INV-10: the conversion route and the trace routes take no tenant identifier; each gets a cross-tenant negative test anyway (a tenant admin of another company asks for a lot id).
* A new permission (`CatalogLotStatusSet`) is a role-and-access change: matrix golden, `docs/roles.md`, the tenant-auditor refused set. Releasing a lot is an audited action; four-eyes only if the plant asks (doc 12 row 7).
* Audit: status change, release decision, deviation and signature each write an audit entry in the same transaction as the record **[G]** per module for M6, M9.

Caveats the owner must see:

* **C1 (demo).** `docs/runbooks/demo-upgrade-notes.md` **[V]** says infra's `promote-demo.sh` runs the upgrade chain on every promote, and its smoke check compares record checksums (a changed lot field would show as `DIFF`, exit 1). A promote of a main that contains L1 would set `quality_status = released` on the demo's lots. This plan does not touch the demo; nothing here promotes. **Infra holds the demo promote past L1 until the owner agrees, or X1 updates the demo check to expect the backfill.** Production: not approved for the chain; `LETFLOW_MODULE_UPGRADE_ON_BOOT` stays off.
* **C2 (QA).** Every QA tenant with `catalog_items`, `locations` or `stock` installed answers 409 on writes of that module between a deploy and the fleet run. UAT must be told. A module version bump without `min_upgradable_from` strands every tenant (T-1860 hit catalog_items and assets): the guard `test/letflow/modules/upgrade_window_test.exs` now prevents it.
* **C3 (rule is a guess).** The hold rule list, who may release, and four-eyes are owner choices (doc 09 s5, doc 12 row 7). The plan builds the starting list.
* **C4 (guard rule, PM D-139, T-1882).** No module version bump merges without an END-TO-END upgrade test from the PREVIOUS released pack with real records (items, units, lots, cards, documents, as the module has). The pack of the version being replaced is kept as a fixture under `test/fixtures/previous_packs/` and the test runs `POST /api/v1/tenant/modules/<id>/upgrade/plan` and `.../upgrade` as a tenant admin. `test/letflow/module_upgrade/previous_pack_test.exs` G1 pins the current version of every module and fails on a bump until the upgrade test exists and the pin is moved. Tested pairs: catalog_items 0.2.0 and 0.3.0 -> 0.4.0, locations 0.4.0 -> 0.5.0, stock 0.10.0 and 0.14.0 -> 0.17.0, codes 0.3.0 -> 0.4.0, org 0.2.0 -> 0.3.0, assets 0.9.0 -> 0.18.0 (with cards). Applies to U1 and every MES module bump.

## 13. Open items for later decisions (not decided here)

1. Tolerance of a recipe quantity: block or warning (doc 10 s7).
2. Whether the original "entered in big bags" quantity is kept on a document line (section 4).
3. Whether the legal e-signature is needed (doc 08 item 7; M9 builds a GMP-like signature object only).
4. Rework (a finished lot consumed again): not in phase 1.
5. Trace index: whether to index `related_document_id` for consume and produce (P2 s6.4, not measured).
6. The shared kernel extraction (core-extraction s7) stays HELD; record 0087 does not take it.

## 14. Verified vs guess, one list

Verified by reading today (file in the text): `posts_ledger` same-manifest rule; step vocabulary cannot insert records; enum change is class B and an optional field is class A; fleet driver exists and never acknowledges; boot upgrade flag off by default; the ledger takes the item's base unit only and pins one unit per key; the ledger quantity scale 9; the guard slot is one; `update_lot` allowlist; `location_type` has no customer value; the stock `settings_schema` exists; `catalog_*` types are tenant-wide; the demo promote runs the chain.
Verified by the proofs (docs 09 to 11 final runs, not re-run): the policy copy, hash movement, U1 to U4 on the real stock module, the hold matrix, the trace answers, kg and litres side by side.
Guess: all sizes and weeks; that a `mes_core` process may call a stock handler; that `catalog_items` may take the stock exclusive hold; that the backfill step skips already set lots; that a new entity type is class A; that class B needs an acknowledgement; whether an `on_install` hook can write lots; the path cap of 3 and the 9-decimal rounding; the hold rule list.

## 15. Commands behind the facts

```
grep -n 'posts_ledger' lib/letflow/modules/write_handler_spec.ex
grep -n 'optional_field_added\|field_changed' lib/letflow/modules/upgrade_plan.ex
sed -n 1,40p lib/letflow/modules/step_spec.ex           # vocabulary
grep -n 'def item_uom_valid' -B8 lib/letflow/modules/catalog_items/catalog_items.ex
grep -n 'version: "' lib/letflow/modules/stock/stock.ex  # 0.17.0 at writing
sed -n 70,90p priv/modules/locations/pack.json          # location_type values
git ls-tree -r origin/main --name-only | grep 'decisions/008'   # 0086 is the highest, 0087 free
```
