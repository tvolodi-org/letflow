# Runbook: the Client 1 move (phase P7), with a dry run on QA

Phase P7 of `docs/status/qoimeks-migration-readiness.md` (section 2.7): move Client 1 (`sss`) from Qoimeks to Letflow outside the
client's working hours: freeze Qoimeks writes, copy, check-only run, load, post, six checks, users switch. All six checks pass,
or the move is rolled back.

**Status: a plan to read, not a script to run.** Nothing on production is done by this page or by the dry-run scenario. P5 (the
production set-up) and P7 itself are not done by any task. The dry run (below) touches QA only and plays only the parts a JSON
runner can play. The Russian text is `docs/runbooks/qoimeks-move-p7.ru.md` (same steps, same order).

This page does not repeat the other runbooks; it orders them and says who acts:

- the tenant, realm, host, users and cutover rules: `docs/runbooks/production-tenant-onboarding.md` (steps 0 to 23, "Rollback summary");
- the load, the compare tools and the move rules (freeze, ANALYZE, rollback): `docs/runbooks/qoimeks-rehearsal.md`, steps 1 to 12;
- the pilot order and the four-eyes decision: `docs/runbooks/pilot-rollout.md`, step 6.

## Who acts

| Who | Does |
|---|---|
| **Owner** | The single go for production (D-118): one decision before P7 starts. Nothing else in this page needs the owner, except the no-go of the last section. |
| **Operator** | Everything that is Letflow's: the tenant, the extract and convert, the check-only run, the load, the posting, the six checks, the users, the rollback. |
| **Infra** | The production host and keys, the backup and the restore test, the realm and its clients, the one `ANALYZE;`. |
| **Client** | Switches the Qoimeks write freeze on and off (the Qoimeks team), names the users, uses the notice. Letflow does not switch the freeze. |

## The production tenant: route 3, and the owner's own tenant on route 4

Letflow has two ways to create a tenant without a person at the platform console (`docs/platform-register-tenant-v2.md`, section 0):
**route 3**, `POST /admin/v1/tenants` (the provisioner mount, operated by infra), and **route 4**, the self-service sign-up
(`Letflow.Signup.Provisioning.create_tenant/2`). Both start the registration process `platform.register_tenant`.

- The **Client 1 production tenant is created through route 3**, by the registration process, as step 4 of
  `docs/runbooks/production-tenant-onboarding.md` says. Do not create it by hand and do not use route 4 for it.
- **The owner's own tenant is the first user of route 4**: the owner signs up through the sign-up page, as any later company will.
  It is a separate tenant, it is not Client 1, and it is not part of the move. It proves route 4 on production; a fault found there
  is a finding, never a reason to change the Client 1 tenant.

## The steps, in order

Do them outside the client's working hours. Write down the time of each step (the freeze time is part of the record, step 10 of
`qoimeks-rehearsal.md`).

| # | Step | Who | Done when |
|---|---|---|---|
| 0 | **Owner's single go (D-118).** Before anything else. No go, no P7. | owner | the go is written down with its date |
| 1 | **Production is ready (P5).** Host, keys, backups with a restore test, alerts. | infra | restore drill passed |
| 2 | **Create the tenant through route 3** and finish the onboarding steps 2 to 8 and 11 to 23 of `production-tenant-onboarding.md` (realm, first administrator, host, modules, definitions, one administrator or two, cutover rules). | infra, operator | the readiness check (step 8 of that runbook) passes |
| 3 | **Freeze Qoimeks writes** (`MAINTENANCE_MODE`, writes answer 503). Write down the time it was switched on. | client | writes answer 503 |
| 4 | **Extract and convert** from the frozen copy (`qoimeks-rehearsal.md`, steps 1 and 2). Read `report.txt`; exit 3 means dropped rows: decide before going on. | operator | `expected_counts.txt` written, nothing dropped without a decision |
| 5 | **Check-only run**: every file with `dry_run=true` (steps 3 and 6 of the rehearsal runbook). Nothing is written. | operator | every row is as expected, nothing refused |
| 6 | **Load**: the same files with `atomic=true`, masters first, then headers, then the lines (rehearsal steps 3 to 6). | operator | every file answers as in step 5 |
| 7 | **Post**: issue each opening document and complete its approval task; positive documents first, negative last (rehearsal step 6). The approver holds `StockApprove`; check `GET /api/v1/modules/stock/approval-access` first. | operator | every document is `posted` |
| 8 | **ANALYZE**: one `ANALYZE;` after posting (rehearsal step 11). | infra | done |
| 9 | **The six checks** (below). All six must pass. | operator | all six pass, or go to ROLLBACK |
| 10 | **Users switch**: create the staff accounts, link each employee to the user, hand out the sign-in and the phone address (onboarding steps 11, 15, 16); the client reads the notice. Qoimeks stays read-only for 30 days (P8). | operator, client | each user signed in once |
| 11 | **Lift nothing on Qoimeks.** Qoimeks stays frozen: it is now the read-only copy. | client | confirmed |

The move is one window. Nothing from step 3 on is repeated after a failed check: a failed check is a rollback, then a new window.

## The six checks (step 9)

Take them from the real tools, never from memory. Each one passes or fails; a difference is read as written by the tool.

| # | Check | Tool or call |
|---|---|---|
| 1 | Record counts equal to the extract | `scripts/pilot/qoimeks_compare.sh OUT/expected_counts.txt after.txt TENANT_SLUG` (rehearsal step 7), exit 0 |
| 2 | Quantity per item and place equal | `scripts/pilot/qoimeks_balances_compare.py` (rehearsal step 8), exit 0, equal hashes |
| 3 | Master data equal (locations, units, items) | `scripts/pilot/qoimeks_masters_compare.py` (rehearsal step 9), exit 0 |
| 4 | Every negative balance equals the extract exactly | read-back of `GET /api/v1/modules/stock/balances` (rehearsal step 6) |
| 5 | Every opening document is posted, none is pending or draft | `GET /api/v1/modules/stock/documents`, each document `posted` |
| 6 | The approver can act and the storekeeper cannot | `GET /api/v1/modules/stock/approval-access`: 200 with `can_approve: true` for the administrator, 403 for the storekeeper (`pilot-rollout.md`, step 6) |

## ROLLBACK

Any check fails, or the client or the owner says stop: **lift the Qoimeks write freeze** (the Qoimeks team switches `MAINTENANCE_MODE`
off). The Qoimeks data was never changed, and the phones still hold the Qoimeks address and token (rehearsal step 12). The Letflow
company is kept, not deleted; deactivate the tenant only on the operator's decision (`production-tenant-onboarding.md`, "Rollback
summary"). Posted opening documents cannot be undone. Anything entered in Letflow after the switch is taken from the stock movements
export and entered in Qoimeks by hand. After the first full business day without a rollback the move is past its point of no return
(P8).

## Checklist for the operator

Tick in the record of the window, with the time:

- [ ] Owner's single go (D-118) written down
- [ ] Restore drill passed (infra)
- [ ] Tenant created through route 3; readiness check passed
- [ ] Qoimeks freeze on (client); time written down
- [ ] Extract and convert; `report.txt` read, no unexplained drop
- [ ] Check-only run clean (`dry_run=true`)
- [ ] Load (`atomic=true`)
- [ ] Every opening document posted, positive first
- [ ] `ANALYZE;` (infra)
- [ ] Check 1 counts, 2 quantities, 3 masters, 4 negatives, 5 posted, 6 approver
- [ ] Users switch; each user signed in once
- [ ] Qoimeks stays read-only for 30 days
- [ ] OR: rollback done, freeze lifted, time written down

## The dry run on QA

`test/uat/processes/BP-QOIMEKS-P7-dry-run.json` (runner id `BP-QOIMEKS-P7-dry-run`) walks the same order against an existing QA
company with its two test actors. It writes nothing, so it needs no cleanup. It plays only what a JSON runner can: the freeze, the
extract, the file upload, the posting task and the production tenant are NOT played (the runner sends no file and has no Qoimeks
or provisioner credential). Each step names the P7 step it stands for:

| P7 step | Scenario steps |
|---|---|
| 3 freeze (client, not Letflow) | not played: no Letflow call exists |
| 5 check-only run | q1 to q3 (the check refuses without unit, with an unknown unit, without a workbook; nothing is written) |
| 6 load | q4 to q5 (the load refused for the storekeeper and without a workbook) |
| 7 post | q6 (approver access) |
| 9 six checks | q7 (balances read), q8 (current stock downloads), q9 (list of loads unchanged) |
| rollback | q10 (the list of loads equals the start: nothing to roll back) |

The real route-3 creation and the real load are covered by `BP-PLATFORM-01` and by `test/letflow/modules/stock/qoimeks_files_test.exs`.
The run's verdict is the engine's (`uat_smoke`); nothing here claims it has passed.

## Not decided here

The date and hour of the window (P6, the team sets it), the number of users (the client's list), and every open owner item of
`production-tenant-onboarding.md`, "Owner decisions this procedure needs".
