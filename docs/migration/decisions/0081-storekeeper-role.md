# 0081: the STOREKEEPER role (D-093, D-097)

Status: accepted (owner decision D-093, 2026-11-05, via the portfolio manager). Amends 0046 D10 ("the role set stays closed")
and the "eight roles" text of 0013 and 0046.

## D1: a ninth built-in role

`STOREKEEPER` is appended to `Letflow.Api.Authorization.roles/0`. It is a built-in role, not a routing role: routing roles carry no
permissions. Seeding (a group and a platform-role binding per tenant), node-scoped grants (0051, D-067) and the backfill of existing
tenants derive from `roles/0`, so no migration is needed. Assignable to a user or to a group like every built-in.

## D2: the grant split

* Stock atoms come from the stock manifest `role_grants` (stock 0.14.0): `StockRead`, `StockPost`, `StockReverse`, `StockCountOrder`,
  `StockCountRecord`. `StockReconcile` is withheld (administrative reconciliation view; one line to grant it).
* A closed core list: `HelpRead`, `MembershipsRead`, `TasksRead`, `TasksComplete`, `EntitiesDefinitionsRead`, `EntitiesQuery`,
  `EntitiesRecordsImport`. No write, manage, export, token, user, role, module, settings or audit permission; no platform-scope one.
* D-097: asset permissions arrive with C19 (T-1339) as a one-line addition to the same `role_grants`.

## D3: the permission-matrix tool

A role absent from the baseline golden cannot be "widened". Its rows are reported as `{:added_new_role, role, perm}` core changes, which
print the mandatory SECURITY-REVIEWER banner. A role already in the baseline keeps every rule (a later module grant to it still fails).

## D4: import guard

A caller who holds `EntitiesRecordsImport` only through STOREKEEPER may import only module-managed types with a registered import
function (`RecordImport.handle_import_records/2`); the module's own import function runs, not the generic update branch; any other type answers 403. This breaks the invariant "Import implies Write" of
`gh2659_import_implies_write_test.exs`; STOREKEEPER is its one named exception.

## D5: count freeze

Unchanged: the assumption stays "no freeze" for GATE B.

## Not decided here

Scoped-storekeeper write semantics beyond 0051 (unchanged: document writes need a tenant-wide grant). Keycloak provisioner templates v1/v2
are not changed; the role reaches Letflow through group membership. Only the dev realm `bpm-default.json` gains the realm role.

## Security review

RECORDED:
