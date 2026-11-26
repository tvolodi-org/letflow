# Orphans of the area mes

The inventory of the area `mes` is empty (`python3 scripts/uat/bp_inventory.py mes` prints `[]`):
`mes_core` has no router, screen, pack node, handler, script or rule file. There is nothing to list.
When MES plan tasks M2..M11 add functions, rerun the inventory and the catalog check.

Orphan review D-169 (T-2561, 2026-11-21): re-run `python3 scripts/uat/check_catalog.py mes` on this tree: 100%, no orphan item; no entry to decide.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|

Gaps (T-2554, D-168, 2026-11-21): processes that stay partial or planned, and why.
- BP-MES-01 (partial): the install of mes_core cannot be scripted for a shared QA company because it cannot be undone (uninstall route off: config/config.exs:188; installs.ex:159). Missing in the product: the uninstall flag on in QA, or a disposable tenant.
- BP-MES-04 (planned): mes_core has no routes, screens, handlers, permissions, uploads, webhooks or approval (lib/letflow/modules/mes_core/mes_core.ex). Missing in the product: plan tasks M2..M11 (docs/design/mes/13-phase1-plan.md).
- BP-MES-03 is implemented by test/uat/processes/SEC-MES-03-module-management-per-role.json (storekeeper refused on seven routes).
