# 0084 — The storekeeper's asset grant is a per-tenant overlay (T-1570, D-097)

Status: accepted (owner approved D-097 on 2026-11-09). Amends 0081 D2 and 0055 D7 for one pair of permissions.

## Context
The owner wants the STOREKEEPER to read and post assets, switchable per tenant. A manifest `role_grants` line
would widen every tenant at deploy and is refused by the permission-matrix tool (0055 D7, 0081 D2).

## Decision
D1. **Per-tenant, add-only overlay with a closed list**, not full per-tenant snapshots and not an instance
setting. The tenant's `assets` row in `tenant_modules` carries `settings.storekeeper_grants`, a subset of
`["AssetsRead","AssetsPost"]`. What may ever be granted is the constant `Authorization.grantable/0`;
AssetsReverse, AssetsReconcile and AssetsCardWrite are not grantable.
D2. **`Authorization` stays pure.** The overlay is an explicit input (`AccessContext.role_overlay`,
`role_allows?/3`, `has_permission_in_scope?/4`); the 2- and 3-arity functions, `permissions/0` and the matrix golden
keep their meaning (the golden describes the baseline). Only the request edge (`Plugs.Authorize`, `Scope.Principal`,
the ledger authority) loads it, through `Letflow.Api.TenantGrants`, with the caller's own schema prefix (INV-1).
`GET /me/access`, and so the sidebar, uses the same overlay as the gate.
D3. **Upgrade chain.** The manifest `role_grants` stays empty; a module upgrade never writes the key, so it cannot
silently widen or narrow a tenant.
D4. **Defaults.** A tenant that installs `assets` after this change gets read and post (`Assets.on_install/3`).
Existing tenants have no key and stay off until a tenant administrator (holding `UsersGroupsRolesManage`
tenant-wide, interactive credential) switches it on with `PUT /tenant/role-grants`; the platform operator may also
use the module settings route. Turning it off takes effect on the next request (the ledger authority reloads it
inside the posting transaction).
D5. **Routes** `GET` and `PUT /tenant/role-grants` use the existing permission `UsersGroupsRolesManage`
(policy keys `RoleGrantsRead`, `RoleGrantsManage`, admin plane), take no tenant identifier, and audit each change.

## Not decided here
Full snapshots for other roles or modules; narrowing a baseline grant; scoped (non tenant-wide) posting.
