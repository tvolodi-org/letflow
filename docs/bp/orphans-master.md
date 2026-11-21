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

- Read API used by other modules (the reference contract of decision 0050): `Letflow.Modules.Org.lookup/2`,
  `active?/2`, `member?/3`, `active_employee?/2`, `first_active_employee_id/1`, `employee_for_user/2`
  (`lib/letflow/modules/org/org.ex`); `Letflow.Modules.Locations.lookup/2`, `list_active/1`, `linked?/3`,
  `location_ids_for_org_unit/2`, `org_unit_ids_for_location/2` (`lib/letflow/modules/locations/locations.ex`);
  `Letflow.Modules.CatalogItems.lookup/2`, `list_active/1`, `item_uom_valid?/2`, `item_lot_valid?/2`,
  `validate_capture/3` (`lib/letflow/modules/catalog_items/catalog_items.ex`); `Letflow.Modules.Codes.lookup/2`,
  `codes_for/3`, `assignment_history/2`, `value_history/2` (`lib/letflow/modules/codes/codes.ex`). Proposed
  action for the owner: keep as platform functions (they are called by the stock and assets modules); the
  history reads `assignment_history/2` and `value_history/2` have no route and no screen in this area,
  which may deserve a "code history" process (give a process).
- Import functions called by the generic import route: covered by BP-MASTER-06 and BP-MASTER-07.
- `Letflow.Modules.Codes.Code128.encode/1` (`lib/letflow/modules/codes/code128.ex`): used by the label print
  (BP-MASTER-10) through `Labels.render/1`.
