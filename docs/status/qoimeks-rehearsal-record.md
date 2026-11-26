# Client 1 (Qoimeks) P2/P3 rehearsal record

Status page, written 2026-11-26 (task T-2856). **Engine proof only (D-194), QA only; nothing here
touches production.** It records what the engine's acceptance runs on QA actually showed, per run,
and what is not proven yet. Every figure below names its source. Nothing is estimated.

Plan and phase definitions: `docs/status/qoimeks-migration-readiness.md`, section 2.3 (steps
RH-0..RH-11), section 2.4 (the six reconciliation checks) and section 2.7 (phases P0..P9).

## 1. The main finding: no run has measured the six reconciliation checks

The runs listed in section 3 are **onboarding rehearsals** (the count approval switch, the
negative-balance setting, the fresh-tenant defaults) and a **ledger posting regression walk**. None
of them loads a converted same-shape data set (666 items, 134 places, 600 balances) and none of
them runs `qoimeks_compare.sh` or the quantity/hash compare (RH-5, RH-7). So the six checks of
readiness section 2.4 have **no measured result yet**. Section 2 states each as "not run", not as
failed.

The RH-9 timing (RH-3 to RH-7, which sizes the move window) is therefore **not measured**. The
durations in section 3 are the length of the engine's walk of the scenario, not the length of a
data move, and must not be used to size the window.

## 2. The six reconciliation checks (readiness section 2.4)

| # | Check | Result | Source / what is missing |
|---|---|---|---|
| 1 | Record counts: places, units, items, opening lines equal `expected_counts.txt` (`qoimeks_compare.sh` exit 0) | **not run** | No engine run executed RH-1..RH-5. No same-shape load exists on any rehearsal tenant (T-2407 prepare made one unit `PCS` and one item `ITEM1` by hand: `state/tasks/T-2407/runs/01-run.json`). |
| 2 | Quantity per (item, place) equals the frozen Qoimeks balance | **not run** | RH-7 tool is T-2024 (readiness 2.3, "planned, not built" in that page's text). |
| 3 | Hash of the sorted (item, place, quantity) list equal on both sides | **not run** | same as 2 |
| 4 | Totals per item equal; the bookkeeper confirms against the weekly workbook | **not run** | Needs the data load; the confirmation is a client step. |
| 5 | Barcodes: count per type equal (G12, T-2033) | **not run** | Needs the data load. |
| 6 | Client spot check of 20 items on the phone | **not run** | A client step; the number 20 is proposed, not sourced (readiness 2.4). |

## 3. Runs the engine did

Dates and times are UTC, from the engine's `runs` table (`state/team.db`, table `runs`, step `run`);
duration is `ended - started` of that step. Build shas are the QA `/health` ids quoted by the run's
own result text (`state/tasks/<id>/runs/01-run.json`, field `result`) or by the preflight log
(`state/tasks/<id>/runs/prepare-*.log`).

| Task | Phase | Date | Tenant | QA build sha | Run duration | Verdict | What it covered |
|---|---|---|---|---|---|---|---|
| T-2407 | P3-type: onboarding rehearsal 1 (count switch off, negative balances, count, reverse) | 2026-11-20, 14:26:57Z to 14:55:50Z | `sss-rehearsal` | start `6a86a81ba20ca5624e6710f5f2c6f4f1cb229602`, end `0fee90799534af86c9b48828c50b5cf1c876b34f` (QA was redeployed during the walk; the run did not poll in between) | 1733 s | **FAIL** (run and sign-off both FAIL) | Steps 1-5 PASS. Step 6-7 FAIL (EO-003): with the count rule Off, the storekeeper's count of 11 against book 10 (QCT-2026-000001) stayed `Issued` and waited for a second person. EO-004 partly failed: no `task.self_approved` audit entry, as a consequence. Steps 9-12 passed after the admin approved by hand. |
| T-2412 | re-run of rehearsal 1 after T-2410 | 2026-11-20, 17:13:00Z to 17:18:42Z | `sss-rehearsal` | `16bc4af51367` at start and end (preflight expected `16bc4af51367b25fa489c82e6228f350c0ee69f5`) | 342 s | **PASS** | The count of 11 against book 10 (QCT-2026-000002) posted at once with the rule Off; audit `task.self_approved`, note "self-approved, four-eyes off"; reversal back to 10; storekeeper refused on `/admin/approval-rules` and `/admin/ledger-settings`. Not covered: a colleague's count staying pending (one counter in the roster). |
| T-2419 | fresh-tenant rehearsal (first try) | 2026-11-20, triage 19:59:30Z (16 s) | none | none | audit and triage only, no run step | **no walk** | The worktree was cut before scenario `onboarding-rehearsal-2` and the `sss-rehearsal2` roster landed; the audit FAILed it and the triage said the run never started (`state/tasks/T-2419/runs/01-audit.json`, `01-triage_setup.json`). Process fault, not a product result. |
| T-2422 | fresh-tenant rehearsal (re-queued) | 2026-11-20, triage 22:44:57Z (16 s) | none | none | no run step | **no walk** | `uat.sh` read `onboarding-rehearsal-2` from the title as the scenario group; no such group exists. Operator fault (`state/tasks/T-2422/runs/01-triage_setup.json`). |
| T-2424 | P3: rehearsal 2, fresh tenant, defaults OFF (D-165) | 2026-11-20, 22:49:37Z to 23:01:58Z | `sss-rehearsal2` | `df0494fb68ad` at start and end (the T-2421 merge); the first preflight showed QA `8f02076b60b6` and waited for the redeploy (`prepare-1795214790.log`) | 740 s | **PASS** | Both approval rules read Off "Never changed (default: off)"; the storekeeper's count of 11 against book 10 (QCT-2026-000001) posted at once, `task.self_approved` in audit with `setting_source tenant_default`; reversal back to B = 10; rule On then Off with the D-164 reason, `approval_rule.changed` in audit; storekeeper refused. The scenario is not repeatable on this tenant: the explicit count row now stays. |
| T-2434 | ledger posting regression walk (group `qoimeks-ledger`, six scenarios) | 2026-11-26, 04:31:27Z to 05:15:10Z | `qoimeks-qa2` | start `62a0e4f399bc28089dc2516f936989e413585090`, end `00d175aed7cb68bdecea6ce06e723f8e5d9bb599` (changed during the walk; between them no lib, priv, config or deploy file changed, per the run's own text) | 2623 s | **PASS**, sign-off `ACCEPT_WITH_ISSUES` | No legitimate completion was refused (receipt, transfer, opening self-approval rule Off, admin2 approval rule On, reversals returned 200). Scenario 3 Part B (steps 16-24) **BLOCKED by environment**: `scripts/qoimeks_qa2_fixture_ledger3.sh` was not run. |

Only the `run` step durations are used above. The T-2407 and T-2412 data load was one receipt of
10 PCS made by hand; it is not a rehearsal data set.

## 4. Not proven yet

Engine task state read from `state/team.db` on 2026-11-26:

| Task | Title (short) | Engine state | What stays unproven |
|---|---|---|---|
| T-2435 | UAT `qoimeks-count` (posting regression after the T-2429 fixes) | running | count group regression |
| T-2436 | UAT `qoimeks-import` | cancelled | import group regression: **no result** |
| T-2437 | UAT `qoimeks-retry` | ready (not started) | retries |
| T-2438 | UAT `qoimeks-move` | cancelled | the move group: **no result** |
| T-2439 | UAT onboarding-rehearsal scenario 1 after the T-2429 fixes | cancelled | rehearsal 1 on a build after T-2429 is not repeated; the last run of it is T-2412 (build `16bc4af51367`) |
| T-2440 | UAT `qoimeks-completion` (crafted completion refused, API-driven) | ready (not started) | the crafted-completion refusal |
| T-2441 | scenario 3, Excel stock load: written, **not walked** | done (scenario written; its run is T-2442) | the Excel load path; its static check only |
| T-2442 | UAT onboarding-rehearsal scenario 3 only | ready (not started) | Excel stock load with the count rule Off |

Also not proven:

- All six reconciliation checks of section 2 (no data load, no compare, no hash).
- The window time (RH-9), the second same-shape rehearsal (RH-11), and the formal count with
  `freeze_locations` (RH-10).
- `qoimeks-ledger` scenario 3 Part B (retired master, steps 16-24), blocked by the fixture script.
- A single rehearsal on one build with every group green: the runs above cover different builds
  and tenants.

Not done by any task here: production items P5-P7. This page records QA engine runs only.
