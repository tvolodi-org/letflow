# WMS foundation runbook

Operational notes for the WMS foundation modules (decision 0050). Each module adds its own
section; REQ-507 (catalog) reuses this file.

## Org module limits

Module `org` (GH #2661 / REQ-473 skeleton, GH #2662 / REQ-506 read API) as it is on main. Each
limit names the GH issue or the code that holds it; code lines were re-read when this section
was written.

1. **Generic writes to the four types are refused.** `org_legal_entity`, `org_site`, `org_unit`
   and `org_unit_membership` are in `manages_entity_types`, so the generic entity routes answer
   403 `entity_type_managed` (GH #2530, PR #2568). The router maps
   `{:error, :entity_type_managed}` at `lib/letflow/routers/entities.ex:566`, and
   `Letflow.Entities.Records` decides it per write in `check_write_authority/3`
   (`lib/letflow/entities/records.ex:2135`, delegating to `ManagedTypes.check_record_write/3`).
2. **Writes go through the module's own Owner only, and nothing checks references.** Module
   code writes with the `/3` arity, `Records.create_record/3` with
   `ManagedTypes.owner_for!(Letflow.Modules.Org)` (`lib/letflow/entities/records.ex:417`). The
   module ships no write functions yet (the unit functions are REQ-495). References between the
   types (`legal_entity_id`, `site_id`, `parent`, `org_unit_id`) are declarative strings with no
   foreign keys and no reference check: a record can name a legal entity, site or unit that does
   not exist (decision 0050 D3.6; `priv/modules/org/entity_definitions/`).
3. **Record attachment upload and delete on a managed type are refused.** A non-owner caller
   gets the 403 `entity_type_managed` (the org types included) via
   `Letflow.Entities.RecordAccess.attachment_write/3` (GH #2582); list and content reads are
   unchanged.
4. **Client idempotency keys cannot use the reserved server-derived prefix.** The single-command
   entry points (`create_record`, `update_record`, `delete_record`) refuse, before any query, an
   `idempotency_key` that starts with the exact bytes `sys:step:` and return
   `{:error, :reserved_idempotency_key}` (`reject_step_key/1`,
   `lib/letflow/entities/records.ex:1224`; prefix `@step_key_prefix`, line 364). Only
   `command_multi/3` accepts that key family, and it has two callers:
   `lib/letflow/entities/step_writes.ex:760` and `lib/letflow/entities/handler_writes.ex:248`.
   `reject_reserved_attributes/1` (`lib/letflow/entities/records.ex:1168`) is a separate check:
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

## Catalog module limits

Module `catalog_items` (GH #2663 / REQ-474 skeleton, GH #2664 / REQ-507 read API) as it is on
main. Each limit names the GH issue or the code that holds it; code lines were re-read when
this section was written. It covers the types `catalog_uom`, `catalog_item` and `catalog_counterparty` (GH #3407, REQ-604).

1. **Generic writes to the three types are refused.** All are in `manages_entity_types`, so the
   generic entity routes answer 403 `entity_type_managed` (GH #2530, PR #2568). The router maps
   `{:error, :entity_type_managed}` at `lib/letflow/routers/entities.ex:566`, and
   `Letflow.Entities.Records` decides it per write in `check_write_authority/3`
   (`lib/letflow/entities/records.ex:2135`, delegating to `ManagedTypes.check_record_write/3`).
2. **Writes go through the module's own Owner only.** Module code writes with the `/3` arity,
   `Records.create_record/3` with `ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)`
   (`lib/letflow/entities/records.ex:417`). The module ships no write functions yet.
3. **No reference check on `base_uom_id`.** A `catalog_item` can name a `base_uom_id` that is
   not a `catalog_uom` record, is inactive or is deleted: it is a declarative string with no
   foreign key (decision 0050 D3.6;
   `priv/modules/catalog_items/entity_definitions/catalog_item.json`). `item_uom_valid?/3` is
   where an unknown or inactive unit shows up, as `false`.
4. **Record attachment upload and delete on a managed type are refused.** A non-owner caller
   gets the 403 `entity_type_managed` (all three catalog types included) via
   `Letflow.Entities.RecordAccess.attachment_write/3` (GH #2582); list and content reads are
   unchanged.
5. **Client idempotency keys cannot use the reserved server-derived prefix.** The single-command
   entry points (`create_record`, `update_record`, `delete_record`) refuse, before any query, an
   `idempotency_key` that starts with the exact bytes `sys:step:` and return
   `{:error, :reserved_idempotency_key}` (`reject_step_key/1`,
   `lib/letflow/entities/records.ex:1224`; prefix `@step_key_prefix`, line 364). Only
   `command_multi/3` accepts that key family, and it has two callers:
   `lib/letflow/entities/step_writes.ex:760` and `lib/letflow/entities/handler_writes.ex:248`.
   `reject_reserved_attributes/1` (`lib/letflow/entities/records.ex:1168`) is a separate check:
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
    `catalog_item` and `catalog_counterparty` in one call
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
    installs get all three types; `lookup/2` still works on the old tenants. Reinstalling is
    refused too (`already_installed`), so there is no operator path today: such a tenant stays
    on the two types until a module-upgrade requirement is delivered. The behaviour is pinned
    by test U-01 in `test/letflow/modules/catalog_items/counterparty_test.exs` (T-0862).
