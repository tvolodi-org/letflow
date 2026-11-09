# WMS foundation runbook

Operational notes for the WMS foundation modules (decision 0050). Each module adds its own
section; REQ-507 (catalog) reuses this file.

## Org module limits

Module `org` (GH #2661 / REQ-473 skeleton, GH #2662 / REQ-506 read API) as it is on main. Each
limit names the GH issue or the code that holds it; code lines were re-read when this section
was written.

1. **Generic writes to the six types are refused.** `org_legal_entity`, `org_site`, `org_unit`,
   `org_unit_membership`, `org_position` and `org_employee` are in `manages_entity_types`, so the generic entity routes answer
   403 `entity_type_managed` (GH #2530, PR #2568). The router maps
   `{:error, :entity_type_managed}` at `lib/letflow/routers/entities.ex:566`, and
   `Letflow.Entities.Records` decides it per write in `check_write_authority/3`
   (`lib/letflow/entities/records.ex:2009`, delegating to `ManagedTypes.check_record_write/3`).
2. **Writes go through the module's own Owner only, and nothing checks references.** Module
   code writes with the `/3` arity, `Records.create_record/3` with
   `ManagedTypes.owner_for!(Letflow.Modules.Org)` (`lib/letflow/entities/records.ex:421`). The
   module has owner-path write functions for legal companies and sites (GH #3619 / REQ-660, item 12) and for units (GH #3618 / REQ-495: `create_unit/3`, `update_unit/4`, `move_unit/4`, `retire_unit/3` in `Letflow.Modules.Org.Units`, keeping the scope tree index through `Letflow.ScopeNodePaths.write/2` in the same transaction; the retire balance guard of D-065 is not built yet). References between the
   original four types (`legal_entity_id`, `site_id`, `parent`, `org_unit_id` of the membership) are
   declarative strings with no foreign keys and no reference check (the two newer types are item 8): a record can name a legal entity, site or unit that does
   not exist (decision 0050 D3.6; `priv/modules/org/entity_definitions/`).
3. **Record attachment upload and delete on a managed type are refused.** A non-owner caller
   gets the 403 `entity_type_managed` (the org types included) via
   `Letflow.Entities.RecordAccess.attachment_write/3` (GH #2582); list and content reads are
   unchanged.
4. **Client idempotency keys cannot use the reserved server-derived prefix.** The single-command
   entry points (`create_record`, `update_record`, `delete_record`) refuse, before any query, an
   `idempotency_key` that starts with the exact bytes `sys:step:` (or `record_trigger:` when no `:trigger_lineage` is passed, REQ-628) and return
   `{:error, :reserved_idempotency_key}` (`reject_reserved_key/2`,
   `lib/letflow/entities/records.ex:1363`; prefix `@step_key_prefix`, line 366). Only
   `command_multi/3` accepts that key family, and it has two callers:
   `lib/letflow/entities/step_writes.ex:821` and `lib/letflow/entities/handler_writes.ex:439`.
   `reject_reserved_attributes/1` (`lib/letflow/entities/records.ex:1306`) is a separate check:
   a top-level `source` or `metadata` attribute gives `{:error, :reserved_attribute}`. GH #2550
   is closed (PR #2600).
5. **The read API is by record id only.** `Letflow.Modules.Org.lookup/2`, `active?/2` and
   `member?/3` (`lib/letflow/modules/org/org.ex`) take a `record_id` uuid; a non-uuid value is
   "not found" or `false`, never a raise. A soft-deleted record is indistinguishable from an
   absent one (`Letflow.Entities.Record.Latest.get_live/3`, GH #2734). There is no lookup by
   `code` or by external reference.
   Contract: `prefix` must be derived server-side from the authenticated tenant, never from
   HTTP input; isolation is by prefix alone and a wrong prefix reads another tenant with no
   check. The never-raise guarantee holds for a provisioned tenant prefix only (a well-formed
   but unprovisioned `tenant_<hex>` prefix raises `undefined_table` from Postgres). `member?/3`
   returns `false`, without a query, for a `user_id` containing NUL, invalid UTF-8 or longer
   than 256 bytes.
6. **Ids are matched as exact text.** `member?/3` (`lib/letflow/modules/org/org.ex`) compares the stored `org_unit_id` and
   `user_id` byte for byte and expects the canonical lowercase uuid, so REQ-495's write
   functions must normalise ids on write.
7. **Two types for people (GH #3584, REQ-643, org 0.2.0).** `org_position` (code, name, org_unit_id,
   active, external reference pair) and `org_employee` (code, full_name, org_unit_id, position_id,
   user_id, active, external reference pair) are managed types shipped by
   `priv/modules/org/pack.json`. `user_id` is the optional Letflow user id as text, unique per
   employee; employees without a user are not limited. No identity number, address, phone, birth
   date or salary is stored.
8. **Their references are real foreign keys, and only that.** `org_unit_id` and `position_id` are
   uuid columns referencing the target table `ON DELETE RESTRICT` (decision 0050 amendment
   2026-10-31, D-066; GH #3584), so an unknown id is refused by the owner path with a `reference` violation.
   The key proves only that the target exists: that the position belongs to the same unit and that
   targets are active is checked by the write functions of REQ-661 (item 13).
9. **One term for the person in charge.** The "materially responsible person"
   (`material_responsible`) and the "actual user" (`actual_user`) are each an `org_employee` record
   id, never a Letflow user id; a writer checks one with `Letflow.Modules.Org.active_employee?/2`,
   and `employee_for_user/2` finds the employee of a user (GH #3584).
10. **The import exists (GH #3599, REQ-654).** The two types are written through the write functions of item 13
    (the Owner path) and the routes of item 14; the roster import (below) calls the same functions, and
    `scope_declarations` (employees and positions scoped by `org_unit_id`) is inert until REQ-519
    (GH #3584). `org_unit`, `org_position` and `org_employee` are imported by the generic route
    through `Letflow.Modules.Org.import_row/3` (`Letflow.Modules.Org.Import`), which calls only the
    write functions: upsert by external ref only, a reference cell (`legal_entity_id`, `site_id`,
    `parent`, `org_unit_id`, `position_id`) holds the external id of the target under the file's
    system, there is no `active` column (retiring stays the retire functions), a changed `parent`
    is a move, a changed employee unit or position is a transfer, and a position's unit and every
    `code` cannot change. Legal entities and sites are not imported: they must exist, created with
    `external_ref_system` and `external_ref_id` equal to the cell. An upsert needs tenant-wide scope
    (`import_scope_check/6`). A dry run replays a file once per row refused by a write function and
    gives up after 20 such rows (`dry_run_unavailable`); cell and reference errors do not count.
11. **Tenants that installed org before 0.2.0 are not upgraded.** Module install is first-install
    only (`Letflow.Modules.Installs`), so such a tenant has no `org_employee` or `org_position`
    definition, and reactivating an uninstalled org there answers `upgrade_required`
    (`check_reactivatable/2`). The upgrade is owed by REQ-642 point 7, in the shape of
    `Letflow.Modules.Exam.ParentRollout`; no phase A entry builds it (GH #3584). REQ-770 adds the generic
    upgrade for modules that declare `min_upgradable_from` and no migration steps (stock does): plan with
    `POST /api/v1/tenant/modules/:module_id/upgrade/plan`, then apply with `POST .../upgrade`
    (`Letflow.ModuleUpgrade.Apply`). It does not re-run `on_install/3` seeds, so a document type that a newer
    stock version registers on install is not registered for an upgraded tenant until REQ-773 steps exist.
12. **Legal companies and sites have owner-path write functions (routes: item 14).**
    `Letflow.Modules.Org.create_legal_entity/3`, `update_legal_entity/4`, `retire_legal_entity/3`,
    `create_site/3`, `update_site/4` and `retire_site/3` (logic in `Letflow.Modules.Org.Masters`,
    GH #3619 / REQ-660) write through the org Owner, one audit entry per accepted change, nothing on
    a refusal. The BIN is exactly 12 ASCII digits with no control digit (UAT assumption, to be
    confirmed by the process owner: D-065 says "12 digits, validated" and names no checksum), and two
    active companies of one tenant never share a BIN (`:bin_taken`, checked under an advisory lock
    keyed by tenant and the text `org_legal_entity_bin`; a retired company's BIN may be reused).
    `code` is immutable; retire is `active` false and is refused while an active site or unit names
    the record (UAT assumption, same status). The routes are item 14;
    tenants that installed org before the pack carried these definitions are not upgraded.
13. **Positions and employees have owner-path write functions (GH #3617, REQ-661; routes: item 14).**
    `Letflow.Modules.Org.create_position/3`, `update_position/4`, `retire_position/3`,
    `create_employee/3`, `update_employee/4`, `transfer_employee/5` and `retire_employee/3` (logic in
    `Letflow.Modules.Org.People`) write through the org Owner, one audit entry per accepted change,
    nothing on a refusal. Unit and position must be active, the position must be of the employee's
    unit (`:position_not_in_unit`), `user_id` must be a user of the tenant (`:user_not_found`; a
    disabled user may stay linked, UAT assumption), a position held by an active employee is not
    retired (`:position_in_use`), and a position is never moved between units (UAT assumption). A
    transfer changes unit and position in one record version; only an active employee can be
    transferred. The audit entries of an employee omit `full_name` (personal data; a name-only change
    is recorded as `changed_fields`); the name remains in the record and its event payload.
14. **Write routes (GH #3613, REQ-665, org 0.3.0).** `Letflow.Modules.Org.Router` serves 17 write
    routes under `/api/v1/modules/org/` (`/legal-entities`, `/sites`, `/units`, `/positions`,
    `/employees`, each with create, `PATCH /:id` and `POST /:id/retire`, plus `/units/:id/move` and
    `/employees/:id/transfer`), no read route. `legal-entities`, `sites` and `units` need
    `OrgStructureWrite`; `positions` and `employees` need `OrgEmployeesWrite`; only TENANT_ADMIN and
    PLATFORM_ADMIN hold them (no `role_grants`). Every body carries a text `idempotency_key`; a reused
    key with another body is 409 `idempotency_key_reuse`, a not-found target (also of another tenant)
    is 404, any other refusal is 422 with a `reason`. A tenant that installed org before 0.3.0 gets
    the routes without an upgrade (they come from the code manifest), but its definitions are not upgraded (item 11).

## Catalog module limits

Module `catalog_items` (GH #2663 / REQ-474 skeleton, GH #2664 / REQ-507 read API) as it is on
main. Each limit names the GH issue or the code that holds it; code lines were re-read when
this section was written. It covers the types `catalog_uom`, `catalog_item`, `catalog_counterparty` (GH #3407, REQ-604) and `catalog_lot` (GH #3593, REQ-647).

1. **Generic writes to the four types are refused.** All are in `manages_entity_types`, so the
   generic entity routes answer 403 `entity_type_managed` (GH #2530, PR #2568). The router maps
   `{:error, :entity_type_managed}` at `lib/letflow/routers/entities.ex:566`, and
   `Letflow.Entities.Records` decides it per write in `check_write_authority/3`
   (`lib/letflow/entities/records.ex:2009`, delegating to `ManagedTypes.check_record_write/3`).
   The one exception is the import route (item 2).
2. **Writes go through the module's own Owner only; the three masters are imported through the
   managed import path (GH #3602, REQ-651).** Module code writes with the `/3` arity,
   `Records.create_record/3` with `ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)`
   (`lib/letflow/entities/records.ex:421`); the only such caller is
   `lib/letflow/modules/catalog_items/import.ex`. `catalog_uom`, `catalog_item` and
   `catalog_counterparty` register `Letflow.Modules.CatalogItems.import_row/3` in the manifest key
   `:import_functions`; `POST /entities/records/:entity_type/import` calls it once per row through
   `Catalog.call_import_function/5` (`Letflow.Entities.ManagedImport`). Upsert by external ref only
   (`upsert_by` absent is 422), a reference cell holds the external id of the target, and
   `?dry_run=true` runs the file and rolls it back (decision 0077 D5 to D7). `catalog_lot` is imported
   through `Letflow.Modules.CatalogItems.LotImport` (GH #3599, REQ-654), which calls only `create_lot/3` and
   `update_lot/4` (item 20, GH #3614); its `item_id` cell is the external id of a `catalog_item`.
   Each `:created` or `:updated` row also writes one audit entry in the same transaction (GH #3739,
   REQ-706): `catalog_uom.created`, `catalog_uom.updated`, `catalog_item.created`, `catalog_item.updated`,
   `catalog_counterparty.created` and `catalog_counterparty.updated`, with the stored field values before
   and after; an `:unchanged` row, a refused row and a replay write none.
3. **No reference check on `base_uom_id`.** A `catalog_item` can name a `base_uom_id` that is
   not a `catalog_uom` record, is inactive or is deleted: it is a declarative string with no
   foreign key (decision 0050 D3.6; the import path is the exception: `reference_not_found` and
   `reference_inactive`, GH #3602; `catalog_lot.item_id` is the exception, see item 14;
   `priv/modules/catalog_items/entity_definitions/catalog_item.json`). `item_uom_valid?/3` is
   where an unknown or inactive unit shows up, as `false`.
4. **Record attachment upload and delete on a managed type are refused.** A non-owner caller
   gets the 403 `entity_type_managed` (all four catalog types included) via
   `Letflow.Entities.RecordAccess.attachment_write/3` (GH #2582); list and content reads are
   unchanged.
5. **Client idempotency keys cannot use the reserved server-derived prefix.** The single-command
   entry points (`create_record`, `update_record`, `delete_record`) refuse, before any query, an
   `idempotency_key` that starts with the exact bytes `sys:step:` (or `record_trigger:` when no `:trigger_lineage` is passed, REQ-628) and return
   `{:error, :reserved_idempotency_key}` (`reject_reserved_key/2`,
   `lib/letflow/entities/records.ex:1363`; prefix `@step_key_prefix`, line 366). Only
   `command_multi/3` accepts that key family, and it has two callers:
   `lib/letflow/entities/step_writes.ex:821` and `lib/letflow/entities/handler_writes.ex:439`.
   `reject_reserved_attributes/1` (`lib/letflow/entities/records.ex:1306`) is a separate check:
   a top-level `source` or `metadata` attribute gives `{:error, :reserved_attribute}`. GH #2550
   is closed (PR #2600).
6. **The read API is by record id only; deleted is the same as absent.**
   `Letflow.Modules.CatalogItems.lookup/2`, `active?/2` and `item_uom_valid?/3`
   (`lib/letflow/modules/catalog_items/catalog_items.ex`) take `record_id` uuids; a non-uuid
   value is "not found" or `false`, never a raise. A soft-deleted record is indistinguishable
   from an absent one (`Letflow.Entities.Record.Latest.get_live/3`, GH #2734). There is no
   lookup by `code` or by external reference.
7. **`item_uom_valid?/3` allows only the base unit in slice 1.** It is true only when the item
   and the unit are both live and active and `uom_id` equals the item's `base_uom_id`; any
   other unit, even an active one, is `false`. Alternative units and conversion factors are
   REQ-504 (GH #2660). The id is compared as exact text: the stored `base_uom_id` must be the
   canonical lowercase uuid, so the write functions must normalise ids on write.
8. **Caller contract on `prefix`.** `prefix` must be derived server-side from the authenticated
   tenant, never from HTTP input; isolation is by prefix alone and a wrong prefix reads another
   tenant with no check. The never-raise guarantee holds for a provisioned tenant prefix only (a
   well-formed but unprovisioned `tenant_<hex>` prefix raises `undefined_table` from Postgres;
   `lib/letflow/modules/catalog_items/catalog_items.ex`).
9. **`catalog_counterparty` is the supplier master (GH #3407, REQ-604).** Its definition is
   `priv/modules/catalog_items/entity_definitions/catalog_counterparty.json`: unique `code`,
   `name`, `kind`, optional `tax_id` (queried, format not validated), `active` and the nullable
   `external_ref_system` / `external_ref_id` pair. `kind` is `supplier` or `contractor`; both
   the two values and the `tax_id` rule are UAT assumptions for the process owner to confirm.
10. **`lookup/2` and `active?/2` return several types.** They search `catalog_uom`,
    `catalog_item`, `catalog_counterparty` and `catalog_lot` in one call
    (`lib/letflow/modules/catalog_items/catalog_items.ex`), so a caller must check the
    `"entity_type"` of the map it gets: a supplier id passed as a unit or an item is found, not
    rejected, by `lookup/2`.
11. **A supplier is retired with `active` false; there is no delete operation.** The record stays
    readable, `lookup/2` returns it with `"active" => false` and `active?/2` is `false`. The
    module ships no write function (GH #3407). The both-or-neither rule for the external
    reference pair is not enforced, as for the other two types.
12. **Suppliers cannot be seeded by the generic import.** `POST /entities/records/catalog_counterparty/import`
    answers 403 `entity_type_managed` because the type is managed
    (`lib/letflow/routers/entities/record_import.ex`), so the seeding path of decision 0057 D12
    for suppliers is open (GH #3407).
13. **An already installed tenant does not get the new type.** `catalog_items` installed before
    GH #3407 has two types only: no upgrade path adds an entity type to an installed module
    (`lib/letflow/modules/installs.ex`), and because `manages_entity_types` changed the
    manifest hash, reactivating such a tenant's module answers `upgrade_required`. Fresh
    installs get all the types of the day; `lookup/2` still works on the old tenants. Reinstalling is
    refused too (`already_installed`), so there is no operator path today: such a tenant stays
    on the two types until a module-upgrade requirement is delivered. The behaviour is pinned
    by test U-01 in `test/letflow/modules/catalog_items/counterparty_test.exs` (T-0862).
14. **`catalog_lot` is the lot (batch) master (GH #3593, REQ-647).** Its definition is
    `priv/modules/catalog_items/entity_definitions/catalog_lot.json`: `item_id`, `code`,
    optional `producer`, `mark` and `expiry_date` (a date), `active` and the nullable
    `external_ref_system` / `external_ref_id` pair, all queried. `item_id` is a real foreign key
    to `catalog_item` (`fk_catalog_lot_item_id`, ON DELETE RESTRICT, owner decision D-066); the
    record delete is a soft delete, so the foreign key does not act on that path. A lot whose
    `item_id` names no item is refused by the reference rule of `Letflow.Entities.Records`.
15. **Lot rules (owner decision D-065).** `producer` is free text, not a reference to
    `catalog_counterparty`; the lot `code` is unique per item (the same code may exist for two
    items); `expiry_date` is optional. That `mark` is free text is a UAT assumption for the
    process owner to confirm (GH #3593). A lot is retired with `active` false; there is no delete
    operation.
16. **`item_lot_valid?/3` checks an item and one of its lots.** It is true only when the item is
    live and active, the lot is live and active, and the lot's stored `item_id` equals the item
    id (exact text, canonical lowercase uuid; `lib/letflow/modules/catalog_items/catalog_items.ex`).
    A lot of another item, a retired or deleted record, the id of a record of another type and
    any non-uuid value are `false`, never a raise.
17. **Lots are seeded by the import function.** `POST /entities/records/catalog_lot/import`
    reaches `Letflow.Modules.CatalogItems.LotImport` (GH #3599, REQ-654): upsert by external ref
    only, no `active` column, a changed `code` or `item_id` is refused.
18. **An already installed tenant does not get `catalog_lot`.** As item 13: no upgrade path adds
    an entity type to an installed module (`lib/letflow/modules/installs.ex`); the module upgrade
    slice owed by REQ-642 point (7) adds it, and the rows of such tenants are untouched. Fresh
    installs get the type. The manifest now declares `scope_declarations` (`:tenant_wide` for all
    four types, decision D-067 and 0051 M4); that reaches installed tenants too, because the
    manifest is compiled, and enforcement is REQ-519.
19. **A malformed `expiry_date` or a non-uuid `item_id` is refused by a raise.** The payload
    schema of a date field is a plain string, and the promoted column is cast in
    `Letflow.TenantProvisioning` (`cast_promoted_value/2`). Observed by tests L-10 and L-14 in
    `test/letflow/modules/catalog_items/lot_test.exs`: `expiry_date` "2027-02-30" raises
    `ArgumentError` (invalid_date) and `item_id` "not-a-uuid" raises `Ecto.CastError`; no record is
    stored either way. This is a finding against core Records (GH #3593), not fixed here, so a
    future write function must validate both values before the owner-path write. The lot writers
    of item 20 do (GH #3614); a direct caller of `Records` still gets the raise.
20. **Lot writers: `create_lot/3`, `update_lot/4`, `retire_lot/3` (GH #3614 / REQ-664).** They live in
    `lib/letflow/modules/catalog_items/lots.ex` and are delegated from
    `Letflow.Modules.CatalogItems`. Each writes through the module's Owner in one transaction with
    one audit entry (`catalog_lot.created`, `catalog_lot.updated`, `catalog_lot.retired`); the
    routes and the permission are item 21. A retired lot may still be updated, retiring a retired lot writes
    nothing, and nothing checks stock (there is no stock ledger on main). Writers for the item,
    unit and supplier types are the import slice A6b.
21. **Lot routes (GH #3610 / REQ-668, `catalog_items` 0.2.0).** `Letflow.Modules.CatalogItems.Router`
    (`lib/letflow/modules/catalog_items/router.ex`) serves `POST /lots`, `PATCH /lots/:id` and
    `POST /lots/:id/retire` under `/api/v1/modules/catalog_items/`, behind the one permission
    `CatalogLotsWrite`, which has no `role_grants` (TENANT_ADMIN and PLATFORM_ADMIN only). Every
    body needs a text `idempotency_key`; the rest is the lot fields, checked by the item 20 writers.
    An unknown, malformed or other-tenant lot or item id is 404, a refusal is 422 with a `reason`
    (field names only), a reused key with other input is 409. The routes come from the code
    manifest, so a tenant that installed the module earlier has them without an upgrade; its
    definitions are still not upgraded (items 13 and 18).
22. **Tracking policy and `validate_capture/3` (GH #3581 / REQ-641, `catalog_items` 0.3.0).**
    `catalog_item` has an optional `tracking_policy` enum (`none`, `lot`, `serial`, `expiry`; absent is
    `none`) in `priv/modules/catalog_items/entity_definitions/catalog_item.json`. `validate_capture/3`
    in `lib/letflow/modules/catalog_items/catalog_items.ex` checks a capture map against it: `none`
    needs nothing, `lot` the lot, `serial` the serial, `expiry` the lot and the expiry date (the
    receipt date is the posting time); a supplied value the policy does not require is refused. It is
    called by no receipt or issue yet, so the MD-04 evidence stays open until the receipt and ledger
    slices. Serial ownership and the refusal of a duplicate active serial stay in the stock ledger
    (REQ-503 design `lib/letflow/design/gh2658-wms-stock-dimensions.md`, section 5). MD-01
    synchronisation is not built (decision 0057 D1). The field is set only through the owner path,
    because the generic import refuses a managed type (`entity_type_managed`). A tenant installed
    before 0.3.0 keeps the old definition (no upgrade path, items 13 and 18): `lookup/2` works and
    `validate_capture/3` reads the missing field as `none`; QA tenants are fresh-only. One policy per
    item; a combined policy such as serial with expiry is an open owner question (assumption, owner
    may change at GATE B).

## Locations module limits

Module `locations` (GH #3501 / REQ-625 skeleton, GH #3591 / REQ-645, decisions 0050 and 0066) as it
is on main. It covers the one type `location_node`, one tree with a free `node_kind` per level. Each
limit names the GH issue or the code that holds it; paths are cited without line numbers.

1. **Generic writes to `location_node` are refused.** The type is in `manages_entity_types`, so
   the generic entity routes answer 403 `entity_type_managed` (GH #2530), mapped in
   `lib/letflow/routers/entities.ex` and decided per write by `Letflow.Entities.Records`
   (`lib/letflow/entities/records.ex`, delegating to `ManagedTypes.check_record_write/3`).
2. **Writes go through the module's own Owner only.** `Letflow.Modules.Locations.create_node/3`,
   `move_node/4`, `update_node/4` and `retire_node/3` (`lib/letflow/modules/locations/tree.ex`, GH #3588)
   are the write functions; they write with `ManagedTypes.owner_for!(Letflow.Modules.Locations)`, each
   after the tenant tree lock. There is no un-retire and no delete function.
   Each accepted write also appends one audit entry in the same transaction (GH #3741, REQ-705,
   `Letflow.Audit.insert_entry/3`): `location_node.created`, `location_node.updated`,
   `location_node.moved` and `location_node.retired`, with the stored field values before and after.
   A refusal, a no-op and a replay write none; a failed entry rolls the write back
   (`{:error, :audit_failed}`). Imported rows write through the same functions and are audited too.
3. **Tree rules are enforced by the module functions.** `create_node/3` refuses a parent that is not
   found or inactive; `move_node/4` is one parent change of one record and refuses a cycle by walking
   the parent chain; `retire_node/3` refuses while a descendant is active. A subtree is read with
   `descendant_ids/2`, one recursive query. The tree is the parent link only: a real foreign key
   (`priv/modules/locations/entity_definitions/location_node.json`), no stored path, no stored depth
   and no depth bound (decision 0066). Addresses are not rewritten on a move or a segment change
   (GH #3588).
4. **No `org_site_id`; the org link is its own type.** The field was removed from `location_node`
   (GH #3591). The link between the org tree and the location tree is the type
   `location_org_unit_link` of GH #3586, and the manifest now depends on `org`.
5. **No both-or-neither rule for `external_ref`.** The unique constraint over
   `external_ref_system` and `external_ref_id` only applies when both are set; a row with one of
   the two is accepted (GH #3501, import key of decision 0057 D1).
6. **No capacity, size or compatibility fields.** Location size, load limit, storage mode,
   temperature band and item compatibility rules are not in the definition (GH #3501); they need
   the exact-decimal quantity type (GH #2654) and the customer's values. There is no lookup by
   `address` either: the read API is by record id only (`lib/letflow/modules/locations/locations.ex`).
7. **The generic import refuses the managed type.** `POST /entities/records/location_node/import`
   answers 403 `entity_type_managed` because the type is managed
   (`lib/letflow/routers/entities/record_import.ex`), so test locations cannot be seeded that way
   (GH #3407 records the same gap for suppliers against decision 0057 D12).
8. **Tenants that installed `locations` 0.1.0 are not upgraded.** The module upgrade of decision
   0055 is not built (GH #3582), so such a tenant keeps the old definition: `parent_id` stays a
   text column without a foreign key and `node_kind` stays the three-value list. The module is
   tested on freshly provisioned tenants (GH #3591).
9. **The link type and its fields.** `location_org_unit_link` has three fields: `location_id`,
   `org_unit_id` and `active`; the pair is unique and the relation is many to many. Two
   functions write links: `link_unit_location/4` and `unlink_unit_location/4` of module locations
   (GH #3616, REQ-662), one transaction and one audit entry each. Linking a pair that has an inactive
   link reactivates the same record; unlinking sets `active` false and never deletes. The routes are item 15;
   there is no import for links yet. Unlinking checks no stock: no ledger code exists, and the slice that first
   posts stock under D-065 decides whether an unlink with stock is refused.
10. **One real foreign key, one checked id.** `location_id` is a uuid column with a foreign key onto
    `location_node` (`ON DELETE RESTRICT`); `org_unit_id` is another pack's id, so it has no foreign key
    (decision 0050 D3.6, D-066) and `link_unit_location/4` checks it at write time. The reads `linked?/3`,
    `location_ids_for_org_unit/2` and `org_unit_ids_for_location/2` check both ends at read time
    (`lib/letflow/modules/locations/locations.ex`, GH #3586).
11. **The not-linked movement rule (D-065).** A consumer refuses a movement when `linked?/3` is false for the
    pair of org unit and location at posting time, and names both. A movement without a location is not
    checked. Retiring a unit, a location or a link only makes the pair not linked; it changes no balance
    and no past movement. This slice builds no refusal reason (GH #3586).
12. **Separate fields, no shortcut.** The link is its own record; `location_node` holds no org field and
    `org_unit` holds no location field (GH #3586).
13. **Tenants that installed `locations` before 0.3.0 are not upgraded.** The module upgrade of decision
    0055 is not built (GH #3582; see `lib/letflow/modules/exam/parent_rollout.ex` for the shape), so they
    have no link type. The module is tested on freshly provisioned tenants with `org` installed first
    (GH #3586).
14. **The import of the tree is `import_row/3`, upsert by external ref only.** The core import route
   (`?upsert_by=external_ref`, xlsx, CSV or JSON) calls `Letflow.Modules.Locations.import_row/3`, which
   delegates to `Letflow.Modules.Locations.Import` (`lib/letflow/modules/locations/import.ex`, GH #3601).
   It writes only through `create_node/3`, `update_node/4` and `move_node/4`. The key is the field pair
   `external_ref_system` / `external_ref_id`, not the record-level master reference (the Tree functions
   never set it), so a later type that resolves a location by external id through
   `Latest.get_by_external_ref/4` will not find it. `parent_id` is the external id of the parent under the
   row's system; the parent must come earlier in the file, else `reference_not_found` with header
   `parent_id`. A re-import moves and updates by the same Tree rules (`cycle`, `parent_inactive`). The row
   is the full desired state: an absent optional cell clears the value. There is no `active` column
   (retire stays `retire_node/3`), a changed `code` is `field_not_allowed`, the address is the given text
   only (no segment pattern), and nothing is retired or deleted by import. A dry run follows the rules of
   `ManagedImport`; a Tree refusal costs one replay there.
15. **Write routes (GH #3612, REQ-666, locations 0.4.0).** `Letflow.Modules.Locations.Router` serves six
   write routes under `/api/v1/modules/locations/`: `POST /nodes`, `PATCH /nodes/:id`,
   `POST /nodes/:id/move`, `POST /nodes/:id/retire`, `POST /links` and `POST /links/retire`; no read
   route. All need `LocationsWrite`; only TENANT_ADMIN and PLATFORM_ADMIN hold it (no `role_grants`).
   Every body carries a text `idempotency_key`; `POST /nodes` also takes `address_pattern` (only the text
   `"segments"`). A reused key with another body is 409 `idempotency_key_reuse`, a not-found target (also
   of another tenant) is 404, any other refusal is 422 with a `reason`. A tenant that installed
   `locations` before 0.4.0 gets the routes without an upgrade (they come from the code manifest), but its
   definitions are not upgraded (item 13).

## Codes module limits

Module `codes` (GH #3588 / REQ-648 skeleton, decisions 0076 and 0050, owner decisions D-065 to D-067)
as it is on main. It covers the three types `code_tag`, `code_assignment` and `code_value_change`.
Each limit names the GH issue or the code that holds it; paths are cited without line numbers.

1. **Generic writes to the code types are refused.** The three types are in `manages_entity_types`,
   so the generic entity routes answer 403 `entity_type_managed` (GH #2530), mapped in
   `lib/letflow/routers/entities.ex`.
2. **Writes go through the module's own Owner only.** Module code writes with the `/3` arity,
   `Records.create_record/3` with `ManagedTypes.owner_for!(Letflow.Modules.Codes)`
   (`lib/letflow/modules/codes/codes.ex`); the tests do the same
   (`test/letflow/modules/codes/codes_fixture.exs`).
3. **Write functions have write routes (item 18) and the scan has a route (item 19).** Receive, assign, release, retire and change value are
   in `lib/letflow/modules/codes/writes.ex` (REQ-663, GH #3615); the routes are REQ-667 (GH #3611), the scan route is REQ-730 (GH #3797).
4. **The target is not validated.** `target_type` and `target_id` are declarative strings, no
   foreign key is possible (decision 0050 D3.5 and D3.6, GH #3588); a code may name a type no module ships.
   The module that writes a code validates the target through the owning module's lookup.
5. **Model rules R1 to R8.** The record id of a code never changes (R1); the value is unique (R2)
   and may change with the old value kept (R3); one open assignment at a time (R4); history rows
   are never deleted (R5); a scan resolves through the open assignment only (R6); a retired code
   never comes back (R7); movements name the object's record id, never the code (R8)
   (`lib/letflow/modules/codes/codes.ex`).
6. **Value unique in the tenant, retired codes included.** `uq_code_tag_value` is a unique
   constraint over `value` for every status; "tenant" means the tenant schema, so two tenants may
   hold the same value (`priv/modules/codes/entity_definitions/code_tag.json`).
7. **Per-target uniqueness is a possible future change.** Uniqueness of target type, target id and
   value is not built and not decided (GH #3588).
8. **No case folding, no trimming.** Values are compared exactly (owner decision D-058 point 8):
   `ABC` and `abc`, or a value with a trailing space, are different codes (GH #3588).
9. **R4 has no storage guard.** A definition has no partial unique index, so two open assignments of
   one code are not refused by the database; the write functions of REQ-663 keep R4 under their
   lock, and `resolve/2` answers `:assignment_conflict` if it ever happens (GH #3588).
10. **The generic import refuses the managed types.** `POST /entities/records/code_tag/import`
    answers 403 `entity_type_managed` (`lib/letflow/routers/entities/record_import.ex`).
11. **Serial uniqueness in the ledger is not resolved.** A unique code value does not stop the ledger
    from holding one serial at two locations (OQ-23 of decision 0073, GH #3588).
12. **No barcode or QR print block.** The print layout blocks are page, text, field, table and
    spacer (`lib/letflow/documents/print_layout.ex`); label printing is a later entry (GH #3588).
13. **No scope is applied by the read functions.** `resolve/2` and the other reads take no
    principal. The three types are declared `:tenant_wide` (decision 0051 M4, immutable); a scan
    route must check the scope of the resolved target with `Letflow.Api.Scope.allowed?/3` and
    answer an out-of-scope target with the same 404 as an unknown code (decision 0051 D7, GH #3588).
14. **Targets are scanned, not indexed.** `target_type` and `target_id` carry no index, so
    `codes_for/3` filters the stored field values without one; fine at skeleton size
    (`lib/letflow/modules/codes/codes.ex`).
15. **Assignment targets are three types.** `assign_code/5` accepts `location_node`, `catalog_item` and
    `catalog_lot` only (UAT assumption, GH #3615); the entry that adds the asset type extends the list
    (`lib/letflow/modules/codes/writes.ex`).
16. **A batch holds at most 1000 codes.** `receive_codes/3` refuses more with `:batch_size` (UAT
    assumption for the process owner to confirm, GH #3615); a changed value equal to the current one is a
    no-op, not an error.
17. **A replay is not compared with its input.** A repeated idempotency key answers the current state of
    the code and writes nothing; the same key with other input is not detected (GH #3615,
    `lib/letflow/modules/codes/writes.ex`).
18. **Write routes (GH #3611, REQ-667, codes 0.2.0).** `Letflow.Modules.Codes.Router` serves five POST
    routes under `/api/v1/modules/codes/`: `/receive` (body `entries`, 201), `/:id/assign` (`target_type`,
    `target_id`), `/:id/release`, `/:id/retire` and `/:id/value` (`value`), all 200. All need `CodesWrite`;
    only TENANT_ADMIN and PLATFORM_ADMIN hold it (no `role_grants`). Every body carries a text
    `idempotency_key` and no other keys. An unknown code or target (also of another tenant) is 404, a bad
    batch entry is 422 `entry_invalid` with its `index` and `entry_reason`, any other refusal is 422 with a
    `reason`. A tenant that installed codes before 0.2.0 gets the routes without an upgrade (they come from the
    code manifest); the scan route is item 19.
19. **Scan lookup route (GH #3797, REQ-730, codes 0.3.0).** `POST /api/v1/modules/codes/resolve` (body `value`, no
    `idempotency_key`, no other key) needs `CodesRead`; only TENANT_ADMIN and PLATFORM_ADMIN hold it (no
    `role_grants`). It writes nothing. A not assigned code, or an assigned code whose target type is
    `tenant_wide`, is 200 with the `resolve/2` map; a retired or conflicting code is 200 with the sent value and
    null keys. An unknown code, and an assigned code whose target type is scoped or undeclared (fail closed),
    are the same 404 (`lib/letflow/modules/codes/router.ex`).
20. **Label route (GH #4017, REQ-779, codes 0.4.0).** `POST /api/v1/modules/codes/labels` (body `code_ids`, 1 to 1000
    distinct `code_tag` ids, no other key) needs `CodesRead` and answers a PDF (`code-labels.pdf`, A4, 3 x 8 labels,
    `Letflow.Modules.Codes.Labels`; Code 128 set B for kind `barcode`, QR level M for `qr`). It writes nothing. An id
    that is not a live `code_tag` of the tenant is the same 404 as an unknown id; a code that cannot be printed (kind
    `epc` or `tid`, retired, value not encodable, glyph missing, longer than 20 characters) is 422 `entry_invalid`
    with the index and `entry_reason`, never the value. The sheet size and the 20-character limit are UAT assumptions.

## Stock module limits

Module `stock` (GH #3707 / REQ-687, slice L4 of the stock ledger, decision 0073, owner decisions D-085 to D-087)
as it is on main: one ledger registration, a pure posting policy, two views and three read routes. Each limit
names the GH issue or the code that holds it; paths are cited without line numbers. Numbers marked
"assumption, owner may change at GATE B" are owner assumptions, not decisions.

1. **No master checks until slice L7.** The module has no gather step and checks no item, location, unit,
   org unit, employee or lot against a master (decision 0073 D6, D7 D-P and OQ-20, GH #3707). A mistyped id
   makes a new balance key whose first-touch unit pin is permanent.
2. **Pilot gate, quoted from decision 0073:** "The stock module is NOT enabled for a customer tenant until L6
   AND L7 are done, and serial-tracked goods stay out of the pilot until OQ-23 is resolved." No seed, pack or
   QA fixture installs the module (`docs/migration/decisions/0073-domain-neutral-ledger-primitive.md`).
3. **OQ-13 and OQ-23 are not decided.** There is no serial slot and no warehouse or zone scoping of
   postings; serial-tracked goods stay out of the pilot (GH #3707).
4. **Posting is built (REQ-713); only a human task posts.** The stock documents of REQ-679 post when the `post` task of the
   `stock_receipt` instance of an issued receipt is completed with the OIDC credential by a holder of `StockPost`; a posted one is
   reversed through the `reverse` task of a `stock_reversal` instance (`StockReverse`). The SERVICE origin is
   refused until slice L5 (REQ-688, GH #3705); the posting code is `lib/letflow/modules/stock/handlers.ex`
   (GH #3748).
5. **API tokens get 404 from every read route; a scoped reader reads its own units.** `Letflow.Ledger.authorize/3`
   answers `:error` for an API token. A reader granted on org units (REQ-682, REQ-693) gets the balances and
   movements of those units only; the query key `scope_subtree` (one org unit id) narrows to a subtree and
   `/balances` then reports `coverage` `complete` or `visible_only`, which a client shows as "your units in P"
   and never as the total of P; a movement leg in a hidden unit is masked (`leg_no`, `quantity`, `unit_ref`,
   `masked`). `reconcile` is tenant-wide only and answers a scoped reader 404 (GH #3733). Whether the ledger read
   follows the tenant's enforcement mode is open (owner, assumption, may change at GATE B).
6. **No role grants; OQ-11 is open.** Only TENANT_ADMIN and PLATFORM_ADMIN hold `StockPost`, `StockReverse`,
   `StockRead` and `StockReconcile` (`docs/roles.md`); the owner decides any widening (GH #3707).
7. **Reconcile reads one chunk per call.** `GET /api/v1/modules/stock/reconcile` runs one chunk; a client loops
   on `next_cursor` until it is null, and only the last result carries `chain_check` and `audit_check`
   (`lib/letflow/ledger/reconcile.ex`). A statement timeout is 503 `ledger_read_timeout`, a busy lock 409
   `reconcile_busy`.
8. **Export is one page per xlsx file.** `format=xlsx` on `balances` and `movements` renders the page the JSON answer
   holds (follow `next_cursor` for the next file); the `report` sheet gives the time basis and a note that a balance
   as of a time before an opening posting shows no opening quantity (decision 0079 D1). The movements file has
   no `ledger_seq` (GATE B open question) and its timezone is Asia/Almaty (assumption, owner may change at GATE B)
   (GH #3772, `lib/letflow/modules/stock/xlsx_export.ex`).
9. **The T-LD-1 throughput floor is a pilot condition.** The floor of note 7.6 (REQ-686 criterion 9) is not
   checked by this module (`lib/letflow/design/gh2657-wms-stock-ledger-core.md`, GH #3707).
10. **Event time of an entry follows the core rule.** The policy ignores an `event_time` key; the entry time
    is the core's `client_event_time` (posting time online) (`lib/letflow/modules/stock/ledger_policy/declare.ex`).
11. **The registry of ledger ids is built at boot.** `Letflow.Modules.Catalog.ledger_registry/0` is stored in
    the app env `:ledger_registry` by `lib/letflow/application.ex` when unset; routes still answer 404 for a
    tenant that has not installed the module (GH #3707).
12. **Assumptions, owner may change at GATE B:** the default tenant time zone Asia/Almaty, the speed-test
    volumes and p95 targets, the 96-hour lateness, the six causes and the slot order
    `sku, location, org_unit, responsible, lot` (`lib/letflow/modules/stock/stock.ex`).
13. **Master checks of a document run at issue only.** `POST /api/v1/modules/stock/documents/:id/issue` checks the
    link of org unit and location, the employee, the counterparty and each line's unit and lot
    (`lib/letflow/modules/stock/documents/checks.ex`); a master retired between issue and posting is not caught
    until the ledger's own master validation, slice L7 (decision 0073 D6, GH #3749).
14. **Scoped principals and API tokens get 404 from the document routes.** The six routes of
    `lib/letflow/modules/stock/router.ex` under `/documents` serve an interactive tenant-wide principal only, the
    guard is `lib/letflow/modules/stock/access.ex`; scoped posting (L6) is not part of phase B (GH #3749).
15. **Document defaults are owner-changeable at GATE B.** Receipt numbered per year with prefix RCP and pad 6, no
    legal entity, at most 1000 lines (REQ-774, GH #3988), the responsible employee not bound to the org unit, no approval step, the
    org unit of a draft cannot change (discard and create anew) (`lib/letflow/modules/stock/documents.ex`, GH #3749).
16. **Installing the new version is an explicit step.** Version 0.2.0 of the module adds the two record types and the
    document type `stock_receipt`; a tenant that installed 0.1.0 takes them through the module upgrade path
    (`lib/letflow/modules/tenant_module_upgrade.ex`), no tenant is upgraded or seeded by the change (GH #3749).
17. **Version 0.3.0 adds the posting parts.** The record type `stock_posting_mark`, the write handlers
    `post_document` and `reverse_document`, the process definitions `stock_receipt` and `stock_reversal` and the
    routes `post`, `reverse` and `cancel`; the module is installed on no tenant, so no upgrade of installed rows is
    needed, and a tenant that installed 0.2.0 takes the new type and definitions through the module upgrade path
    (`lib/letflow/modules/tenant_module_upgrade.ex`, GH #3748).
18. **The binding gap: posting is detected, not enforced, until slice L7.** The handler reads nothing, and the
    engine merges the `output_variables` of a completion without a per-node allowlist, so a holder of `StockPost`
    could complete the post task with changed posting variables, or start the definition through the generic
    instance start route with variables of its own, also for a draft or a cancelled document. The document read
    answers `posting_check` `mismatch` (no detail) whenever the legs of its ledger entries differ from the issued
    content, a draft has an entry, a mark has no entry, or a cancelled document has a receipt with no reversal;
    prevention is slice L7 with its expected-document-version check (decision 0073 D6, decision 0078 D5, GH #3748).
    A master retired between issue and posting is likewise caught only at L7 (item 13).
19. **The post and reverse tasks have no assignee.** Both nodes carry the role label `TENANT_ADMIN` (the graph needs a
    role), any user may open them, and the ledger authority step refuses a completer without `StockPost` or
    `StockReverse`, an API token included; the task then stays pending (`lib/letflow/ledger/handler_post.ex`,
    GH #3748).
20. **One posted and one reversed mark per document.** The unique constraint `uq_stock_posting_mark_doc_mark` of
    `stock_posting_mark` refuses a second completion for the same document: the whole completion rolls back before
    any ledger write, so there is one entry and one mark, the second task stays pending and the answer is a typed
    refusal, not the ledger's duplicate result. This also refuses a second completer and a changed quantity under
    the same operation id (`priv/modules/stock/entity_definitions/stock_posting_mark.json`, GH #3748).
21. **The definitions are activated lazily.** Install leaves `stock_receipt` and `stock_reversal` as stamped drafts;
    the first issue (and the first reverse) of a tenant activates its definition with the activator of that request
    (`DefinitionsActivate` and `EntitiesRecordsWrite`), and answers 409 `definition_not_active` before any number is
    taken when it cannot, or when an active definition of that name is not the module's
    (`lib/letflow/modules/stock/documents/posting.ex`, GH #3748).
22. **`reason_text` of a reversal is kept on the instance only.** The ledger keeps the closed `reason_code`; the free
    text (at most 500 characters) is the variable `reason_text` of the `stock_reversal` instance
    (`lib/letflow/modules/stock/documents/posting.ex`, GH #3748).
23. **Receipt-only fields.** Version 0.4.0 adds `supplier_document_ref`, `received_on`, `unit_price` and `line_value`
    to the receipt types. Price and value live on the document only: the posting reads literal keys and never copies
    them to the ledger. At issue the lot is checked against the item's tracking policy (serial-tracked goods are
    refused, `tracking_policy_not_supported`) and `received_on` may not be after the event day in Asia/Almaty
    (assumption, owner may change at GATE B) (`lib/letflow/modules/stock/documents/checks.ex`, GH #3747).
24. **A transfer, hand over or return is filed under one org unit only.** The filing unit is the from unit
    (`org_unit_id`) of a transfer or hand over, and the unit the stock goes back to (`org_unit_id`) for a return; the
    other unit does not see the document in phase B, and scoped (L6) posting is not part of phase B. The filing unit is
    the scope column of the header and of every line (`Letflow.Modules.Stock.Documents.Kinds`, GH #3770).
25. **The from side is checked by the ledger only, at the post task.** Issue checks that each side's location is
    linked to its org unit and that each side's employee is active, but not the balance; a transfer, hand over or
    return larger than the from side holds answers `insufficient_stock` at the post task, which then stays pending
    with no entry and no mark until the document is cancelled, and a reversal after the to side's quantity left is
    refused the same way (`lib/letflow/modules/stock/documents/posting.ex`, GH #3770).
26. **Defaults of transfer, hand over and return, owner may change at GATE B.** Number prefixes `TRF`, `HOV`, `RET`
    (year numbering, pad 6, no legal entity); the responsible employee is not bound to the side's org unit; no
    price, value, reason or counterparty field; a return needs no earlier hand over; equal sides (same unit, location
    and employee) are refused at save as `sides_equal` (`priv/modules/stock/entity_definitions/stock_transfer.json`,
    GH #3770).
27. **Opening balance document.** Version 0.9.0 adds the second document kind `opening` (records `stock_opening` and
    `stock_opening_line`, number prefix `OPN` per year, pad 6). It posts only through the two-person process
    `stock_opening` (GH #3774); a larger stock than 1000 lines is entered as several documents (the import route's 200-row file cap is unchanged)
    (`lib/letflow/modules/stock/documents/opening_shape.ex`, GH #3775). A tenant that installed 0.8.0 (or earlier) takes the new
    types and definitions through the module upgrade path (`lib/letflow/modules/tenant_module_upgrade.ex`); no tenant
    is upgraded or seeded by the change.
28. **The entry's event time is its posting time.** An opening carries no event time; the real receipt date is a field of
    each line (`received_on`) and never reaches the ledger. A balance as of an earlier time therefore shows no opening
    quantity, and the posting handler, the policy and the read-side check all refuse a client event time
    (`lib/letflow/modules/stock/handlers.ex`, GH #3774).
29. **At most 1000 lines.** The cap is now 1000 per REQ-774 / GH #3988 (it was 100); a posting carries up to 2000 legs. The cap of the stock policy `declare/2` applies, a deviation from the 200 lines of decision
    0079 D2 (owner may change at GATE B) (`lib/letflow/modules/stock/ledger_policy/declare.ex`, GH #3775).
30. **Not offered on a customer tenant before the pilot gate.** Opening balances follow the NOT enabled for a customer
    tenant rule of decision 0073 until slices L6 and L7 (decision 0079 D3, GH #3775).
31. **Defaults the owner may change at GATE B.** The prefix `OPN`, numbering per year, pad 6, the time zone Asia/Almaty
    for the receipt-date check, 1000 lines, the external reference pair, and a second person for every opening (owner
    may change at GATE B) (`lib/letflow/modules/stock/stock.ex`, GH #3775).
32. **Who is the preparer.** The `approve` task has `distinct_from ["submit"]`; the issue step completes `submit` as the
    issuing user. When that completion fails the `submit` task stays pending and whoever completes it is the preparer;
    the retry route `post` answers `posting_pending` while a `submit` or `approve` task is pending
    (`lib/letflow/modules/stock/documents/posting.ex`, GH #3774).
33. **No service posting of opening balances.** A posting from a service task stays refused (`ledger_origin_not_supported`)
    until slice L5; the process has no service task (decision 0079 D7, GH #3774).
34. **A repeated approval is refused, not answered with the first result.** A second `stock_opening` instance for the
    same issued version fails at `approve` on the unique mark of item 20: one entry, one mark, no second answer
    (`priv/modules/stock/entity_definitions/stock_posting_mark.json`, GH #3774).
35. **Opening lines can be imported from xlsx into a draft only.** The record import route
    (`POST /api/v1/entities/records/stock_opening_line/import?upsert_by=external_ref`, `?dry_run=true` supported) creates
    or replaces lines of a draft opening document named by the header's external id; a reference cell holds the
    external id of its target under the same external-ref system as the row. The import never posts and does not run
    the line checks of decision 0079 D3: use the check route afterwards. A row for an issued, posted or cancelled
    document is refused (`document_not_draft`); a draft has at least one line at save, so imported lines start after it
    (`lib/letflow/modules/stock/documents/opening_import.ex`, GH #3773). On screen: the type is on the Import data
    screen (`/admin/import`, stock module installed) with its template download; the draft is named by the external
    system and id entered on the opening draft form, and every row of the file repeats that system in
    `external_ref_system` and the id in `header_id` (GH T-1364).
36. **The template columns are the line field names.** `header_id`, `org_unit_id`, `location_id`, `responsible_id`,
    `catalog_item_id`, `catalog_uom_id`, `catalog_lot_id`, `quantity`, `received_on`, `unit_price`, `line_value`,
    `external_ref_system`, `external_ref_id` (decision 0077 D3); `line_no` is a definition field, so the downloaded template has it as a
    14th column, but the import ignores it: a new line takes the next number. The row's own external ref pair identifies the line inside its document. `line_invalid` is a sixth refusal
    beyond the five of the entry, for a cell the shape check refuses (GH #3773).
37. **An API token of a TENANT_ADMIN can import draft lines** although the stock document routes refuse API tokens: the
    import route needs `EntitiesRecordsImport`, not `StockPost`. The token can only write draft lines, never post; if
    `StockPost` is later granted to another role the import function needs its own check first
    (`lib/letflow/routers/entities/record_import.ex`, GH #3773).

## Assets module: asset cards

GH #3892 / REQ-750. Module `assets` writes its one record type `assets_card` only through
`Letflow.Modules.Assets.Cards` (`create_card/3`, `update_card/4`, `retire_card/3`); the generic record routes
answer 403 `entity_type_managed`. Routes under `/api/v1/modules/assets`, permission `AssetsCardWrite` (no role
grants: TENANT_ADMIN and PLATFORM_ADMIN), interactive tenant-wide callers only (`Assets.Access`; an API token or a
scoped grant gets the 404 of a tenant without the module):

- `POST /cards` (201), `PATCH /cards/:id` (200), `POST /cards/:id/retire` (200). Every body carries `idempotency_key`. `GET /cards/:id/lock` (`AssetsRead`) answers `{"posted": bool}` (T-1490); once a document naming the card is posted, a changed `inventory_number` or `kind` is 422 `inventory_number_locked` / `kind_locked` and nothing is written.
- 422 `reason`: `field_not_allowed` (`active` and unknown keys), `field_invalid`, `org_unit_not_active`,
  `valid_until_not_allowed` (only kind `intangible`), `currency_mismatch` (the tenant currency, setting `currency`,
  `KZT` by default), `card_inactive` (update or second retire of a retired card), `record_payload_invalid`
  (duplicate `inventory_number` or external reference pair, a decimal that is not strict text). 409
  `idempotency_key_reuse`; 500 `audit_failed` (the write is rolled back).
- Each accepted write appends one audit entry (`assets_card.created`, `.updated`, `.retired`). Money and depreciation
  fields are stored as the given text, never calculated. Location, quantity and responsible person are not card
  fields; they belong to the commission document (REQ-751).

## Assets module limits

Module `assets` (GH #3893 / REQ-749, assets phase C item C8, owner decision D-097) as it is on main: one ledger
registration (`assets`), a pure posting policy, two views and three read routes. Each limit names the GH issue or
the code that holds it; paths are cited without line numbers.

1. **Four documents post (C10, C11, REQ-751 to REQ-753).** The commission, the change of responsible or user, the
   hand over and the write off post to the `assets` ledger (GH #3889, #3890, #3891,
   `lib/letflow/modules/assets/documents.ex`). A document is saved, issued (numbers `ACM`, `ACH`, `AHO`, `AWO` +
   `-<year>-<n>`) and posted by completing its `post` task, and reversed by completing the `reverse` task of `POST
   /documents/:id/reverse`. A change and a hand over post two legs per line (`-q` at the from key, `+q` at the to
   key), a write off one (`-q`, with its `reason_code`). The actual user is optional in every kind, so a change or hand
   over can name an empty user to match a commissioned asset that has none. A low-value asset may be changed, handed
   over or written off in part; a fixed or intangible one only with quantity 1. A posted hand over of a fixed or
   intangible asset moves `assets_card.org_unit_id` in the same transaction (T-1489 / G2, version 0.14.0, through
   `HandlerWrites.update/3`; a `low_value` card is not moved, D-111); the balance row stays the truth, so the new kinds skip
   `org_unit_mismatch` and `asset_already_in_register`.
2. **No master checks in the ledger until slice L7.** The policy and the ledger check no asset, org unit, location
   or employee against a master, and not the kind of the card (one asset per row, no location for an intangible);
   the documents check them (decision 0073 D6, GH #3893).
3. **Scoped posting is not built.** A scoped principal cannot post (decision 0073 OQ-21, slice L6); a scoped
   reader reads the balances and movements of its own org units, a leg in a hidden unit is masked, and `reconcile`
   answers a scoped reader 404 (GH #3893, `lib/letflow/modules/assets/router.ex`).
4. **No role grants, no storage on earlier installs.** No seed, pack or QA fixture installs `assets`. A tenant that
   installed version 0.3.0 or 0.4.0 (auto-CD deploys main to QA) has no `assets` ledger partitions: the read routes
   answer empty lists, a posting would be refused `ledger_storage_missing`, and the upgrade plan lists the ledger under
   `missing_ledger_storage` (`lib/letflow/modules/upgrade_plan.ex`). The role grants of the
   four atoms (`AssetsPost`, `AssetsReverse`, `AssetsRead`, `AssetsReconcile`) are item C19, so only TENANT_ADMIN and
   PLATFORM_ADMIN hold them (`docs/roles.md`, GH #3893).
5. **Checks run at issue only.** The master checks (org unit, location link, employees, card state, fixed and
   intangible assets held once) run when the document is issued, under a per-tenant lock; a master retired between
   issue and posting is not caught until slice L7 (`lib/letflow/modules/assets/documents/checks.ex`).
6. **The posting task has no assignee.** Any holder of `AssetsPost` (TENANT_ADMIN) may claim and complete the `post`
   task; the ledger authority step decides, and a scoped principal cannot (OQ-21, slice L6).
7. **The binding gap is detected, not prevented.** The posting command is built at issue and carried in the instance
   variables; a changed variable posts but the document reads `posting_check` "mismatch" (decision 0078 D5, until
   L7). The handler never reads, so the refusal `asset_already_in_register` is a check at issue only.
8. **No cancel and no post-retry route yet.** A lost start of the posting instance after issue leaves an issued
   document with no task; a draft can be discarded, an issued one cannot be cancelled (follow-up of REQ-752). The same
   holds for a change, hand over or write off whose from key matches no balance row: it is issued, completing the
   `post` task is refused by the ledger (`insufficient_balance`), nothing is written and the task stays pending. A
   reversal of a two-leg document is refused the same way when the asset has moved on since.
9. **Upgrade needed after deploy.** An install of `assets` 0.5.0 or older has no commission record types, and one of
   0.6.0 or older has no change, hand over or write off record types or process
   definitions, and one of 0.7.0 or older has no change of kind record types, until the module upgrade (`lib/letflow/modules/upgrade_plan.ex`) is applied; until then the new write
   routes answer 500 without detail. Existing rows are not changed.
10. **The xlsx files are one page each and not promised to re-import.** The card export (`POST
   /api/v1/entities/records/assets_card/export?format=xlsx`) holds at most 200 cards and writes `org_unit_id` as a
   record id; the balances export (`GET /api/v1/modules/assets/balances?format=xlsx`) holds one page of the rows the
   caller reads, and the `next_cursor` row of its `report` sheet continues (GH #3898, REQ-763,
   `lib/letflow/modules/assets/xlsx_export.ex`).
11. **A change of kind posts two entries and creates the cards (C15 parts 2 and 3A, REQ-759, REQ-760).** The document `kind_change` (number `AKC` +
   `-<year>-<n>`) is drafted and issued on the `/documents` routes; at issue it checks the item, unit, lot,
   tracking, both locations, the asset org unit, the links, the employees, the quantity and the inventory number
   (`lib/letflow/modules/assets/documents/kind_change_checks.ex`). Issue starts the process definition
   `assets_kind_change` (modules `assets` 0.9.0 and `stock` 0.16.0); completing its `post` task runs the handlers
   `post_kind_change` and `post_kind_change_out` in ONE transaction: one `assets_card` per line, the stock entry
   (`kind_change_out`, negative legs, unit = the line unit), the asset entry (`kind_change_in`, positive legs at the
   new cards, unit `pcs`) and both posted marks, with one shared `correlation_id`. Any failure (stock below the
   quantity, missing `StockPost` or `AssetsPost`, an inventory number taken after issue) leaves nothing. The card
   ids come from the platform (`HandlerWrites.next_record_id/1`), never from the task variables. Limits: the cards
   are created through `HandlerWrites.create/3`, so no `assets_card.created` audit entry is written (the record event
   and the `ledger.posted` audit entries carry the actor) and the `Cards` rules beyond field validation are not run
   (the org unit is checked at issue); `asset_card_id` of a line is derived on read from the asset entry; the stored
   field stays empty; `posting_check` needs `StockRead` (else `null`) and detects a forged `posting` variable as
   `mismatch`. `POST /documents/:id/reverse` of a posted change of kind answers 409 `posting_inconsistent` (the pair
   reversal is part 3B); there is no cancel or retry route. A change of kind issued on QA under assets 0.8.0 has no
   instance and the next issue answers 409 `definition_not_active` until the module is reinstalled: redraft it.
   Module `assets` needs `catalog_items` and `stock` installed. Two issued documents with the same inventory
   number are not told apart until the card is created (the unique constraint settles it).
12. **The asset opening document, part 1 (G5, GH #4037, decision 0083, assets 0.10.0).** The sixth document kind `opening`
   (number `AOP` + `-<year>-<n>`) places existing cards in the register at the posting time of the document. Its header is
   `org_unit_id` and `note` (no `event_time`: a body carrying one is `field_not_allowed`); a line is `asset_id`,
   `material_responsible_id`, `quantity` and the optional `location_id` and `actual_user_id` (one line per card and
   placement; a low-value asset may be split over placements). It is saved, replaced, discarded, fetched and listed on the
   `/documents` routes. `POST /documents/:id/check` (`AssetsPost`, drafts of an opening only; writes nothing, takes no
   lock) answers `ok`, the `header` reasons and, per line, all `reasons` and `fields`
   (`lib/letflow/modules/assets/documents/opening_checks.ex`). Issue runs the same checks and refuses with the first
   failing line (422 `reason`, `line_no`, `field`); a clean opening answers 409 `posting_not_available` (nothing issued, no
   number): the process, the posting, the reversal and the register-balance half of "once" are part 2, the web screen is
   part 3. "Once" in part 1 counts issued, non-reversed commission and opening documents (`asset_already_in_register`,
   any card kind for an opening). G6 (assets 0.11.0) adds the optional external reference pair (`external_ref_system`,
   `external_ref_id`, both or neither, unique among live opening headers, 409 `external_ref_taken`) on the header and the
   line, and the xlsx import of lines: `POST /api/v1/entities/records/assets_opening_line/import?upsert_by=external_ref`
   (columns `header_id asset_id location_id material_responsible_id actual_user_id quantity`, every reference an
   external id; draft only, never posts, no D4 check; quantity above zero; 100 lines per document, 200 rows per file;
   `lib/letflow/modules/assets/documents/opening_import.ex`). The module upgrade has no window (see `demo-upgrade-notes.md`).
