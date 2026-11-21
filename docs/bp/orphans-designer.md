# Orphans of the designer area

Inventory items of the area `designer` that no business process uses: none.

Every one of the 181 inventory items (153 routes, 18 screens, 10 script modules) is named by a task of at least one of
the processes `BP-DESIGNER-01` to `BP-DESIGNER-33` in `docs/bp/designer.json`. Where a route is used only by a security
process (for example `GET /api/public/:kind/:handle`, `POST /instances/:id/reconstruct`) it is still a task there.

Items with no router test and so listed as `partial`, not as orphans: `GET /api/v1/services` (`BP-DESIGNER-23`) and
`POST /api/v1/public-read-handles` (`BP-DESIGNER-22`): no file under `test/letflow/routers/` exercises them directly
(only the route-scope inventory tests name them).

Orphan review D-169 (T-2561, 2026-11-21): re-run `python3 scripts/uat/check_catalog.py designer` on this tree: 100%, no orphan item; no entry to decide.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
