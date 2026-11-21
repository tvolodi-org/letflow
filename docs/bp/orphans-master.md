# Orphans of the area `master` (org, locations, catalog_items, codes)

No inventory item of the area is an orphan: `python3 scripts/uat/bp_inventory.py master` lists 44 items
(33 write or lookup routes of the four module routers and 11 screens) and every one is used by a task of
`docs/bp/master.json` (`python3 scripts/uat/check_catalog.py master`: COVERAGE 44/44). The table below is
therefore empty on purpose; a row would have to match an inventory item or the check calls it stale.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|

## Observations (not inventory items, so not rows)

`bp_inventory.py` lists routes, screens, pack nodes, handlers, scripts and rule files. The four modules have
none of the last four kinds today, but they also hold functions that no route or screen of this area calls.
They are read or import functions for other modules and are NOT judged here; the owner decides whether each
needs a process of its own. Each was found by reading the module file (`grep -n "  def "`), not by a call-graph
tool, so a caller in another area may exist.

- Read API of the four modules (decision 0050), callers checked with `grep -rn` over `lib/` outside the four module directories:
  - used by stock and/or assets: `Org.lookup/2` (stock/document_print_source.ex:91), `Org.active?/2` (assets/cards.ex:301),
    `Org.active_employee?/2` (assets/counts.ex:565), `Org.first_active_employee_id/1` (stock/old_app_writes.ex:636),
    `Org.employee_for_user/2` (stock/count_differences.ex:542), `Locations.lookup/2` (stock/stock_workbook.ex:384),
    `Locations.list_active/1` (stock/old_app_reads.ex:91), `Locations.linked?/3` (assets/documents/checks.ex:184),
    `Locations.location_ids_for_org_unit/2` (stock/counts.ex:783), `Locations.org_unit_ids_for_location/2`
    (stock/old_app_writes.ex:624), `CatalogItems.lookup/2` (stock/document_print_source.ex:98), `CatalogItems.list_active/1`
    (stock/voice_service.ex:191), `item_uom_valid?/3` (stock/documents/checks.ex:177), `item_lot_valid?/3`
    (stock/documents/opening_checks.ex:58), `validate_capture/3` (stock/documents/checks.ex:219), `Codes.codes_for/3`
    (stock/stock_workbook.ex:392), `Codes.resolve/2` (stock/count_sheet.ex:558). Proposed action: keep as platform functions.
  - NO production caller: `Letflow.Modules.Org.member?/3` (`lib/letflow/modules/org/org.ex:228`; only its definition is found by
    `grep -rn 'member?(' lib`) and `Letflow.Modules.Codes.value_history/2` (`lib/letflow/modules/codes/codes.ex`; callers only in
    tests: writes_lifecycle_test.exs:141, read_api_test.exs:164). Proposed action for the owner: give a process (a "code history" screen
    for value_history) or keep as platform read API; member?/3 may be removed only after the owner confirms (it is part of the 0050 contract).
  - Called only inside its own module: `Codes.lookup/2` (used by the codes router labels action) and `Codes.assignment_history/2`
    (codes/writes.ex:511, codes/import_assignment.ex:146). Proposed action: keep; assignment_history has no route or screen of its own.
- Import functions called by the generic import route: covered by BP-MASTER-06 and BP-MASTER-07.
- `Letflow.Modules.Codes.Code128.encode/1` (`lib/letflow/modules/codes/code128.ex`): used by the label print
  (BP-MASTER-10) through `Labels.render/1`.

## Gaps that keep security entries partial (T-2552)

Not orphans: these are things the product or the runner lacks, so a map entry stays `partial`.

- BP-MASTER-14: a runner step that sends no credential, a malformed header or an expired token (runner feature, `auth: none`/`bad`). Meanwhile: Elixir auth pipeline tests; the other-company token is walked in BP-MASTER-12 and SEC-ID-02.
- BP-MASTER-15: a runner step that sends a file body (xlsx, CSV) for the xlsx/csv limits (runner feature, file upload). Meanwhile: JSON limits walked in BP-MASTER-15; Elixir import tests.
- BP-MASTER-16: a QA tenant with a record type whose scope is not tenant-wide (environment fixture). Meanwhile: unknown and retired code walked in BP-MASTER-16; Elixir resolve_router_test.
