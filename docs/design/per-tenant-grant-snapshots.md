# Per-tenant grant snapshots for module `role_grants`

Task T-2243. Status: **proposed design and recommendation; no code, migration, tenant data or deployed
configuration is changed by this document.** Decision 0055 D7 calls this option B. It is a design for the
general mechanism, not another per-pair exception. The request and upgrade paths are authorization-critical:
every implementing slice that changes them needs SECURITY-REVIEWER.

## 1. Recommendation in one page

Adopt **an accepted, per-tenant, per-module snapshot of the manifest's `role_grants`**, evaluated together
with the grants compiled into the running release:

```text
module grant is effective for tenant T
  = the running manifest still declares it
  AND tenant T's accepted snapshot contains it
```

Core role rules, the two administrator catch-alls and role-agnostic permissions do not move into the
snapshot. The D-097 storekeeper/assets overlay remains an additional, independent grant. A snapshot grants
nothing by itself when the running manifest no longer contains the pair; this is what keeps a narrowing
effective at deploy, as 0055 D7 already decides.

The lifecycle is:

* **Initial migration and new-tenant provisioning:** snapshot the currently compiled grants so the answers
  do not change at cutover.
* **First install of a module registered after this feature:** the install writes the current manifest's
  grants. The install is the administrator's explicit acceptance of that module's initial defaults.
* **Upgrade with widening:** the existing upgrade plan shows the added `(role, permission)` pairs but they
  remain denied. The apply writes them only when an interactive, tenant-wide `ModulesManage` holder sends
  the exact acknowledgement set and the unchanged `plan_hash`, in the same transaction as the module
  upgrade, its journal and its audit entry.
* **Upgrade without widening:** no grant acknowledgement is needed. Boot and fleet upgrades keep their
  current behaviour. A plan containing widening is never boot-applicable and is left for the tenant admin
  by the fleet driver.
* **Narrowing:** it is effective at deploy through the intersection above. A tenant migration also prunes
  the removed pairs from every snapshot. The pruning is required: without it, removing a grant in release
  B and re-adding it in release C would resurrect it for a tenant that never ran B's upgrade, without a
  new acknowledgement.
* **Rollback:** the previous snapshot is restorable from the journal, but restoring a pair that would
  widen the tenant relative to its current snapshot needs the same explicit acknowledgement. An `undo`
  blob is not a bypass.

Keep `priv/permission_matrix/effective.golden` as the **compiled/default matrix**, not as a claim about
every tenant. Its format and row meaning stay compatible. The matrix tool changes from "every manifest
widening is refused" to "a widening is accepted for review only when the module version changed and the
exact pair is declared in `widens_grants`". The report labels these rows `tenant_ack_required`. The tool's
refusal stays in force until the storage, request, upgrade and migration slices have all merged.

This is an **L-sized backend change, followed by an M-sized admin-screen slice**. Split it into the five
sequenced PRs in section 11; do not implement it as one authorization-and-migration PR.

## 2. Verified starting point

Read on branch `team/T-2243`, initially at `ce467189a`. The important commands were:

```bash
rg -n "def (role_allows\?|evaluate_access|has_permission_in_scope\?)|role_overlay" \
  lib/letflow/api lib/letflow/plugs lib/letflow/ledger
rg -n "grant|permission|plan_hash|applicable_on_boot|ack_destructive" \
  lib/letflow/modules/upgrade_plan.ex lib/letflow/module_upgrade
rg -n "role_grants|version:" lib/letflow/modules/{stock/stock.ex,exam/exam.ex,codes/codes.ex,assets/assets.ex}
rg -n "upgrade/plan|ack_destructive|plan_hash|tenant/modules" web/src
```

The facts the design relies on are:

1. `Authorization.role_allows?/2` is pure and global: `core_role_allows?/2` or membership in
   `Catalog.role_grants/1`. `Catalog.role_grants/1` unions all compiled modules without a tenant or install
   argument. `/2` is therefore the right function for the compiled golden, but cannot remain the source of
   module grants in a tenant request.
2. The request edge already has the right dependency-injection shape. `Plugs.Authorize` resolves the
   tenant prefix and effective roles, loads `TenantGrants.load_for/2`, and puts `role_overlay` into
   `AccessContext`. `Scope.Principal`, `Api.ModuleGuard`, `GET /me/access` and `Ledger.Authority` carry the
   same explicit input. `Ledger.Authority.check_with_read/1` reloads the overlay inside the posting
   transaction. Snapshots must extend this path, not put a repository call into `Authorization`.
3. `TenantGrants` currently special-cases only D-097. Its read is skipped unless the caller has a role in
   `Authorization.grantable/0`, and a read failure fails closed to no overlay. This is both the performance
   pattern and the failure pattern to retain.
4. `Modules.UpgradePlan.plan/3` already takes the per-tenant advisory lock, recomputes the plan during
   `ModuleUpgrade.Apply`, and includes tenant state and the target manifest in `plan_hash`. Its
   `information` currently says permissions are `effective_at_deploy`, but it has no grant diff. Its own
   moduledoc says the permission-matrix digest is not an input yet.
5. `tenant_module_upgrades.touches` already carries apply results and rollback `undo` data. The journal can
   hold grant before/after snapshots without a second lifecycle table. Boot only applies
   `applicable_on_boot` plans; `ModuleUpgrade.Fleet` never supplies `ack_destructive`.
6. `Catalog.manifest_hash/1` deliberately does **not** hash `role_grants`. A grant change therefore needs
   its own canonical digest in `plan_hash`; adding it to the write-handler manifest hash would change stamp
   semantics for an unrelated reason. The matrix check must also reject a grant change with an unchanged
   module version, or `UpgradePlan` could report `up_to_date`.
7. There is no module-upgrade screen in `web/src` today; the only matches are API constants and the module
   rollout/uninstall screens. An administrator cannot be asked to acknowledge an invisible JSON diff as the
   final product experience, so the UI is a required follow-up slice, not a claim that the API alone is a
   completed owner-facing feature.
8. Decision 0088 already decides that module `role_grants` become default content of template keys, that
   module updates never silently enter a tenant role, and that the open build has read-only templates. This
   design supplies the acknowledgement mechanism for those templates; it does not build tenant-defined
   roles or the closed role editor.

At this starting point the stock manifest still withholds `StockQuickCount` from STOREKEEPER and the codes
manifest has empty `role_grants`. The task's D-161 exception for exactly `{STOREKEEPER, StockQuickCount}`
and `{STOREKEEPER, CodesRead}` is therefore a dependency to re-check on `origin/main` at implementation
time, not something this document pretends has already merged.

## 3. Snapshot meaning and worked examples

Let `C(m)` be the `(role, permission)` pairs in the running manifest of module `m`, and `S(t,m)` the pairs
in tenant `t`'s accepted snapshot. For every module-granted pair:

```text
allowed(t,m,role,permission) = (role,permission) in C(m) AND in S(t,m)
final_role_allows? = core_rule OR effective_module_grant OR D-097_overlay
```

The install gate on module routes, `min_data_version`, scope checks and INV-10 platform checks are separate
and unchanged. Administrator rows computed from `all` / `all_tenant_scope` are not snapshots; this is what
keeps a newly declared module atom available to the two admins exactly as the current golden describes.

### Example A: a normal widening

Stock 0.21 has no `{STOREKEEPER, StockQuickCount}` in a tenant's snapshot. A later manifest declares it.
After deploy, the pair is in `C(stock)` but not `S(t,stock)`, so the storekeeper still gets 403 and the two
admins retain their computed access. The plan lists one `add` row. Only an apply whose `ack_grants` contains
that exact row adds it to `S(t,stock)`. Another tenant that has not applied remains refused.

### Example B: first install after the feature

A tenant installs a newly registered module whose initial manifest grants a read atom to STOREKEEPER. The
install transaction writes `S(t,m) = C(m)`. No second upgrade is needed. A different tenant that has not
installed it has no snapshot row and does not gain the grant. Its module routes were already 404; internal
module entry points still need their existing install guards.

### Example C: narrowing and re-adding

Release A grants P, release B removes it, release C adds it again. In B the pair leaves `C(m)`, so access
stops immediately, and B's pruning migration removes it from every `S(t,m)`. In C the pair is again in
`C(m)` but is absent from `S(t,m)`, even for a tenant that skipped B's module upgrade. C therefore needs a
fresh acknowledged apply. The test plan names this three-release case explicitly because the intersection
alone does not prevent resurrection.

### Compatibility backfill for the currently global union

The initial migration seeds **every currently registered module**, not only rows in `tenant_modules`.
Today's `Catalog.role_grants/1` makes those pairs globally visible even where the module is not installed
(the route install gate is what normally makes that difference inaccessible). Seeding only installed
modules would silently narrow that legacy behaviour. New-tenant provisioning takes the same initial
snapshot. Modules first registered after the feature are different: their rows are written at install, not
by a fleet-wide deploy. This preserves the old union for everything that exists at migration without making
a new module's initial grants a silent widening for every existing tenant.

Soft uninstall and reactivation do not rewrite the snapshot; their existing route gates stay separate.
This preserves the legacy answer and prevents reactivation from becoming an unacknowledged upgrade.

## 4. Storage and migrations

### 4.1 One snapshot row per tenant and module

Add the tenant-schema table `tenant_module_grant_snapshots`:

| Column | Type and rule | Purpose |
|---|---|---|
| `module_id` | text, primary key | Catalog id; never a request-selected tenant key |
| `role_grants` | jsonb, not null | Object `role string => sorted permission-string array`; canonical and deduplicated by core |
| `accepted_version` | text, not null | Module version that supplied this grant set; for the compatibility backfill, the compiled version being snapshotted |
| `accepted_upgrade_id` | uuid, null | The done upgrade/rollback journal row; null for provisioning, install and backfill |
| `inserted_at`, `updated_at` | UTC timestamps | Operational diagnostics only, not authorization inputs |

There is deliberately no `tenant_id`: the Ecto `prefix` is the tenancy boundary. There is one row even for
an installed module with an empty grant map, so "initialised to no grants" differs from "missing/broken".
A missing row fails closed and raises an operational alert; it is never repaired by blindly copying the
newest compiled grants, because that could apply a widening.

A single JSONB document per module is preferable to a row per pair here: replacement is atomic, empty
snapshots are representable, the plan hash has one canonical input, and rollback needs only one value.
The table is bounded by the number of registered modules, and a request reads only this small table. It
is not a full role-permission matrix and does not duplicate core grants.

### 4.2 Initial backfill

The tenant migration, registered in `TenantProvisioning`'s migration list, runs per tenant and:

1. Reads the compiled production manifests, canonicalises their grant maps, and inserts one row per module
   with `ON CONFLICT DO NOTHING`.
2. Never overwrites an existing row on replay; an acknowledged tenant choice must not be replaced by a
   later migration replay.
3. Processes tenants independently, with the same `(prefix,module_id)` advisory lock used by plan/apply for
   any update, and reports inserted/skipped counts. There is no cross-tenant transaction.
4. Writes no module-upgrade journal row and changes no `tenant_modules.version`: this is a compatibility
   snapshot of what is effective at migration time, not an assertion that a data upgrade ran.

New-tenant provisioning calls the same idempotent writer. `Installs.install/3` writes the module's current
snapshot inside its existing transaction, after dependency checks and before commit. Reactivation does not
upsert. These writers land and run before the read switch, so dual-write coverage exists before any access
decision depends on the table.

The migration and fresh-install tests must also update the normal tenant-table and migration-position pins;
no new permission atom or route is introduced by this storage slice.

### 4.3 Narrowing and module-removal reconciliation

Every release that removes a manifest grant includes a small tenant migration calling one shared core
function with the declared removed pairs. It deletes exactly those pairs under the advisory lock and writes
an audit entry with system actor, module, removed pairs and count; it does not invent a module-upgrade
state. The runtime intersection enforces the narrowing even before the pruning replay reaches a tenant.

Unregistering a module similarly requires a migration that removes its snapshot row after the module's
existing uninstall/data-retention preconditions. Otherwise a later re-registration could revive stale
grants. CI should pin these declarations to a reconciliation migration so a narrowing cannot be shipped as
a golden-only change.

## 5. The request path: pure decision, bounded reads, fail closed

Introduce a separate explicit `module_grants` input alongside `role_overlay`; do not widen the meaning of
D-097's sanitised overlay and do not let `Authorization` query Ecto. `AccessContext` and `Scope.Principal`
carry both. Existing pure `/2` calls remain the compiled/default function for the matrix. Request-time
callers use a new arity that accepts both inputs; the old overlay-only arities delegate with an empty
snapshot for compatibility during the conversion.

`TenantGrants.load_for/2` (or a sibling loader with the same request-edge contract) returns both values:

* If none of the caller's roles occurs in any compiled `role_grants` key, it performs no snapshot query.
* Otherwise one tenant-prefixed query reads the small snapshot table and constructs the union for just the
  caller's roles. D-097's separate assets-settings read stays as it is; STOREKEEPER therefore has at most
  one additional query, other grant-bearing roles one, and uninvolved roles zero.
* Stored strings are converted only through lookups in `Authorization.roles/0` and the compiled module
  permission lists. No `String.to_atom`, `String.to_existing_atom` or input-derived module is used.
* The loader intersects each stored pair with the current manifest and discards unknown roles, unknown
  permissions, malformed JSON shapes and grants of unregistered modules. Core never trusts JSON to define a
  new permission or role.
* A missing/unreadable table or query error returns no **module** grants and logs only the error kind,
  tenant-safe module metadata and trace id. Core permissions still work; module-grant access fails closed.
  There is no fallback to `Catalog.role_grants/1`, which would reopen silent widening.

Do not add ETS or `:persistent_term` caching in the first version. The upgrade is meant to take effect on
the next request, multi-node invalidation is otherwise a new failure mode, and the bounded query is easy to
measure. `Plugs.Authorize` loads once and assigns the result for downstream scope checks and `/me/access`.
`Ledger.Authority` reloads both inputs inside its posting transaction, exactly as it reloads the D-097
overlay today, so a grant change between task claim and posting is honoured.

A static guard should forbid `role_allows?/2` and overlay-only request calls in the HTTP/ledger decision
paths after conversion. Pure core-only tests and `PermissionMatrix.current/0` remain intentional users of
`/2`.

## 6. Plan, acknowledgement, journal and rollback

### 6.1 Plan report and hash

Extend the existing plan, not the route inventory. `POST /tenant/modules/:module_id/upgrade/plan` gains a
`grant_changes` array with only:

```text
id, role, permission, direction (add|remove), accepted_version, target_version
```

The id is a deterministic, plan-issued string derived from module, role and permission. `remove` rows carry
`effective_at: deploy`; `add` rows carry `effective_at: acknowledged_apply`. The existing blanket
`information.effective_at_deploy = true` is split so it no longer misdescribes grants. There is no tenant
record content in this response.

Bump the hash input version and add canonical `compiled_role_grants`, `accepted_role_grants`, and the
ordered diff. The tenant snapshot is read under the same advisory lock on plan and on apply. A changed
snapshot, acknowledgement set or target manifest therefore produces `plan_mismatch` rather than applying a
different grant decision from the one reviewed. A grant change with unchanged module version is refused by
CI and produces no applicable grant-only plan; repair the manifest/version first.

`applicable_on_boot` is false whenever an `add` row exists. Removals do not by themselves make a safe plan
unsafe, because the running code already narrows and the migration prunes independently.

### 6.2 Apply

`POST /tenant/modules/:module_id/upgrade` accepts an additional `ack_grants` list. Its rules are:

* With no `add` rows, `ack_grants` must be empty.
* With `add` rows, the caller must be an interactive user holding `ModulesManage` tenant-wide (the same
  credential/scope shape as `TenantRoleGrants`), and the sorted unique `ack_grants` must equal exactly the
  plan's add-row ids. Missing, extra or stale ids answer 409 `grant_ack_mismatch`; a non-list answers 422.
* The snapshot replacement, `tenant_modules` update, journal `done`, and audit entry commit in the existing
  apply transaction. Any failure leaves both the old module version and old snapshot.
* The audit payload contains before/after grant pairs, `plan_hash`, `ack_grants`, actor, credential kind and
  rationale, never request internals or exception text.
* Boot never sends `ack_grants`, so it cannot widen. The fleet records a neutral `pending_tenant_ack`
  outcome for this refusal rather than counting it as a failed tenant or retrying it as an automatic
  rollout. There is no platform-operator body option to acknowledge for the tenant.

A first install needs no `ack_grants`: its explicit module install accepts that initial manifest. This does
not permit an installed module to use reinstall/reactivation as an upgrade; the existing guards prevent
that.

### 6.3 Journal and rollback

Use `tenant_module_upgrades.touches["grant_snapshot"]` for a versioned object containing `before`, `after`,
`changes`, `ack_grants` and `accepted_version`. `accepted_upgrade_id` points logically to this journal row;
provisioning/install/backfill leave it null. No second grant lifecycle state machine is added.

Rollback stores and restores the same object. Before restoring, core computes current-snapshot -> target-
snapshot diff. Any `add` needs `ack_grants` under the same interactive rule; any `remove` follows the
narrowing rule. A rollback that would silently re-widen is refused without changing the module or snapshot.

## 7. Permission-matrix tool and `effective.golden`

### 7.1 What the file means after snapshots

There is no single effective matrix across tenants anymore. The committed file remains useful as the
**compiled matrix**: core answers plus each module's declared defaults and proposed next-version grants.
It is also the source for the initial provisioning snapshot. It never contains tenant ids or accepted tenant
snapshots.

Keep format 1, the eight-line header, the path and `via = core|grant|-` to avoid an unnecessary migration of
all pins. Update the moduledoc and report wording: a `grant` row means "supplied by the compiled manifest;
effective for a tenant only when accepted". Enabling the snapshot implementation itself should not change
the golden's rows or counts. A later widening PR changes its module's rows in the normal regenerated diff.

### 7.2 Classification changes

The trusted-baseline versus working-tree freshness separation stays unchanged. Classification becomes:

| Change | Verdict |
|---|---|
| Added `via: grant` pair, module version changed, exact pair in that module's `widens_grants` | Pass as `tenant_ack_required` |
| Same added pair without declaration, or with unchanged version | Fail `widening` / `grant_version_required` |
| Removed manifest grant, exact declaration and changed version | Pass as narrowing; require its pruning migration |
| Manifest grant of a core-policy atom, a core rule widening an existing module atom for a non-admin, or a grant referenced by another module | Keep the current refusal |
| First registered module's declared grants | Allowed with exact declaration; they take effect per tenant at provisioning/install, not by updating existing tenants at deploy |
| Core-rule change or a new role | Existing `core_change` and mandatory security-review behaviour stays |
| Declaration on an unchanged module version | Failure, not an inert declaration |

`widens_grants` returns to its original 0055 D7.1 two-way meaning: the exact declared grant diff, despite
its now-awkward name. Renaming it to `grant_changes` would touch every manifest and validator without
improving the safety check; do that only with the later role-template work if desired.

Add a compile-time capability switch in the matrix implementation, initially false, so declarations cannot
authorise widening while the runtime still uses the global fallback. The final backend slice flips it only
after all storage/read/apply/reconciliation tests are present. The D-161 two-pair temporary exception can
then retire only its temporary tool special case: pairs already in the merged baseline need no new
declaration or golden change; a pair delivered in the same release follows the ordinary declaration and
version-bump rule. Until that slice, keep the exception exactly as it lands on main and add no runtime
special case for either pair.

## 8. Relationship to existing decisions

* **0055 D7:** widening is no longer globally effective at deploy; the acknowledged per-tenant path replaces
  the permanent refusal. Narrowing remains effective at deploy. `plan_hash` now really includes the grant
  matrix and tenant grant state. The implementing record must amend D7 and the `widens_grants` bullet that
  currently makes widening declarations a failure.
* **0080 Q3/Q5/Q6:** the plan/apply routes, one-transaction apply and rationale stay. Boot's safe-plan rule
  gains "no grant additions". The fleet driver needs the neutral pending-ack outcome.
* **0084:** the D-097 overlay stays separate and additive. Snapshot writes never overwrite
  `settings.storekeeper_grants`, and an upgrade cannot turn that tenant choice off. Its pure-input pattern is
  generalised, not its closed allowlist.
* **0088 D6/D7:** this is the open build's mechanism for changing a read-only template through an explicit
  admin acknowledgement. Corporate custom roles are not silently edited either; a later role-editor slice
  can present the same proposal without automatically applying it to copied roles. The supersession-table
  sentence saying the open-build block simply "stays" needs an amendment when this mechanism is accepted.
* **0039 D4:** the initial backfill preserves the legacy global union for currently registered modules.
  New modules no longer widen every existing tenant merely by being registered; their initial snapshot is
  written at install. The install-route gate remains a distinct control.

No requirement status or run-history change belongs to this design task. Accepting the eventual
implementation needs a decision-record amendment and the normal security review; this document itself does
not ratify one.

## 9. Administrator experience

The backend can ship behind the read switch before the UI, but the feature is not owner-facing complete
until the existing module administration area has an upgrade review panel. It shows current/target version,
grant additions and removals in role-label plus permission-id form, the other plan changes, and the
rationale. The acknowledgement control is a confirmation action bound to the exact `plan_hash`; a changed
plan forces review again. A successful apply keeps the module selected and shows the accepted grants;
`grant_ack_mismatch`, load failure and pending fleet acknowledgement have plain-language states.

This is a panel in the module detail view, not a new modal editor. The UI slice includes en/ru/kk strings,
no-permission, loading, empty/no-change, error, pending, success and mismatch tests, and the required
1440/390 light/dark screenshot matrix (kk for long labels). No new route is needed. Boot/fleet pending
acknowledgement links to this panel rather than offering a platform-side override.

## 10. Security and verification plan

| Property | Test that must exist |
|---|---|
| INV-1 / INV-6 tenant isolation | Two tenants with the same role and module get different answers after only A acknowledges; every snapshot query uses A's prefix and B's rows are unchanged. Migration replay in A neither reads nor writes B. |
| INV-5 / route identity | Existing unknown-module versus foreign/not-installed 404 tests still pass; grant errors never reveal another tenant's snapshot or upgrade id. |
| INV-10 and acknowledgement authority | A scoped admin, API token, non-platform PLATFORM_ADMIN, and non-interactive caller cannot acknowledge; an interactive tenant-wide ModulesManage holder can. Platform/fleet calls cannot supply an acknowledgement. |
| Red proof of the general bug | With a fixture manifest adding a grant, the real router is 403 before acknowledgement and 200 after only the intended tenant's apply; on the unmodified global-fallback code both tenants become allowed at once. |
| Fresh install | A module first registered after the feature grants its declared default after install, not before; install rollback leaves no snapshot. |
| Backfill parity | For every current role x permission pair, old `/2` and new snapshot evaluation agree immediately after backfill, including a legacy module with no `tenant_modules` row. Replay is idempotent and preserves an acknowledged later snapshot. |
| Narrowing and resurrection | A grants, B removes (denied immediately and pruned), C re-adds: a tenant that skipped B's upgrade is still denied in C until it acknowledges C. Module unregister/re-register follows the same rule. |
| Snapshot failure | Missing row, malformed stored maps, unknown strings and a forced query error never produce module access and never create atoms; core-only access remains. |
| Plan binding | Changing accepted or compiled grants changes `plan_hash`; stale/missing/extra `ack_grants` is refused with no writes; unchanged-version grant drift is rejected. |
| Atomic journal and audit | Snapshot, module version, journal and audit are all present after success and all absent after an induced audit failure. Counts and pairs are audited, no exception text. |
| Boot/fleet | A widening plan is not `applicable_on_boot`; boot leaves it for admin; fleet records `pending_tenant_ack`, does not widen and does not count it as a failed tenant. |
| Rollback | Restoring a narrower snapshot works under the narrowing rule; restoring a wider one without exact acknowledgement is refused and writes nothing. |
| D-097 regression | The existing storekeeper/assets overlay tests pass unchanged; snapshot replacement neither adds nor removes that overlay. |
| Hot-path shape | Roles with no manifest grants cause zero snapshot queries; a grant-bearing role causes one; `/me/access` uses the same answer as the route; ledger authority re-reads inside the posting transaction. No sleep- or timing-based assertion. |
| Matrix gate | Undeclared widening and unchanged-version widening fail; exact declared widening passes as `tenant_ack_required`; core-policy/cross-module cases stay refused; narrowing without pruning migration fails. |
| UI | The plan, acknowledgement, mismatch and success are exercised through the real panel at desktop and narrow width; every screenshot in the state table is opened and compared. |

The implementation must also run the existing authorization, overlay, module install/upgrade/boot/fleet/
rollback, permission-matrix and tenant-migration suites. New tenant-table and migration-position pins are
re-derived after the final merge of main, not copied from this document.

## 11. Slices and sizes

These are sequential because they share `authorization.ex`, `tenant_grants.ex`, `installs.ex`, the upgrade
plan/apply and the permission matrix. Sizes are implementation estimates including tests, not elapsed-time
commitments.

| Slice | Contents | Size | Exit condition |
|---|---|---|---|
| GS1 | Snapshot schema, canonical writer, initial backfill/provisioning/install dual-write, migration parity and pins | **M** | Read switch still off; backfill parity and idempotence proven; no access answer changes |
| GS2 | Explicit snapshot input through Plug/Scope/ModuleGuard/me/Ledger, fail-closed loader, read flag default off, cross-tenant and hot-path tests | **L, security** | Two-tenant behaviour and zero/one-query bounds proven; D-097 unchanged |
| GS3 | Plan diff/hash v2, interactive exact acknowledgement, transactional journal/audit, boot/fleet/rollback behaviour | **L, security** | No route can apply an unacknowledged widening; atomicity and resurrection tests pass |
| GS4 | Matrix classification, narrowing/removal reconciliation, final capability switch, D-161 reconciliation and decision amendments | **M** | CI accepts only declared/versioned diffs; all backend prerequisites merged before any widening manifest |
| GS5 | Module upgrade review/acknowledgement panel, localized states and full screenshot matrix | **M** | An admin can review and acknowledge entirely from the UI; GUI review passes |

Overall backend size **L**; with the required UI, **L+**. Do not queue GS2/GS3/GS4 in parallel. A module
that needs a widening gets `after` on GS4 (and on GS5 for an owner-facing rollout), while the D-161 exception
continues to cover only its two named pairs in the meantime.

The only proposed new runtime setting is a **default-off** snapshot-read switch used for expand/contract
rollout. GS1/GS2 deploy table, backfill and writers with reads off; old nodes are drained, the idempotent
backfill is replayed once more, parity is checked, then reads are enabled. This avoids a mixed-deployment
window in which an old node could install a module without dual-writing. Enabling it in production is a
rollout decision, not made by this document. No cache-invalidation setting is introduced.

## 12. Principal risks and controls

| Risk | Severity | Control / residual |
|---|---|---|
| A mistake on the hottest authorization path denies legitimate work or grants too much | High | Pure decision inputs, real-router two-tenant tests, fail closed on snapshot errors, mandatory security review on GS2/GS3, no cache. A core-rule failure is unchanged; a snapshot failure can deny module work until repaired, which is preferable to widening. |
| Backfill captures the wrong historical state | High | The truth at migration is the currently compiled global matrix, not guessed old manifest. Seed all currently registered modules and prove pair-for-pair parity. Historical reconstruction before that moment is intentionally not attempted. |
| Removed grants return in a later release | High | Runtime intersection plus mandatory pruning migrations and the A/B/C resurrection test. A narrowing PR without reconciliation fails CI. |
| Mixed old/new nodes miss a snapshot write | High | Default-off read switch, dual-write first, drain old nodes, replay backfill and compare before enabling reads. |
| Fleet or boot silently widens | High | `applicable_on_boot = false` on additions, neutral fleet pending-ack state, no acknowledgement parameter on platform routes. |
| Ack applies a different proposal than the admin reviewed | High | Exact add-id set, interactive tenant-wide authority, advisory lock, recomputed hash and atomic audit. |
| Rollback bypasses acknowledgement | Medium | Compute the rollback grant diff and require acknowledgement for additions even when an old snapshot exists in `undo`. |
| Query cost grows per request | Medium | Zero queries for uninvolved roles and one small tenant-table read for grant-bearing roles; no per-module/per-pair queries. Measure before introducing any cache. |
| Golden gives reviewers a false picture | Medium | Rename its meaning in documentation/report output to compiled/default, show `tenant_ack_required`, and inspect tenant snapshots only through the tenant's own plan/audit. |
| Duplication with tenant-defined roles | Medium | Limit this work to module default grants and template keys. 0088 stage 1/2 can consume these snapshots; custom/copied roles are never silently changed. |
| Admin cannot understand or reach the acknowledgement | Medium | GS5 is required before calling the feature owner-facing complete; pending fleet outcomes link to the module panel. |

## 13. Alternatives considered

1. **Generalise the D-097 add-only overlay.** Smaller, but it has no coherent narrowing/removal semantics,
   no per-module accepted version, and makes every manifest grant a special-case allowlist. Reject.
2. **Snapshot the whole core + module role matrix per tenant.** One lookup is attractive, but it duplicates
   computed admin and core rules, multiplies migration size and conflicts with 0088's protected `all` and
   `all_tenant_scope` rows. New core permissions would require a fleet-wide semantic migration. Reject in
   favour of module-only snapshots.
3. **Recompute accepted grants by replaying upgrade journals on every request.** Avoids a snapshot table,
   but puts journal replay on the hot path, makes install/backfill provenance ambiguous and makes pruning
   and rollback harder to reason about. The journal is evidence, not the request-time read model. Reject.
4. **Make both widening and narrowing wait for acknowledgement.** This would make snapshots conceptually
   simple but contradicts 0055's deploy-effective narrowing and prevents a security revocation from taking
   effect promptly. Keep narrowing immediate and prune it.

The recommended model is the smallest one that preserves current installed behaviour, gives each tenant an
explicit upgrade decision, and can later feed 0088's role templates without putting database access into
`Authorization`.
