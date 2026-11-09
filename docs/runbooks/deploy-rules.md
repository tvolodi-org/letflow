# Runbook: deploy rules (expand/contract, build / restart / tenant upgrade)

Slice S1 of D-114(3), "updates at runtime". Source: the design note
`docs/uat/ba-decisions/T-1519.md` (sections 2, 3, 6 and 8) and decision records
`docs/migration/decisions/0055-module-upgrade-migration-uninstall.md` (D5 skew and
expand/contract, D7 grants, D8 forbidden changes, D9 rollback) and
`0080-module-upgrade-working-path.md`. Docs only: this page changes no code and no
requirement. It states rules for UAT and QA; production values are the process owner's.

The one sentence to remember: **deploy is global (code), upgrade is per tenant (data).**
A new build reaches every tenant at once. A tenant upgrade is a database transaction on a
running server and needs no restart. A tenant upgrade cannot give a tenant new code.

## 1. What needs a build, a restart, or a tenant upgrade

| Kind of change | New build and restart of the server? | Tenant upgrade needed? | Notes |
|---|---|---|---|
| Elixir code (routers, engine, handlers) | Yes | No | Compiled into the release. |
| Module manifest (entities, process pack, permissions, ledgers, routes) | Yes, for the manifest itself | Yes, for each tenant that has the module | The manifest and pack file are compiled into the build. The tenant keeps the old version until plan and apply run (`POST /api/v1/tenant/modules/:module_id/upgrade/plan`, then `.../upgrade`). |
| Permissions and role grants | Yes | No, and the upgrade cannot gate them | Live for every tenant at deploy (0055 D7). Widening a grant is refused by rule until per-tenant grants exist. |
| Tenant-schema DB migration | Runs at boot (`TenantProvisioning.MigrationReplayBoot`) | No | The upgrade boot child starts after the replay, so new columns exist when it runs. |
| Shared (public) schema DB migration | Run once by the deploy step before the new build takes traffic | No | UAT assumption, to be confirmed by infra: how the release invokes it is not in this repository. |
| Tenant data change (data step) | No | Yes, but not possible yet | The apply refuses any plan with a step (`upgrade_needs_runner`) until the runner exists (REQ-773, slice S4). |
| Database-backed setting (tenant setting, feature flag stored in the database) | No | No | Changes at run time. |
| Environment or boot flag (`LETFLOW_*` variables read in `config/runtime.exs`, for example `LETFLOW_MODULE_UPGRADE_ON_BOOT`) | Yes, a restart of the node | No | Read once at boot. `LETFLOW_MODULE_UPGRADE_ON_BOOT` is consumed by a one-shot boot child (`Letflow.ModuleUpgrade.Boot`); changing the variable of a running node does nothing until that node restarts. |
| Web bundle (`web/`) | No server restart | No | Users must reload; an open tab runs the old bundle against the new API. |
| Mobile app | Store release, cannot be forced | No | Old apps call the new API. |

Web and mobile follow the same rule as the database: the API must stay compatible with the
previous bundle and app for one release.

### What the BEAM can hot-load, and what we do not

The BEAM can load new module code into a running node (`code:load`, or a release upgrade
with appup/relup). **We do not do this.** Reasons:

1. Our state lives in Postgres, not in long-lived processes (REQ-045: no process per
   workflow instance), so hot loading buys almost nothing.
2. A relup is written and tested by hand for every release, and a mistake damages a running
   node instead of failing at start.
3. The compiled manifest, the permission matrix and `Application.compile_env` values are
   read at compile time; loading a module does not change them.
4. With two nodes, a plain restart of one node at a time gives the same "no downtime" with a
   much simpler failure mode.

Safe to change without a release or restart: data and database-backed settings. Environment
variables and boot flags need a restart of the node.

## 2. Expand / contract checklist for a database or module-data change

During a rolling deploy build N and build N+1 both run on the same Postgres, and tenants
stay at version N until upgraded. So every change goes in two releases.

Before merging a change that touches the database or a module's stored data:

- [ ] **Expand release only adds.** A new column (nullable or with a default), table, index,
      entity type, optional field, process definition version, enum value, permission atom
      or route. The old build ignores it and keeps working.
- [ ] **Nothing is dropped, renamed or retyped** in the same release. Dropping a column is not
      allowed at all in an upgrade (0055 D8.1).
- [ ] No nullable column becomes NOT NULL without a default. No constraint is tightened that
      the old build can still violate.
- [ ] New code **tolerates version-N data** on every path, including non-HTTP paths (service
      tasks, task and form resolution, webhook delivery, pollers). The skew gate covers HTTP
      only (0055 D5, open point 8).
- [ ] A **compatibility test** runs the module's code over fixtures at the previous data
      version (0055 D5 ruling).
- [ ] The module version is bumped, and the plan shows what happens to a tenant on the
      previous version. Look at the class of the change: A (additive, automatic), B (needs the
      admin's acknowledgement), C (refused). A plan with an empty path is fine if only
      permissions and routes changed.
- [ ] If tenants on an older version must still be upgradable, `min_upgradable_from` in the
      manifest covers them. If you cannot cover them, say so in the PR and in
      `docs/runbooks/demo-upgrade-notes.md` (the table of windows).
- [ ] After the release: upgrade every tenant (admin action, the upgrade-on-deploy flag for
      Class A set on the final new-build restart, or `scripts/demo_upgrade_chain.sh` for the demo fleet) and check each plan
      reads `up_to_date`.
- [ ] **Contract release (later).** Remove the old thing, and only now raise `min_data_version`.
      Only after every tenant with the module installed was upgraded at the previous release,
      and after the fleet driver exists (0055 D5, D12; slice S6). Neither `min_data_version`
      nor the fleet driver is built today, so **no contract release is allowed yet**.

## 3. Rolling deploy preconditions

Rolling (two or more nodes, replace one at a time, health check between) is the recommended
way to avoid downtime. Run it only when all of these hold:

- [ ] Every database change in the release is expand-only (section 2).
- [ ] The shared-schema migration has run before the first new node takes traffic.
- [ ] The new build is compatible with the previous web bundle and mobile app.
- [ ] No tenant has been upgraded to a version the old build would reject. Today the refusal
      `module_version_ahead` is **not built** (slice S3), so this is a rule you keep by hand:
      do not run tenant upgrades until the last old node is gone, or you cannot roll the
      code back.
- [ ] `LETFLOW_MODULE_UPGRADE_ON_BOOT=false` (the default; exactly `true` or `false`) on **every**
      node for the whole mixed-build window. When it is `true`, a node that boots applies every
      eligible Class A upgrade at once (`Letflow.ModuleUpgrade.Boot`). The advisory lock only
      stops two nodes applying the same upgrade twice (the second is refused with
      `upgrade_running`); it does not stop an old node from serving a tenant that was just
      upgraded. So the flag must be off until the last old node is gone. The flag is read at
      boot, so set it before the nodes start.
- [ ] After the last old node is drained, apply the upgrades explicitly (admin action, or
      `scripts/demo_upgrade_chain.sh` for the demo fleet), or restart with the flag `true`
      as a deliberate final step on the new build only.
- [ ] Migration replay is assumed idempotent when two nodes start within seconds. UAT
      assumption, not yet confirmed.
- [ ] A health check is defined between nodes. The rolling procedure on QA (two nodes, drain,
      measured upgrade time) is slice S2 and needs infra: until it is done, treat this list
      as the intended procedure, not a tested one.

Blue-green is not recommended now: it doubles hardware and, with one Postgres, does not
remove the compatibility need.

### What a tenant sees while it waits for its upgrade

A tenant that has not upgraded keeps working on its old definitions (old manifest hashes are
accepted, REQ-769). Only the module's write handlers are refused: a human task completion
answers 409 `upgrade_required` and the task stays pending (REQ-771). An unupgraded tenant
degrades; it does not go down.

## 4. Rollback

| Layer | Rollback |
|---|---|
| Code (the build) | Redeploy the previous build. Safe only while no tenant is at a version the old build rejects, and never after a contract release. |
| Failed tenant apply | Automatic: one transaction, the tenant stays on the old version, the journal row is `failed`. |
| Tenant version after a done upgrade | Not built (slice S5, designed in 0055 D9). Roll forward with a corrective release. |
| Shared-schema migration | Never drop to undo. Roll forward with a corrective release. |
| Web bundle | Redeploy the files. |

## 5. Example from our own chain: codes 0.3.0 to 0.4.0 (2026-11-08)

A build shipped codes 0.4.0 with changes to permissions and routes only, but the manifest
had no `min_upgradable_from`. For a module with none, only the current version has an upgrade
path (see the table in `docs/runbooks/demo-upgrade-notes.md`). The tenant on codes 0.3.0
(QA, `gate-b5`) could not plan: `no_upgrade_path`. Its code writes answered 409
`upgrade_required`, and nothing in the application could fix it.

What the checklist would have caught: the "bump the version and look at the plan for a tenant
on the previous version" item. The fix was one line, `min_upgradable_from: "0.1.0"` in
`lib/letflow/modules/codes/codes.ex` (T-1485, commit `00643fd70`), because 0.1.0 to 0.4.0
differ only in permissions and routes, so a plan with an empty path exists and apply keeps all
data. Test: `test/letflow/modules/codes/upgrade_http_test.exs`.

The same page lists the modules (stock before 0.10.0, org, locations, catalog items, assets
before 0.14.0) where a version bump without a declared window already leaves an older demo
with no path; those need a re-seed. Rule: **a build that bumps a module version is not done
until a tenant on the previous version can plan and apply.**

## 6. Order of work for this subject

S1 (this page) then S2 (rolling deploy on QA), S3 (`min_data_version` gate and
`module_version_ahead`), S5 (rollback route), S4 (data-step runner), S6 (fleet driver),
S7 (application package for on-site installs). Open owner questions (downtime promise,
upgrade window default, rollback promise) are listed in `docs/uat/ba-decisions/T-1519.md`
section 9.
