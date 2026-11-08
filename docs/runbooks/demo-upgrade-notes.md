# Demo instance: does the data survive an upgrade? (T-1471, D-108)

The demo instance keeps its database and is moved build by build. `promote-demo.sh` (infra) runs the module upgrade
chain on every promote: the read-only plan `POST /api/v1/tenant/modules/:module_id/upgrade/plan` (REQ-768), the
administrator's apply `POST /api/v1/tenant/modules/:module_id/upgrade` (REQ-770), the 409 `upgrade_required` that a
module write answers while a module is older than the build (REQ-771), and upgrade on deploy
(`LETFLOW_MODULE_UPGRADE_ON_BOOT`, default off, REQ-772). This page says what has been proved about the showroom
tenant (`docs/runbooks/demo-showroom.md`), what has not, which builds break it, and how infra checks every promote.

## The smoke check for infra

`scripts/demo/demo_upgrade_check.sh` (bash, curl, jq, cksum; the tenant's own HTTP API only; it never writes and never
calls the apply route).

```
export BASE_URL=https://demo.example.org TENANT_SLUG=showroom
export ADMIN_USERNAME=... ADMIN_PASSWORD=... ADMIN_REALM=...      # or ACCESS_TOKEN (an interactive admin, not an API token)
bash scripts/demo/demo_upgrade_check.sh snapshot /var/tmp/demo-before.json    # 1. BEFORE promote
./promote-demo.sh                                                              # 2. infra's promote (module upgrade chain)
bash scripts/demo/demo_upgrade_check.sh verify   /var/tmp/demo-before.json    # 3. AFTER promote
bash scripts/demo/demo_showroom_seed.sh                                        # 4. fill in what the new build needs (idempotent)
```

| Exit | Meaning | What to do |
|---|---|---|
| 0 | every checked count and checksum equals the snapshot, and every installed module's plan says `up_to_date` | done |
| 1 | a difference: the line `DIFF  <check>: before [..] after [..]` names it | stop the demo, restore the database backup taken before promote, report with the output |
| 2 | missing tool or bad input, nothing was requested | fix the call |
| 3 | data equal, but a module is still pending (`pending <module>: pending A -> B (path available: false ...)`) | see "Breakage list": an administrator must apply the plan, or the build needs a declared step or window; until then writes to that module answer 409 `upgrade_required` |
| 4 | a request failed, the check cannot judge | look at the `STOP:` line (sign-in, tenant, network) |

What is compared (exact, not floating point): the installed module ids; for every active entity type, the record count and
a checksum of every record id with its field values; the stock documents, counts, balances (the per-item and location
rows) and movements, as row count plus a checksum of every row; that the Inv-10 print of the first count answers 200 and a
PDF. A float total of the balance quantities is logged for the human (`info:`) and is not compared. Module versions and
manifest hashes are **not** compared: an upgrade is meant to change them. The output holds names, counts and checksums only,
no record content and no token. The snapshot file holds the same.

## Apply the chain: `scripts/demo_upgrade_chain.sh` (T-1480)

`scripts/demo_upgrade_chain.sh` (bash, curl, jq; HTTP only) is what infra's `promote-demo.sh` runs between the snapshot and
the verify. For every tenant in `TENANT_SLUG` (comma or space separated, default `showroom`) and every installed module
(dependency order: org, locations, catalog_items, codes, stock, assets, then the rest) it asks the read-only plan
(`POST /tenant/modules/:module_id/upgrade/plan`, REQ-768); when the plan is pending and a path is available it applies it
(`POST /tenant/modules/:module_id/upgrade`, REQ-770, with the plan's `plan_hash` and a rationale); it asks the plan again and
requires `up_to_date`. It never sends `ack_destructive`: a class B step stays an administrator's decision and shows as pending.

```
export BASE_URL=https://demo.example.org TENANT_SLUG=showroom
export ACCESS_TOKEN=...                       # or ADMIN_USERNAME + ADMIN_PASSWORD + ADMIN_REALM (password grant)
bash scripts/demo/demo_upgrade_check.sh snapshot /var/tmp/demo-before.json
bash scripts/demo_upgrade_chain.sh                                             # DRY_RUN=1 plans only
bash scripts/demo/demo_upgrade_check.sh verify   /var/tmp/demo-before.json
```

Which admin: both routes are tenant routes (`:ModulesManage`), reached through the caller's own tenant. The token must be one
the demo tenant accepts: the demo tenant's administrator (TENANT_ADMIN). An OIDC token resolves its tenant from its issuer and
ignores `X-Tenant-Slug`, so a PLATFORM_ADMIN token minted through the platform tenant's issuer reaches the platform tenant, not
`showroom`, and an API token is refused on these routes. The script supports both input forms (`ACCESS_TOKEN`, or admin
credentials) and does not guess: when the token is not accepted the first call ends with `STOP: ... HTTP 401/403/404`; then
infra must supply a demo-tenant administrator's token. One token serves every slug (one demo realm).

One line per tenant and module on stderr, then `RESULT:`; only slugs, module ids, versions, status codes and the answer's
`code` field are printed, no token and no record content:

```
applied showroom/stock: 0.3.0 -> 0.4.0
ok      showroom/org: up_to_date 0.5.0
pending showroom/assets: 0.1.0 -> 0.2.0 (path available: false, no_upgrade_path)
```

| Exit | Meaning | What to do |
|---|---|---|
| 0 | every module upgraded or already current | done |
| 1 | `DIFF <slug>/<module>`: after the apply the plan still says pending | stop, as for exit 1 of the check |
| 2 | missing tool or bad input, nothing requested | fix the call |
| 3 | a module is still pending (no path, apply refused with 409/422, or `DRY_RUN=1`) | see "Breakage list"; an administrator acts |
| 4 | a request failed: `STOP:` line (sign-in, tenant, network, 5xx) | look at the line |

Idempotent: the second run sees `up_to_date` everywhere, sends no apply, prints only `ok` lines and exits 0. Optional inputs:
`UPGRADE_RATIONALE` (default `demo promote: module upgrade chain`), `DRY_RUN=1`. Proved by `test/scripts/demo_upgrade_chain_test.exs`
(real HTTP; the password grant and an apply refused with `ack_required` or a stale `plan_hash` are not exercised there).

## What the test proves, and its limit

`test/scripts/demo_upgrade_check_test.exs` runs both scripts through a real HTTP listener (`Bandit` + `curl`), signed in
with minted tokens, on a committed tenant:

- U1: the seed script builds the tenant (every kind of stock document posted, a signed count, asset documents); `snapshot`;
  every installed module is aged; plan and apply of every installed module over HTTP, all `200`; `verify` exits 0; the row
  count of every data table and the ledger count and quantity sum per cause are identical before and after.
- U2: `verify` before the apply exits 3 and names every pending module. U3: the seed script run again after the upgrade
  exits 0 and changes no table count. U4: a changed ledger quantity is found (exit 1). U5: upgrade on deploy leaves the data
  equal. U6: a post task completed in the window answers 409 `upgrade_required`, then completes after the apply. U8: a module
  with no declared upgrade window is refused `409 no_upgrade_path` and nothing changes.

**Limit.** One checkout holds one build, so a test cannot run the previous build's code. "Seeded with the previous manifest
versions" is simulated the way `test/letflow/modules/stock/upgrade_http_test.exs` does it: the tenant is seeded by the current
build, then each module's `tenant_modules` row gets an older version (stock: `0.10.0`, the lower end of its window) or, for a
module without a window, only a foreign manifest hash, and the stamps on that module's process definitions get the same hash.
So the test proves what the chain does to data, not what an older build's pack looked like. What can differ between real builds
(a renamed field, a new required field) is the breakage list below, and the real promote plus `verify` covers it on the actual
instance. If a field of the demo's stored records changed meaning between two builds, only that instance run can show it.

## Breakage list

Source: `git log -G'^ +version: "[0-9]' -- lib/letflow/modules/<m>/<m>.ex` at main `f870f0f81` (2026-11-07), and the upgrade
path rule `Letflow.Modules.Catalog.upgrade_path/3`.

**The rule that decides everything** (`upgrade_path/3`, REQ-640 / REQ-770, decision 0055 D1): an installed version `from` can be
upgraded to the build's version `to` only if the manifest declares contiguous migration steps from `from`, or, for a module with
no steps, declares `min_upgradable_from` and `from` lies in `[min_upgradable_from, version]`. A module with neither has
`min_upgradable_from == version`, so **every older version has no path**: plan answers `upgrade_path_available: false`,
`path_error: "no_upgrade_path"`, apply answers `409 no_upgrade_path`, the module stays on its old version, and its writes answer
`409 upgrade_required` (REQ-771) while the module's hash differs from the build's. Reads keep working, data is untouched
(test U8).

| Module (now) | Window today | Versions that upgrade in place | A promote from any other version | Demo effect |
|---|---|---|---|---|
| `stock` 0.15.0 | `min_upgradable_from: "0.10.0"` | 0.10.0 .. 0.15.0 | 0.1.0 .. 0.9.0: no path | stock writes refused (409) until the demo is re-seeded on a rebuilt database |
| `org` 0.3.0 | none | 0.3.0 only | 0.1.0, 0.2.0: no path | org writes refused; the seed script fails at its first org write (`STOP: ... HTTP 409`) |
| `locations` 0.4.0 | none | 0.4.0 only | 0.1.0 .. 0.3.0: no path | same |
| `catalog_items` 0.3.0 | none | 0.3.0 only | 0.1.0, 0.2.0: no path | same |
| `codes` 0.4.0 | `min_upgradable_from: "0.1.0"` (T-1485) | 0.1.0 .. 0.4.0 | none below 0.1.0 | none: a QA tenant on 0.3.0 (gate-b5) now plans and applies |
| `assets` 0.12.0 | none | 0.12.0 only | 0.1.0 .. 0.11.0: no path (0.12.0, T-1488, makes `assets_card.org_unit_id` optional: class B, no in-place upgrade; G6 bumped 0.10.0 > 0.11.0 and G5 part 1 bumped 0.9.0 > 0.10.0, both without a window) | same: re-seed |

Every version bump below is therefore a build that breaks an in-place promote of a demo that sits on the version before it,
unless a window or step was declared with it. Builds that bumped (commit, date, step, subject):

| Module | Commit | Date | Step | Change (commit subject) |
|---|---|---|---|---|
| stock | `08cd23332` | 2026-11-04 | new 0.1.0 | module, ledger registration, balance and movement views |
| stock | `f1402b7fd` | 2026-11-04 | 0.1.0 > 0.2.0 | stock document foundation (types, life cycle, posting handler) |
| stock | `bc21755c4` | 2026-11-04 | 0.2.0 > 0.3.0 | count order and commission documents |
| stock | `c3045e674` | 2026-11-04 | 0.3.0 > 0.4.0 | receipt document with lot capture |
| stock | `8d9e6e955` | 2026-11-04 | 0.4.0 > 0.5.0 | count sheet with book quantities |
| stock | `6efba7c17` | 2026-11-04 | 0.5.0 > 0.6.0 | differences sheet posted as ledger entries |
| stock | `0990b8f93` | 2026-11-05 | 0.6.0 > 0.7.0 | count paperwork as xlsx |
| stock | `73291d24f` | 2026-11-05 | 0.7.0 > 0.8.0 | keyboard-scanner input on the count sheet |
| stock | `82acd6404` | 2026-11-05 | 0.8.0 > 0.9.0 | opening balance document and workflow |
| stock | `8e8658e3a` | 2026-11-05 | 0.9.0 > 0.10.0 | xlsx import of opening lines (**start of the window**) |
| stock | `de158019a` | 2026-11-05 | 0.10.0 > 0.11.0 | count differences posted to the ledger (cause `count_difference`) |
| stock | `583435d12` | 2026-11-05 | 0.11.0 > 0.12.0 | printed count paperwork as PDF |
| stock | `c3f875e6a` | 2026-11-05 | 0.12.0 > 0.13.0 | printed hand-over documents as PDF |
| stock | `7b8f4346a` | 2026-11-05 | 0.13.0 > 0.14.0 | voice routes |
| stock | `a131f14e5` | 2026-11-05 | 0.14.0 > 0.15.0 | storekeeper role permissions |
| assets | `cd6ddfd22` .. `6df6fc632` | 2026-11-05 .. 2026-11-07 | 0.1.0 > 0.8.0, seven bumps | card write path, expiry reminder, xlsx import, ledger registration, asset documents, `kind_change` document type |
| assets | G5 part 1 (GH #4037, T-1492) | 2026-11-08 | 0.9.0 > 0.10.0 | `opening` document kind (drafts, `POST /documents/:id/check`), record types `assets_opening` and `assets_opening_line` |
| assets | G6 (GH #4037, T-1493) | 2026-11-09 | 0.10.0 > 0.11.0 | xlsx import of opening lines (`assets_opening_line` import function), optional `external_ref_system` / `external_ref_id` pair on the opening header and line |
| assets | T-1488 (GH #3893) | 2026-11-08 | 0.11.0 > 0.12.0 | card holder from the register: `org_unit_id` optional on the card, refused on the card routes |
| locations | `c1ce8cc22`, `95b2a7ef8`, `b6d91d665`, `cb002500b` | 2026-10-30 .. 2026-11-03 | 0.1.0 > 0.4.0 | location tree, org unit links, write permission |
| org | `12ae85d3d`, `eaa1f1e49`, `acf6be347` | 2026-10-19 .. 2026-11-03 | 0.1.0 > 0.3.0 | employees as records, routes and write permissions |
| catalog_items | `e6650bb86`, `83589a94e`, `e77837a71` | 2026-10-19 .. 2026-11-03 | 0.1.0 > 0.3.0 | routes, item tracking policy (none, lot, serial, expiry) |
| codes | `d9f967f71`, `94d21b5e4`, `e8df61e8f`, `e38844c84` | 2026-11-02 .. 2026-11-08 | 0.1.0 > 0.4.0 | routes, scan lookup route `POST /resolve`, label route `POST /labels` |

Classes of decision 0055 D2 (A optional field or new type survives; B required field without a covering step needs the
administrator's acknowledgement; C rename or removal is refused): the class of a given pair is computed by the plan route at
promote time (`entity_types[].class` in the plan report) from the stored definitions, not guessed here. The commit subjects
above are mostly additions (new type, new optional field, new permission), which the plan reports as A. The one subject that
adds a rule to existing records is catalog_items `e77837a71` (item tracking policy): if the demo's items were stored before it,
that is a B candidate; read the plan.

What breaks the demo, as a standing list:

1. **A version bump of `org`, `locations`, `catalog_items` or `assets` in a build** (`codes` has had a window since T-1485). No window, so the promote of an
   existing demo is refused for that module (`409 no_upgrade_path`, exit 3 of the check). Fix in the same change that bumps:
   declare `min_upgradable_from` (a step-less module with only class A changes) or a migration step (REQ-773); otherwise the
   demo needs a database rebuild and a fresh seed. A task that bumps a module version should say so in its PR.
2. **A `stock` build that raises `min_upgradable_from` above the demo's version**, or a demo still below `0.10.0`.
3. **A change of the stored shape of a document or record** (a required field, a rename, a removed field) without a covering
   step: plan class B or C. The apply needs the administrator's acknowledgement (B) or is refused (C).
4. **A change of the seed script's expectation** (a document body shape): the seed script fails loudly with
   `STOP: <step>: HTTP 422 <reason>` after the promote (step 4 above). Fix the script in the same change.
5. **Handlers or stamp rules.** The apply moves the stamps of the module's process definitions
   (`owner_manifest_hash`) only if they carry the hash the tenant row had; a hand-edited definition keeps its stamp and its
   module writes answer `409 upgrade_required` (REQ-769 accepted hashes, REQ-771). Removing a write handler from a module breaks
   the running instances that call it.
6. **A promote that skips the chain.** With `LETFLOW_MODULE_UPGRADE_ON_BOOT` off (default) and no administrator apply, every
   changed module stays old, reads work, writes answer 409. `verify` exits 3 and names them.

Standing rules for infra: take a database backup before promote; run `snapshot` before and `verify` after; exit 1 means restore;
exit 3 means the chain is not complete, not that data is lost; run the seed script after every promote (it is idempotent and
fails loudly when a document shape changed). Keep `LETFLOW_MODULE_UPGRADE_ON_BOOT` as the owner decides: on, it applies only
what needs no administrator (class A, no data steps) and leaves the rest as `left_for_admin` (`Letflow.ModuleUpgrade.Boot.list_outcomes/0`).
