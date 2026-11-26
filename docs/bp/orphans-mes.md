# Orphans of the area mes

The inventory of the area `mes` is empty (`python3 scripts/uat/bp_inventory.py mes` prints `[]`):
`mes_core` has no router, screen, pack node, handler, script or rule file. There is nothing to list.
When MES plan tasks M2..M11 add functions, rerun the inventory and the catalog check.

Orphan review D-169 (T-2561, 2026-11-21): re-run `python3 scripts/uat/check_catalog.py mes` on this tree: 100%, no orphan item; no entry to decide.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
