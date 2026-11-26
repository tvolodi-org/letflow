# Orphans of the area tenant-admin

Every inventory item of the area but one (88 routes, 11 business rules, 20 screens) is named by at least one process
task in `docs/bp/tenant-admin.json`; the one exception is the row below. Checked with
`python3 scripts/uat/check_catalog.py tenant-admin` (COVERAGE 119/119).

Partial entries and why (T-2550; the machine-readable form is the `gaps` field of each entry in `docs/bp/tenant-admin.json`):

- BP-TENANT-ADMIN-31 (screens only, no browser step in the runner), -33, -34, -41, -44 (routes at the root of a two-part prefix
  that the runner's static check cannot match), -35, -37, -40 (need a per-step Authorization, a request without a credential
  or a service principal: runner tasks), -36 (root route and a state change of a shared tenant), -38 (no file-upload step kind),
  -47 (no hand-over of a task id between actors). None of them is a missing product feature.

Items covered only by a weak reason (the owner may want to give them a real process or retire them):

- `GET /api/v1/me/memberships`, `GET /api/v1/me/modules`, `GET /api/mobile/tenant-config`: used as part of sign-in and
  mobile start-up (BP-TENANT-ADMIN-01, -02, -17); no scenario drives them yet.
- Screens `admin/print-templates`, `admin/official-forms`, `admin/import` are listed in BP-TENANT-ADMIN-31 (status partial):
  their data routes belong to the documents and entities areas and are not tasks of this area.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
| GET /api/v1/notification-templates/catalogue | lib/letflow/routers/notification_templates.ex:60 | reads the compiled catalogue of the registered notification template keys and the placeholder allow-list of each | T-2600 (pilot gap G5b), commit c0b6d37ae, 2026-11-23 | the designer's notification-step editor reads it to offer the templates a service step may use; the tenant's own text stays behind the route of BP-TENANT-ADMIN-26, and no designer-area process of that editor exists yet | give a process |
| GET /api/v1/outbound-destinations | lib/letflow/routers/outbound_destinations.ex:34 | lists the tenant allow-list of outbound channels and recipient domains | T-2597 (pilot gap G14), 2026-11-24 | deny-by-default guardrail: only the holder of OutboundDestinationsManage changes what a definition may send to; no process of the tenant-admin area drives it yet | give a process |
| POST /api/v1/outbound-destinations | lib/letflow/routers/outbound_destinations.ex:41 | adds a channel or a recipient domain to the allow-list | T-2597 (pilot gap G14), 2026-11-24 | deny-by-default guardrail: only the holder of OutboundDestinationsManage changes what a definition may send to; no process of the tenant-admin area drives it yet | give a process |
| DELETE /api/v1/outbound-destinations | lib/letflow/routers/outbound_destinations.ex:55 | removes an allow-list entry | T-2597 (pilot gap G14), 2026-11-24 | deny-by-default guardrail: only the holder of OutboundDestinationsManage changes what a definition may send to; no process of the tenant-admin area drives it yet | give a process |

Review T-2559 (D-169): the five weakly covered items above are decided as (a) USED: the three routes are called by the
sign-in and mobile start-up tasks (BP-TENANT-ADMIN-01, -02, -17, code_refs resolve per check_catalog), and the three
screens are listed in BP-TENANT-ADMIN-31 (partial). None is a real orphan; the gap is a missing runner scenario, not
missing use. Nothing removed.
