# Tenants behind the deployed module version after a deploy: upgrade on boot, a banner, a QA check

Recommendation to the owner, not a decision. Production module upgrades stay a deliberate step by the owner and are never
automatic. The only rule settled here is for QA (UAT), in `docs/uat/ba-decisions/T-1970.md`.

Written by the business analyst for task T-1970, 2026-11-14. Docs only: no code, route, flag or requirement is changed.

## 0. Short answer

1. **The upgrade on deploy is already built, but it is switched off.** `Letflow.ModuleUpgrade.Boot` (REQ-772, decision 0080
   Q3) applies, at application start, every plan that says `applicable_on_boot: true`. It runs only when the environment
   variable `LETFLOW_MODULE_UPGRADE_ON_BOOT` is exactly `true`. The default is `false`, and with it off the child reads and
   writes nothing. `applicable_on_boot` is a property of the plan ("this plan would be safe to apply without a person"); it
   is not an order to apply. So with the flag off, a plan can say `applicable_on_boot: true` and the tenant still waits for
   an administrator. Every task completion that calls a module write handler then answers 409 `upgrade_required`.
2. **QA (decided for UAT):** turn the existing flag on in the QA environment file. Decision 0080 Q3 already said "It is set
   to `true` on QA only"; nothing in this repository sets it, because the QA environment file is local to the QA host.
   Option (a) needs no new code for QA.
3. **Production (recommendation):** keep the flag off. Upgrade the tenants after each deploy with the fleet rollout
   (option c, already built: `Letflow.ModuleUpgrade.Fleet`, route `POST /platform-module-rollouts`, screen "Module
   rollouts"), started by the operator after the owner agrees to that deploy. Option (b), a banner with "Upgrade now" for
   the tenant administrator, is worth one later slice as a safety net for both environments. It is not needed to unblock QA.

## 1. Why `applicable_on_boot` did not upgrade the tenants

What the code does (sources opened: `lib/letflow/module_upgrade/boot.ex`, `config/runtime.exs` lines with
`module_upgrade_on_boot`, `lib/letflow/supervisor/infrastructure.ex`, decision 0080 Q3, decision 0055 D5):

| Step | What happens | Source |
|---|---|---|
| Flag | `Boot.flag_on?/0` is `Application.get_env(:letflow, :module_upgrade_on_boot, false) == true`. `config/runtime.exs` reads `LETFLOW_MODULE_UPGRADE_ON_BOOT` (exactly `true` or `false`, anything else stops the boot). Unset means `false`. | `boot.ex` `flag_on?/0`; `config/runtime.exs` |
| Flag off | `start_link/1` does nothing and returns `:ignore`. No plan is computed and no journal row is written. | `boot.ex` `start_link/1` |
| Flag on | For every registered tenant and every active module whose version or manifest hash differs from the compiled one: compute the plan (`UpgradePlan.plan/3`). If it says `applicable_on_boot: true` (all changes class A, no data step, every stamped definition passes the activation check), apply it through `Apply.apply_upgrade/4` as the system actor `00000000-0000-0000-0000-000000000000` with the rationale `upgrade on deploy to <version>`. | `boot.ex` `upgrade_one/4` |
| Not applied | Any other plan, a refused apply, or a module whose newest finished journal row is a rollback is left for the administrator (`left_for_admin`). A failed apply is rolled back fully and written as a `failed` journal row with a closed `error_code`. | `boot.ex` `left/4`, `failed/5`, `rolled_back?/2`; decision 0080 Q5 |
| When | Once, at application start, after `MigrationReplayBoot` and before the HTTP side starts. A running server never checks again. | `infrastructure.ex` child list |

So the plan flag means "safe without a person", and the environment flag decides whether that is acted on. The finding of
2026-11-14 (plans say `applicable_on_boot: true`, tenants not upgraded) matches the flag being off on QA.

**Not verified from here.** The QA host's environment file (`/opt/apps/letflow-qa/.env`, read through `env_file: .env` in
`deploy/docker-compose.qa.yml`) is not in this repository, so I could not read the flag's value. The operator confirms it in
one of two ways:
- the QA log of the last start has the line `module upgrade on boot: summary` (with `upgraded_count`, `left_count`,
  `failed_count`) only when the flag is on;
- the tenant's journal (`tenant_module_upgrades`) has rows with the system actor and a rationale starting
  `upgrade on deploy to` only when the boot child ran. `Boot.list_outcomes/0` reads exactly these rows; no route exposes it.

If the flag turns out to be on and the tenants are still behind, the cause is one of the other rows of the table
(`left_for_admin` after a refused apply, `failed` with an `error_code`, or a module held after a rollback). Those rows name
the cause; this note does not guess it.

## 2. The options

| | (a) Apply safe plans at boot | (b) Banner and "Upgrade now" for the tenant administrator | (c) Fleet rollout by the operator |
|---|---|---|---|
| Built? | **Yes**, REQ-772, flag default off. Per deployment: QA on, production off is pure configuration. | **No.** The plan and apply routes exist (`POST /api/v1/tenant/modules/:module_id/upgrade/plan`, `.../upgrade`, `:ModulesManage`), but no screen calls them: `web/src` has only the uninstall page and a 409 message text (`moduleLifecycleErrors.ts`, `UPGRADE_MESSAGE`). | **Yes**, `Letflow.ModuleUpgrade.Fleet`, routes in `lib/letflow/routers/platform_module_rollouts.ex` (`:ModuleRolloutsManage`, platform tenant's PLATFORM_ADMIN only), screen `web/src/pages/admin/module-rollouts/ModuleRolloutsPage.tsx`. |
| What it upgrades | Only plans that are class A with no data step; all tenants of that deployment. | One module of one tenant, any plan the apply accepts; the administrator reads the plan summary first and gives a rationale. | One module across every tenant that has it, in batches of 25 per call, one tenant at a time, within each tenant's `module_upgrade.window`; never sends `ack_destructive`. |
| Who decides | Nobody per deploy (the flag was set once). | The tenant's own administrator. | The operator, per module and version. |
| Stops on failure | Per tenant: rolled back, `failed` row, the boot goes on. No stop across tenants. | The one apply. | Halts after `LETFLOW_MODULE_ROLLOUT_HALT_AFTER` consecutive failed tenants (starting value 3, `Letflow.ModuleUpgrade.Settings.rollout_halt_after/0`); `resume` retries. |
| Gap after a deploy | None for safe plans. | Until the administrator acts. | Until the operator runs it. |

"For all tenants or for QA/demo only": the flag is read per running deployment, so "QA/demo only" is already the shape: set
it on QA (and on the demo, if the owner wants), leave it unset in production. A per-tenant allow list inside one
deployment is not needed for QA and is not recommended (another setting to get wrong, no source asks for it).

### Recommendation

- **QA: (a)**, the existing flag set to `true`. QA tenants are test data; a class A plan with no data step cannot lose or
  reshape data (decision 0055 D2, decision 0080 Q3 reason). This removes the 409 window after every QA deploy that bumps a
  module. Plans that are not class A still wait, and the operator applies them with (c) or the script in section 3.
- **Production: (c)**, started by the operator after the owner's go for that deploy, flag off. Reasons: decision 0080
  Q3 keeps turning the boot upgrade on in production as the owner's decision, and the owner's rule for this task is that
  production upgrades stay deliberate. (c) has a halt, a per-tenant window and an outcome list per tenant, which (a) does
  not. A production upgrade at boot would also run during the first start of a new node; `docs/design/rolling-deploy.md`
  (rows "Upgrade on boot" and I8) requires the flag to be `false` on both nodes during a roll.
- **Both, later: (b)** as one slice, so a tenant administrator is not stuck when the operator has not run (c), and so a
  plan that needs a person (class B with acknowledgement) has a place to be decided. Not needed to unblock QA now.

## 3. What the operator does today, and what stays manual

Today (before the QA flag is on, or for plans the boot leaves for the administrator):
- **Per module, all tenants (preferred):** as PLATFORM_ADMIN of the platform tenant, open "Module rollouts" (or
  `POST /platform-module-rollouts` with the module id) and repeat the call / press resume until the rollout is
  `completed`; read the per-tenant outcomes (`succeeded`, `failed` with `error_code`, `skipped`, `outside_window`).
- **Per tenant, scripted:** `scripts/demo_upgrade_chain.sh` with `BASE_URL` of QA, `TENANT_SLUG` and a TENANT_ADMIN token of
  that tenant (plan, apply, plan again until `up_to_date`; `DRY_RUN=1` plans only; exit 3 means a module still needs an
  administrator). It was written for the demo (one realm, one token for every slug); on QA, where a tenant has its own
  realm, run it once per tenant with that tenant's administrator token. UAT assumption, to be confirmed by the process
  owner: that QA tenants each have their own realm (I did not read QA's realm list; the script's header says "One token
  serves every slug (one demo realm)", which holds only when the tenants share a realm).

What stays manual in every environment:
- any plan with a class B or C change, or with a data step (the boot never applies a plan with a step; an administrator can apply
  declarative steps (`set_default`, `backfill_from_constant`, `copy_field`, REQ-773) up to the record cap
  `Letflow.ModuleUpgrade.Settings.one_tx_max_records/0`, starting value 1000 per decision 0080 Q5, in the apply's one
  transaction; a code step, a step outside that vocabulary or a plan over the cap is refused with `upgrade_needs_runner`,
  `lib/letflow/module_upgrade/apply.ex` moduledoc);
- the acknowledgement of a destructive change (`ack_destructive`); neither the boot nor the fleet ever sends it;
- activating the new process definition drafts an upgrade creates (decision 0055 D2 open point 7, confirmed by 0080 Q2);
- a rollback (`POST /api/v1/tenant/modules/:module_id/rollback`, per tenant, `:ModulesManage`); after a rollback the boot
  and the fleet leave that module alone until an administrator applies an upgrade again;
- in production: every upgrade (recommendation above).

## 4. Risks

| Risk | What happens | Mitigation |
|---|---|---|
| A plan fails at boot | The apply is one transaction: it rolls back, the tenant stays on the old version (writes keep answering 409 for that module), a `failed` journal row with a closed `error_code` is written, the boot continues and the server starts. | Read the log summary line after every QA deploy; a `failed_count` above 0 is fixed by a code change, then the next deploy retries. |
| Slow first start | The boot child runs synchronously before the HTTP side, once per tenant and per changed module. `deploy/redeploy-qa.sh` waits about 30 s (10 tries, 3 s apart) for `/health` and fails the deploy after that. With many QA tenants the deploy could fail its health check although the upgrade is correct. | Measure the time of the first QA start with the flag on (start line to `module upgrade on boot: summary`). If it nears 30 s, raise the wait in the deploy script or move the hook after the HTTP start (a code slice). Not measured here. |
| Image rollback after the upgrade | The tenants are on the newer version; the older image's compiled hash differs, so its writes answer 409 again, and the older plan cannot go back (no downgrade in the plan). | Roll the tenant back first, on the new build, with the rollback route, then revert the image. UAT assumption, to be confirmed by the process owner: this order; decision 0055 D9 and the `min_data_version` gate described in `docs/uat/ba-decisions/T-1519.md` are the long-term answer. |
| Two nodes in production | A node with the flag on upgrades while the old node still serves. | Flag `false` on both nodes (`docs/design/rolling-deploy.md` I8); production uses (c). |
| A module the administrator rolled back | Held by both the boot and the fleet (`rolled_back`). | Intended; the administrator re-applies. |
| Guard rule (T-1882, PM D-139) | A version bump that merges without an upgrade test from the previous pack can make the plan say a path exists while the apply fails (`activation_refused`, `step_required`, see `docs/runbooks/demo-upgrade-notes.md` items 8 and 9). With the flag on, such a defect shows as `failed` at boot instead of as a 409 later. | Already a rule: `test/letflow/module_upgrade/previous_pack_test.exs` G1 fails a bump without that test. |

## 5. Slices and effort

| # | Slice | Kind | Effort |
|---|---|---|---|
| S1 | Set `LETFLOW_MODULE_UPGRADE_ON_BOOT=true` in the QA host's environment file, restart once, read the summary line and the journal rows (section 1). | infra / operator, no code | under an hour |
| S2 | QA tenant check after every deploy: a read-only script (or a `DRY_RUN=1` run of `demo_upgrade_chain.sh` per QA tenant) that lists every tenant and module still behind and exits non-zero, run by the operator after each QA deploy. | small script in `scripts/`, with a test | one change |
| S3 | A read-only "upgrade pending" signal for `:ModulesManage` holders (installed version versus the version in the build, per module). Today `GET /me/modules` returns only `module_id` and the installed `version` (`lib/letflow/routers/me.ex`), and the plan route writes a `planned` journal row, so a banner must not call it on every page load. | backend, one route field, security review (tenant data path) | one change |
| S4 | Banner and "Upgrade now" screen for the tenant administrator: shows the plan summary (classes, drafts to activate, steps), asks for a rationale, applies with the `plan_hash`. Uses S3. | web, with the screenshot matrix | one to two changes |
| S5 | If S1 shows a slow first start: run the boot hook after the HTTP side is up, or bound it. | backend | one change, only if measured |

S1 unblocks QA by itself. S2 is the "QA tenant check" the task asks for. S3 and S4 are option (b). Production needs no new
slice for (c); the owner's go per deploy is a process rule, not code.

## Sources opened

`lib/letflow/module_upgrade/boot.ex`, `lib/letflow/module_upgrade/fleet.ex` (moduledoc), `lib/letflow/module_upgrade/rollback.ex`
(moduledoc), `lib/letflow/module_upgrade/settings.ex`, `lib/letflow/supervisor/infrastructure.ex` (child list),
`lib/letflow/routers/tenant_modules.ex`, `lib/letflow/routers/platform_module_rollouts.ex`, `lib/letflow/routers/me.ex`,
`config/runtime.exs`, `deploy/redeploy-qa.sh`, `deploy/docker-compose.qa.yml`, `scripts/demo_upgrade_chain.sh` (header),
`web/src/router.tsx`, `web/src/pages/admin/moduleLifecycle/moduleLifecycleErrors.ts`,
`docs/migration/decisions/0080-module-upgrade-working-path.md` (Q3, Q5, "Not decided here"),
`docs/migration/decisions/0055-module-upgrade-migration-uninstall.md` (D2, D5, by the amendments 0080 quotes),
`docs/runbooks/demo-upgrade-notes.md` (items 6 to 9), `docs/design/rolling-deploy.md` (rows naming the flag),
`docs/uat/ba-decisions/T-1519.md` (section 1).
