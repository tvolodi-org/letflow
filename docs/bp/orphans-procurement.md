# Orphans of the procurement area

Every inventory item of the area (the 14 routes of `lib/letflow/modules/procurement/router.ex`) is used by at least
one process of `docs/bp/procurement.json`, so there are no orphans.

The inventory lists routes only: the module has no pack, no screens, no write handlers and no `*rules*`/`*policy*`
files (`python3 scripts/uat/bp_inventory.py procurement --summary` gives `{"route": 14}`). Two notes for the owner:

- There is no procurement screen in `web/src`; every process is an API process.
- `PurchaseRequests.create/3`, `submit_for_bpm/3` and `revise/4` are reached from the routes; `update_draft/4` and
  `submit/3` of the same module are context functions that no route calls (checked with
  `grep -rn "update_draft\|PurchaseRequests.submit(" lib/`). They are not in the inventory (the inventory has no
  function-level item for this module), so they are not orphans by the tool's definition; the owner may want a route
  or their removal.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
