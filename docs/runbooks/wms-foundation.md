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
   (`lib/letflow/entities/records.ex:2047`, delegating to `ManagedTypes.check_record_write/3`).
2. **Writes go through the module's own Owner only, and nothing checks references.** Module
   code writes with the `/3` arity, `Records.create_record/3` with
   `ManagedTypes.owner_for!(Letflow.Modules.Org)` (`lib/letflow/entities/records.ex:412`). The
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
   `lib/letflow/entities/records.ex:1159`; prefix `@step_key_prefix`, line 359). Only
   `command_multi/3` accepts that key family, and it has two callers:
   `lib/letflow/entities/step_writes.ex:760` and `lib/letflow/entities/handler_writes.ex:248`.
   `reject_reserved_attributes/1` (`lib/letflow/entities/records.ex:1103`) is a separate check:
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
this section was written. It covers the types `catalog_uom` and `catalog_item`.

1. **Generic writes to the two types are refused.** Both are in `manages_entity_types`, so the
   generic entity routes answer 403 `entity_type_managed` (GH #2530, PR #2568). The router maps
   `{:error, :entity_type_managed}` at `lib/letflow/routers/entities.ex:566`, and
   `Letflow.Entities.Records` decides it per write in `check_write_authority/3`
   (`lib/letflow/entities/records.ex:2047`, delegating to `ManagedTypes.check_record_write/3`).
2. **Writes go through the module's own Owner only.** Module code writes with the `/3` arity,
   `Records.create_record/3` with `ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)`
   (`lib/letflow/entities/records.ex:412`). The module ships no write functions yet.
3. **No reference check on `base_uom_id`.** A `catalog_item` can name a `base_uom_id` that is
   not a `catalog_uom` record, is inactive or is deleted: it is a declarative string with no
   foreign key (decision 0050 D3.6;
   `priv/modules/catalog_items/entity_definitions/catalog_item.json`). `item_uom_valid?/3` is
   where an unknown or inactive unit shows up, as `false`.
4. **Record attachment upload and delete on a managed type are refused.** A non-owner caller
   gets the 403 `entity_type_managed` (both catalog types included) via
   `Letflow.Entities.RecordAccess.attachment_write/3` (GH #2582); list and content reads are
   unchanged.
5. **Client idempotency keys cannot use the reserved server-derived prefix.** The single-command
   entry points (`create_record`, `update_record`, `delete_record`) refuse, before any query, an
   `idempotency_key` that starts with the exact bytes `sys:step:` and return
   `{:error, :reserved_idempotency_key}` (`reject_step_key/1`,
   `lib/letflow/entities/records.ex:1159`; prefix `@step_key_prefix`, line 359). Only
   `command_multi/3` accepts that key family, and it has two callers:
   `lib/letflow/entities/step_writes.ex:760` and `lib/letflow/entities/handler_writes.ex:248`.
   `reject_reserved_attributes/1` (`lib/letflow/entities/records.ex:1103`) is a separate check:
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
