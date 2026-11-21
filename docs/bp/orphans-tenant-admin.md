# Orphans of the area tenant-admin

Every inventory item of the area (87 routes, 11 business rules, 20 screens) is named by at least one process task in
`docs/bp/tenant-admin.json`, so there is no orphan row. Checked with `python3 scripts/uat/check_catalog.py tenant-admin`
(COVERAGE 118/118).

Items covered only by a weak reason (the owner may want to give them a real process or retire them):

- `GET /api/v1/me/memberships`, `GET /api/v1/me/modules`, `GET /api/mobile/tenant-config`: used as part of sign-in and
  mobile start-up (BP-TENANT-ADMIN-01, -02, -17); no scenario drives them yet.
- Screens `admin/print-templates`, `admin/official-forms`, `admin/import` are listed in BP-TENANT-ADMIN-31 (status partial):
  their data routes belong to the documents and entities areas and are not tasks of this area.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
