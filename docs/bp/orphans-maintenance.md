# Orphans of the area `maintenance`

Every item of `python3 scripts/uat/bp_inventory.py maintenance` (19 items: 15 routes, 2 module write handlers,
2 pack nodes) is used by a process of `docs/bp/maintenance.json`, so there is no orphan row.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|

## Notes for the owner (not orphans)

- **Naming.** The inventory's area `maintenance` also holds three routes that are not the CMMS module:
  `GET /maintenance/v1/problem-reports`, `GET /maintenance/v1/error-groups` and
  `POST /maintenance/v1/owner-list/import` (the platform's problem-report export and owner-list import, T-1948,
  T-1951, T-1963). They are covered by BP-MAINTENANCE-12, -13 and -20. They would sit better in the `platform`
  area; moving them is a change of `AREAS` in `scripts/uat/bp_inventory.py`, not decided here.
- **Screens.** The inventory lists no screen: `web/src` has no maintenance route and `apps/mobile` no maintenance
  screen. The screens are requirements REQ-898, REQ-899 and REQ-900 (entries BP-MAINTENANCE-09..11, status
  `planned`). "My work orders" does not exist yet; today the technician works from the core inbox (BP-MAINTENANCE-06).
- **Runner scenarios.** None written (`scenario: null`). The release flag `:maintenance_enabled` is false on QA and
  production, the actor roster has no tenant with the module installed or a technician login, and the runner has no
  multipart step, so a dry run on QA could only fail on a 404. The security processes (BP-MAINTENANCE-14..21) are
  `automation: planned` for that reason; they are covered by ExUnit tests named in each entry's `tests` field.
