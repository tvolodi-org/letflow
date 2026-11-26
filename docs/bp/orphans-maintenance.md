# Orphans of the area `maintenance`

Every item of `python3 scripts/uat/bp_inventory.py maintenance` (19 items: 15 routes, 2 module write handlers,
2 pack nodes) is used by a process of `docs/bp/maintenance.json`, so there is no orphan row.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
| route `admin/maintenance` (container) | `web/src/modules/maintenance/maintenanceRoutes.tsx:16` | parent route of the three request screens; it has no page of its own, it only groups `requests`, `requests/new`, `requests/:id` | REQ-898, commit 6e6c35f7c (#5099) | route nesting in the router, not a user task | keep as a platform function |

## Orphan review (BA, D-169, T-2560, 2026-11-21): decision for every entry

`python3 scripts/uat/bp_inventory.py maintenance` lists 19 items, all used by a process of `docs/bp/maintenance.json`
(`check_catalog.py maintenance`: 19/19). `docs/bp/dead-code.json` has no function row for `modules/maintenance`
(checked with a filter on the file path). So the area has no orphan; the entries below are the earlier notes, each decided.
Nothing is deleted.

- (a) USED, in the map: the three routes `GET /maintenance/v1/problem-reports`, `GET /maintenance/v1/error-groups`,
  `POST /maintenance/v1/owner-list/import` (T-1948, T-1951, T-1963) belong to BP-MAINTENANCE-12, -13 and -20. They are
  platform functions that only share the URL prefix; moving them to the `platform` area is a change of `AREAS` in
  `scripts/uat/bp_inventory.py`, which this task may not change, so it is left to the owner.
- (b) INFRASTRUCTURE / planned, not orphan: the screens "my work orders" and the technician screens are requirements
  REQ-898, REQ-899, REQ-900 (entries BP-MAINTENANCE-09..11, status `planned`); `web/src` has no maintenance route and
  `apps/mobile` no maintenance screen, so the inventory has no screen item to cover. Today the technician works from the core inbox (BP-MAINTENANCE-06).
- Runner scenarios: none (`scenario: null`). The flag `:maintenance_enabled` is false on QA and production, the roster has
  no tenant with the module installed or a technician login, and the runner has no multipart step; that is a runner/environment
  task, not an orphan. BP-MAINTENANCE-14..21 stay `automation: planned` and are covered by the ExUnit tests in each entry's `tests`.
