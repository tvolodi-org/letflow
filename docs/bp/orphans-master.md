# Orphans of the area `master` (org, locations, catalog_items, codes)

No inventory item of the area is an orphan: `python3 scripts/uat/bp_inventory.py master` lists 44 items
(33 write or lookup routes of the four module routers and 11 screens) and every one is used by a task of
`docs/bp/master.json` (`python3 scripts/uat/check_catalog.py master`: COVERAGE 44/44). The table below is
therefore empty on purpose; a row would have to match an inventory item or the check calls it stale.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|

## Orphan review (BA, D-169, T-2560, 2026-11-21): decision for every entry

The inventory has no orphan row (44/44 covered). The entries below are the function-level observations of the earlier
version of this file plus the `docs/bp/dead-code.json` rows of area `master`. They are NOT table rows because the table
accepts only inventory items (`check_catalog.py` calls any other row stale). Each was re-checked with `grep -rn` over
`lib/`, `test/` and `web/src` and `git log -S` on the file. Nothing is deleted; real orphans are for the owner to see first.

**(b) Infrastructure: read API of decision 0050, used by stock and assets (leaves the list; keep as platform functions).**
`Org.lookup/2`, `Org.active?/2`, `Org.active_employee?/2`, `Org.first_active_employee_id/1`, `Org.employee_for_user/2`,
`Locations.lookup/2`, `Locations.list_active/1`, `Locations.linked?/3`, `Locations.location_ids_for_org_unit/2`,
`Locations.org_unit_ids_for_location/2`, `CatalogItems.lookup/2`, `CatalogItems.list_active/1`, `item_uom_valid?/3`,
`item_lot_valid?/3`, `validate_capture/3`, `Codes.codes_for/3`, `Codes.resolve/2`. Each has a production caller in
`lib/letflow/modules/stock` or `assets` (callers listed in the previous version of this file, e.g.
stock/document_print_source.ex:91, assets/cards.ex:301); they run inside the processes of the stock and assets areas
(BP-STOCK / BP-ASSETS tasks), not as master-data tasks.

**(a) Used, and in the map (leaves the list).**
- `Codes.lookup/2` (`lib/letflow/modules/codes/codes.ex:185`): called by the codes router at `router.ex:167` (label print),
  so it is a function of BP-MASTER-10 "Print code labels".
- `Codes.assignment_history/2` (`codes.ex:267`): called by `writes.ex:511` (release/assign check of open assignments) and
  `import_assignment.ex:146` (import), so it is a system function of BP-MASTER-09 and BP-MASTER-07.
- `Codes.Code128.encode/1` (`code128.ex`): used by `labels.ex` through `Labels.render/1`, BP-MASTER-10.
- Import functions behind the generic import route: BP-MASTER-06 and BP-MASTER-07.

**(c) Real orphans (no production caller; kept, with proposal).**
- `Letflow.Modules.Org.member?/3` (`lib/letflow/modules/org/org.ex:228`). What: true when a user is an active member of an
  org unit. Callers: tests only (`test/letflow/modules/org/read_api_test.exs:229..263`); `grep -rn "Org.member?" lib` finds
  only a docstring (`catalog_items.ex:167`). History: added 2026-10-19, `d7f7eefb4` (GH #2662, REQ-506, "org read API
  (lookup, active?, member?)"); reworked 2026-11-02 in `eaa1f1e49` (GH #3584, REQ-643). Why it exists: part of the 0050 read
  contract so a later module can scope by unit. Proposal: KEEP as a platform read API until a process needs unit-scoped
  access; removal only after the owner confirms.
- `Letflow.Modules.Codes.value_history/2` (`codes.ex:288`). What: the list of value changes of a code. Callers: tests only
  (`writes_lifecycle_test.exs:141`, `read_api_test.exs:164,209,230,238`); no route, no screen. History: added 2026-11-02,
  `d9f967f71` (GH #3588, REQ-648, codes skeleton "with a status and a value history"). Why: the history is written by
  BP-MASTER-09 (rewrite of a tag) but nothing shows it. Proposal: GIVE A PROCESS (a "code history" view) or keep as read API.
- `Letflow.Modules.Locations.descendant_ids/2` (`locations.ex:138`, a `defdelegate`; dead-code.json reason `test_only`).
  Callers of the delegate: tests only; production code calls `Locations.Tree.descendant_ids/2` directly
  (`assets/counts.ex:587`, `assets/count_freeze.ex:72`). History: added 2026-11-02, `a9b6d5ed2` (GH #3588, REQ-646, "subtree
  read by one recursive query"). Proposal: KEEP as the public face of the Tree function (moduledoc line 22 names it); owner may
  remove the delegate and point tests at `Tree`.

## Gaps that keep security entries partial (T-2552)

Not orphans: these are things the product or the runner lacks, so a map entry stays `partial`.

- BP-MASTER-14: a runner step that sends no credential, a malformed header or an expired token (runner feature, `auth: none`/`bad`). Meanwhile: Elixir auth pipeline tests; the other-company token is walked in BP-MASTER-12 and SEC-ID-02.
- BP-MASTER-15: a runner step that sends a file body (xlsx, CSV) for the xlsx/csv limits (runner feature, file upload). Meanwhile: JSON limits walked in BP-MASTER-15; Elixir import tests.
- BP-MASTER-16: a QA tenant with a record type whose scope is not tenant-wide (environment fixture). Meanwhile: unknown and retired code walked in BP-MASTER-16; Elixir resolve_router_test.
