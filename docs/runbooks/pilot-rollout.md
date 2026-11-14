# Runbook: rolling out a pilot company (assets and stock counting)

Spec: REQ-786. This page is the order of work for the day the owner starts a pilot. It starts nothing itself.

## Status

- No pilot company or dealer is named yet. The brief is `ai-dala-portfolio/architectures/assets.md`, section "Customers and rollout".
- Production is not approved (D-086, "Not lifted: production"). The set-up of production is in `docs/runbooks/production-readiness.md`.
- This page creates no tenant, installs no module and changes no setting. It is a plan to read, not a script to run.
- Numbers the owner has not given (support hours, response times, pilot length, data volumes, number of users) are not invented here; they are listed under "Open owner questions".

## Before the pilot starts

All four must hold. If one does not, the pilot does not start.

1. Production is approved and set up as `docs/runbooks/production-readiness.md` describes. Source: that file (link above) and D-086.
2. The PILOT GATE row of `docs/migration/decisions/0073-domain-neutral-ledger-primitive.md` is met (slices L6 and L7 done). The record says: "The stock module is NOT enabled for a customer tenant until L6 AND L7 are done". Source: decision 0073, Consequences table, row PILOT GATE.
3. Serial-tracked goods stay out of the pilot until OQ-23 of the same record (decision 0073) is resolved. Source: decision 0073, PILOT GATE row.
4. The owner has passed the gate of phase F (D-063: each phase ends with the owner's check). Source: portfolio decision D-063.

## Onboarding

Ordered steps. Each step is done once the one before it is done.

1. Create the tenant and its realm by the steps of `docs/runbooks/onboarding-new-tenant-realm.md`, section "Ordered steps". Those steps are not repeated here.
2. Set the tenant type to `production` as the same runbook says in its section "Tenant type (REQ-469)". Only a platform administrator of the platform tenant can change it.
3. Install the modules, in the order of the next subsection.
4. Create the first users. Options: one by one on the Users screen, or the xlsx users import (`POST /identity/users/import`, permission `UsersManage`). Roles used by the pilot company are `TENANT_ADMIN` (the company administrator), `STOREKEEPER` (the storekeeper) and `TENANT_AUDITOR` (read-only). No user of the pilot company or of a dealer is given PLATFORM_ADMIN: platform authority belongs to the platform tenant only (`docs/roles.md`).
5. Sign-in per company: pending the sign-in choice (task T-1359, held by the PM). Nothing is built for it here. Read `docs/runbooks/production-readiness.md`, section "Sign-in per company", and `docs/runbooks/pilot-first-month.md`, section "Interim sign-in path for created users".
6. Four eyes, decided per company before its opening documents are issued: a company where one person both issues and approves needs the four-eyes rule of the opening approval switched off; otherwise it stays on (the default). The company administrator switches it, through the new tenant-wide permission of `docs/design/four-eyes-switch.md` (planned, not yet on main; working name `ApprovalRulesManage`), and gives a reason; afterwards check the audit log for one `approval_rule.changed` entry and, for each opening the same person approved, one entry with the note "self-approved, four-eyes off". Stock-only companies: see `docs/status/qoimeks-migration-readiness.md`, section 1.4.

### Module install order

Every module comes after each id in its manifest's `depends_on`. The test `test/letflow/pilot_rollout_runbook_test.exs` checks this against the manifests.

1. `org`
2. `catalog_items`
3. `codes`
4. `locations`
5. `stock`
6. `assets`

## Data load

Load in the order of the table. Use the xlsx import (Admin > Import data) with a dry run first, then the real run; see `docs/assets/asset-xlsx.md` and `docs/runbooks/qoimeks-rehearsal.md`. A record type with File import `no` has no xlsx import function and is entered by hand in the generic entity screens or the API. The column File import is checked against `Letflow.Modules.Catalog.import_function/2` by the test.

| Order | Record type | Module | File import | How it comes in | Source |
|---|---|---|---|---|---|
| 1 | `org_legal_entity` | `org` | no | by hand in the generic entity screens | `lib/letflow/modules/org/org.ex` |
| 2 | `org_site` | `org` | no | by hand in the generic entity screens | `lib/letflow/modules/org/org.ex` |
| 3 | `org_unit` | `org` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/org/org.ex` |
| 4 | `org_unit_membership` | `org` | no | by hand in the generic entity screens | `lib/letflow/modules/org/org.ex` |
| 5 | `org_position` | `org` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/org/org.ex` |
| 6 | `org_employee` | `org` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/org/org.ex` |
| 7 | `catalog_uom` | `catalog_items` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/catalog_items/catalog_items.ex` |
| 8 | `catalog_item` | `catalog_items` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/catalog_items/catalog_items.ex` |
| 9 | `catalog_counterparty` | `catalog_items` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/catalog_items/catalog_items.ex` |
| 10 | `catalog_lot` | `catalog_items` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/catalog_items/catalog_items.ex` |
| 11 | `code_tag` | `codes` | no | by hand in the generic entity screens, after the module is installed | `lib/letflow/modules/codes/codes.ex` |
| 12 | `code_assignment` | `codes` | no | by hand in the generic entity screens, after the module is installed | `lib/letflow/modules/codes/codes.ex` |
| 13 | `code_value_change` | `codes` | no | by hand in the generic entity screens, after the module is installed | `lib/letflow/modules/codes/codes.ex` |
| 14 | `location_node` | `locations` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/locations/locations.ex` |
| 15 | `location_org_unit_link` | `locations` | no | by hand in the generic entity screens | `lib/letflow/modules/locations/locations.ex` |
| 16 | `stock_opening_line` | `stock` | yes | xlsx import (Admin > Import data), dry run first | `lib/letflow/modules/stock/stock.ex` |
| 17 | `assets_card` | `assets` | yes | xlsx import (Admin > Import data), dry run first | `docs/assets/asset-xlsx.md` section 1 |
| 18 | `assets_opening_line` | `assets` | yes | xlsx import (Admin > Import data), dry run first | `docs/assets/asset-xlsx.md` section 5a |

Rules for the opening balances:

- Opening documents post at their posting time. The real receipt or acquisition date is kept as a field, not as a backdated posting (decision 0079 D1 and decision 0083 D1, both "No backdating").
- Asset cards are imported before the asset opening lines that place them (`docs/assets/asset-xlsx.md`, section 5a).
- Old assets arrive by the xlsx import (D-097 item 3). The Qoimeks conversion tooling `scripts/pilot/qoimeks_convert.py` exists and is only linked here, not changed.

## Printed forms

The pilot company is shown these forms:

- Z-1, Z-2, Z-3, Z-4, Z-5, Z-6, Z-7
- Inv-1, Inv-3, Inv-7, Inv-10, Inv-18
- DA-1, DA-2, DA-3, DA-4
- Inv-8, Inv-16

What each form prints and what is still missing is in `docs/assets/kz-forms-mapping.md`, section 4. No form text is copied here. The layouts follow the 2026 draft forms of the KZ Ministry of Finance. If the final order text differs from the drafts, the operator is asked (the caveat in section 0 of that file).

## Support

A problem the pilot company finds reaches the register as a GitHub issue of `tvolodi-org/letflow`, filed by the operator. This is a proposal, to be confirmed by the owner. No support hours and no response time are given: they are open owner questions.

## Open owner questions

No answer is given to any of these, and no number is proposed.

1. Which company is the pilot, and which dealer?
2. Does the dealer have its own tenant, and what may it see of the pilot company's data?
3. Support hours and response times.
4. The channel the pilot company uses to report a problem.
5. The pilot's length and the end condition.
6. Data volumes per record type.
7. Which printed forms the pilot needs first.
8. The sign-in choice (task T-1359), see Onboarding step 5.
