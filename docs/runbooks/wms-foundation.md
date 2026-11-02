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
   (`lib/letflow/entities/records.ex:2223`, delegating to `ManagedTypes.check_record_write/3`).
2. **Writes go through the module's own Owner only, and nothing checks references.** Module
   code writes with the `/3` arity, `Records.create_record/3` with
   `ManagedTypes.owner_for!(Letflow.Modules.Org)` (`lib/letflow/entities/records.ex:423`). The
   module has owner-path write functions for legal companies and sites only (GH #3619 / REQ-660, item 12); the unit functions are REQ-495. References between the
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
   `lib/letflow/entities/records.ex:1292`; prefix `@step_key_prefix`, line 368). Only
   `command_multi/3` accepts that key family, and it has two callers:
   `lib/letflow/entities/step_writes.ex:760` and `lib/letflow/entities/handler_writes.ex:248`.
   `reject_reserved_attributes/1` (`lib/letflow/entities/records.ex:1235`) is a separate check:
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
   targets are active is checked by the write functions of REQ-661.
9. **One term for the person in charge.** The "materially responsible person"
   (`material_responsible`) and the "actual user" (`actual_user`) are each an `org_employee` record
   id, never a Letflow user id; a writer checks one with `Letflow.Modules.Org.active_employee?/2`,
   and `employee_for_user/2` finds the employee of a user (GH #3584).
10. **No write function, route or import yet.** The two types are written only through the Owner
    path; the write functions, the roster import and the routes are later slices, and
    `scope_declarations` (employees and positions scoped by `org_unit_id`) is inert until REQ-519
    (GH #3584).
11. **Tenants that installed org before 0.2.0 are not upgraded.** Module install is first-install
    only (`Letflow.Modules.Installs`), so such a tenant has no `org_employee` or `org_position`
    definition, and reactivating an uninstalled org there answers `upgrade_required`
    (`check_reactivatable/2`). The upgrade is owed by REQ-642 point 7, in the shape of
    `Letflow.Modules.Exam.ParentRollout`; no phase A entry builds it (GH #3584).
12. **Legal companies and sites have owner-path write functions; there is still no route.**
    `Letflow.Modules.Org.create_legal_entity/3`, `update_legal_entity/4`, `retire_legal_entity/3`,
    `create_site/3`, `update_site/4` and `retire_site/3` (logic in `Letflow.Modules.Org.Masters`,
    GH #3619 / REQ-660) write through the org Owner, one audit entry per accepted change, nothing on
    a refusal. The BIN is exactly 12 ASCII digits with no control digit (UAT assumption, to be
    confirmed by the process owner: D-065 says "12 digits, validated" and names no checksum), and two
    active companies of one tenant never share a BIN (`:bin_taken`, checked under an advisory lock
    keyed by tenant and the text `org_legal_entity_bin`; a retired company's BIN may be reused).
    `code` is immutable; retire is `active` false and is refused while an active site or unit names
    the record (UAT assumption, same status). The functions are reached by no route yet (REQ-665);
    tenants that installed org before the pack carried these definitions are not upgraded.

## Catalog module limits

Module `catalog_items` (GH #2663 / REQ-474 skeleton, GH #2664 / REQ-507 read API) as it is on
main. Each limit names the GH issue or the code that holds it; code lines were re-read when
this section was written. It covers the types `catalog_uom`, `catalog_item`, `catalog_counterparty` (GH #3407, REQ-604) and `catalog_lot` (GH #3593, REQ-647).

1. **Generic writes to the four types are refused.** All are in `manages_entity_types`, so the
   generic entity routes answer 403 `entity_type_managed` (GH #2530, PR #2568). The router maps
   `{:error, :entity_type_managed}` at `lib/letflow/routers/entities.ex:566`, and
   `Letflow.Entities.Records` decides it per write in `check_write_authority/3`
   (`lib/letflow/entities/records.ex:2223`, delegating to `ManagedTypes.check_record_write/3`).
   The one exception is the import route (item 2).
2. **Writes go through the module's own Owner only; the three masters are imported through the
   managed import path (GH #3602, REQ-651).** Module code writes with the `/3` arity,
   `Records.create_record/3` with `ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)`
   (`lib/letflow/entities/records.ex:423`); the only such caller is
   `lib/letflow/modules/catalog_items/import.ex`. `catalog_uom`, `catalog_item` and
   `catalog_counterparty` register `Letflow.Modules.CatalogItems.import_row/3` in the manifest key
   `:import_functions`; `POST /entities/records/:entity_type/import` calls it once per row through
   `Catalog.call_import_function/5` (`Letflow.Entities.ManagedImport`). Upsert by external ref only
   (`upsert_by` absent is 422), a reference cell holds the external id of the target, and
   `?dry_run=true` runs the file and rolls it back (decision 0077 D5 to D7). `catalog_lot` has no
   import function: its writers are the lot write functions (item 20, GH #3614) and the generic route still answers 403 (REQ-654).
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
   `lib/letflow/entities/records.ex:1292`; prefix `@step_key_prefix`, line 368). Only
   `command_multi/3` accepts that key family, and it has two callers:
   `lib/letflow/entities/step_writes.ex:760` and `lib/letflow/entities/handler_writes.ex:248`.
   `reject_reserved_attributes/1` (`lib/letflow/entities/records.ex:1235`) is a separate check:
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
17. **Lots cannot be seeded by the generic import.** `POST /entities/records/catalog_lot/import`
    answers 403 `entity_type_managed` (`lib/letflow/routers/entities/record_import.ex`); the
    import path for managed types is open (GH #3593).
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
    one audit entry (`catalog_lot.created`, `catalog_lot.updated`, `catalog_lot.retired`); there is
    no route and no permission. A retired lot may still be updated, retiring a retired lot writes
    nothing, and nothing checks stock (there is no stock ledger on main). Writers for the item,
    unit and supplier types are the import slice A6b.

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
3. **Tree rules are enforced by the module functions.** `create_node/3` refuses a parent that is not
   found or inactive; `move_node/4` is one parent change of one record and refuses a cycle by walking
   the parent chain; `retire_node/3` refuses while a descendant is active. A subtree is read with
   `descendant_ids/2`, one recursive query. The tree is the parent link only: a real foreign key
   (`priv/modules/locations/entity_definitions/location_node.json`), no stored path, no stored depth
   and no depth bound (decision 0066). Addresses are not rewritten on a move or a segment change
   (GH #3588).
4. **No `org_site_id`.** The field was removed from `location_node`; the link between the org tree
   and the location tree is a later step of the assets application (phase A4), and the manifest
   does not depend on `org` (GH #3591).
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

9. **The import of the tree is `import_row/3`, upsert by external ref only.** The core import route
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
3. **Write functions exist, routes do not.** Receive, assign, release, retire and change value are
   in `lib/letflow/modules/codes/writes.ex` (REQ-663, GH #3615); the scan route is REQ-667 (GH #3588).
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
