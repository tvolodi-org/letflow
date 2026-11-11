# Audit of the GAP sidecars (task T-1672, batch 7 item 9)

Source: `docs/uat/ba-decisions/T-1665.md` item 9. Read-only audit of the files in
`test/fixtures/uat/scenario-env-limitations/` on main at `723f95a90`. Nothing is deleted or edited here;
closable sidecars are removed in a follow-up task (each needs its scenario written or re-run first).

`ls test/fixtures/uat/scenario-env-limitations | wc -l` printed 35 (T-1665 cited 32, which does not match the 35
files present; B6#7 deleted two and modified one). All 35 are listed. The one that B6#7 and
T-1648 already updated (`platform-runtime-updates-3`) is marked "already reviewed".

Method: for each file I read `classification`, `reason`, `review` and checked the stated blocker against main
with grep (commands in the checks below). I did not run any scenario. "Closable" means the blocker named in
`review` no longer holds on main; the sidecar still needs a scenario run before removal.

Verdicts: **blocked** (the stated blocker still holds), **closable** (the blocker is gone), **permanent**
(the limit is by design and will not change; the sidecar is the correct final state).

## Checks run

* Roster: `grep -in "storekeeper\|PROCESS_DESIGNER" test/fixtures/uat/actors.yaml` finds only a comment (line 186);
  `builtin_roles` entries show two TENANT_ADMIN actors (swiftroute-alice, bilimbaga-admin), no second SwiftRoute administrator; one `CANDIDATE` actor (line 138).
* Exam notification switch: `grep -rn exam_notifications_enabled config lib` gives `false` in `config/config.exs:188`.
* Exam assignment route: `grep -n assign lib/letflow/modules/exam/router.ex` finds only `conn.assigns` and the
  `not_assigned` refusal; no route writes an assignment (REQ-582 open question 3 still open).
* Webhook delivery trigger: `grep -rn "Webhooks.deliver" lib` outside `webhooks.ex` finds only docs and moduledoc
  mentions, no caller.
* Module settings: `grep -n settings_schema lib/letflow/modules/*/*.ex` now finds real schemas in
  `assets/assets.ex:192` and `stock/stock.ex:327` (assets is wrapped by the pack `modules/assets/pack.json`).
* Agent routers: `lib/letflow/router.ex` lines 91 to 93 still list `AgentRequests`, `AgentResponses`, `AgentEvents` as deferred.

## Table

| # | Sidecar (file name, `.yaml` omitted) | Class | Issue | Verdict | One line |
|---|---|---|---|---|---|
| 1 | bilimbaga-certificate-pdf-download-other-candidate-and-tenant-refusals | GAP | #3342 | blocked | Roster still has one bilimbaga candidate and none elsewhere. |
| 2 | bilimbaga-exam-analytics-4-access-auditor-worker-agent-runner | GAP | #3350 | blocked | No exam-tenant auditor or worker in the roster; no second exam tenant. |
| 3 | bilimbaga-exam-analytics-6-scoped-caller-empty-result | GAP | #3350 | blocked | No roster actor with a limited access scope. |
| 4 | bilimbaga-exam-assignment-2-targeted-assignments | ENV_NOT_SUPPORTED | #3307 | blocked | No assignment write route (checked), one candidate. |
| 5 | bilimbaga-exam-assignment-3-refusal-text-and-other-company | ENV_NOT_SUPPORTED | #3307 | blocked | Same route gap; no second exam tenant. |
| 6 | bilimbaga-exam-grading-2-mark-and-session-finalisation | GAP | #3324 | blocked | The audit-trail half is blocked on a readable audit screen (the sidecar's `review` names it). Permanent part: two overlapping requests cannot be made by a UAT actor, so the row lock stays a backend test. |
| 7 | bilimbaga-exam-grading-4-access-candidate-refused | GAP | #3324 | blocked | No per-role Bilimbaga actors, no unauthenticated actor. |
| 8 | bilimbaga-exam-grading-6-examiner-screen | GAP | #3323 | blocked | Needs a setup that prepares 26 or more waiting answers next to the 3-answer queue. |
| 9 | bilimbaga-exam-notifications-2-result-message-on-submit | ENV_NOT_SUPPORTED | #3363 | blocked | Switch still `false` in shipped config (checked); no per-tenant switch. |
| 10 | bilimbaga-exam-notifications-3-assignment-message-person-only | ENV_NOT_SUPPORTED | #3363 | blocked | Switch off, and no route writes assignments or calls the assignment notice. |
| 11 | bilimbaga-exam-notifications-4-other-company-sees-no-row | ENV_NOT_SUPPORTED | #3363 | blocked | Switch off. |
| 12 | bilimbaga-exam-notifications-5-ids-only-in-delivery-log | ENV_NOT_SUPPORTED | #3363 | blocked | Switch off. |
| 13 | bilimbaga-exam-parent-4-session-draws-one-version | ENV_NOT_SUPPORTED | #3315 | blocked | A new exam is startable only with an assignment; no route to create one. |
| 14 | bilimbaga-my-results-3-other-candidate-other-company-and-role-refusals | GAP | #3321 | blocked | Needs a second candidate, a bilimbaga auditor and a no-permission account. |
| 15 | meridian-loan-origination-kyc-manual-review | ENV_NOT_SUPPORTED | #3076 | blocked | The KYC stub always answers "clear"; a mock service keyed to the applicant does not exist on QA. |
| 16 | platform-frontend-guard-selfcheck | COVERED_ELSEWHERE | ISS-0900 | permanent | System-only steps, covered by CI guard specs; remains valid while those tests exist. |
| 17 | platform-out-of-order-effect-completion | COVERED_ELSEWHERE | ISS-0900 | permanent | Covered by `ordering_test.exs`; QA drives only HTTP and UI. |
| 18 | platform-partition-retention-drop | ENV_NOT_SUPPORTED | ISS-0901 | permanent | Backdating a partition needs direct SQL; the product deliberately has no such endpoint. |
| 19 | platform-runtime-updates-3-fleet-start-halt-resume | GAP | T-1625 | blocked (already reviewed) | Updated by B6#7 and T-1648; a rollout of a real module and the halt after N failures stay unrun on shared QA until a disposable QA instance exists. |
| 20 | platform-sandbox-cross-tenant-probe | UNBUILT_FEATURE | ISS-0890 | blocked | Agent routers are still deferred (checked); remove only when the runtime-agent subsystem is built. |
| 21 | platform-solution-pack-override-access-and-other-company | GAP | #3353 | blocked | No PROCESS_DESIGNER actor, no second company with the pack installed. |
| 22 | platform-solution-pack-update-3-access-and-other-company | GAP | #3443 | blocked | No actor that holds exactly DefinitionsCreate. |
| 23 | platform-tenant-switch-cache-isolation | ENV_NOT_SUPPORTED | ISS-0901 | blocked | Needs an HTTP write path for `tenant_memberships`; none found. |
| 24 | provisioning-8-signup-verify-to-tenant-created | GAP | T-1625 | blocked | Needs a mailbox the UAT runner can read (owner or infra). |
| 25 | swiftroute-first-login-administrator-binding | ENV_NOT_SUPPORTED | (none) | permanent | The condition (open grant, unverified address) can never become true in the seeded company. |
| 26 | swiftroute-tenant-onboarding-happy | ENV_NOT_SUPPORTED | ISS-0895 | permanent | The slug stays reserved on QA because `TenantPurge` keeps the `tenants` and `tenant_lifecycles` rows (`lib/letflow/tenant_purge.ex`) even though `POST /:slug/purge` and `TenantProvisioner.delete` exist; the sidecar's own text (deactivate-only) is outdated. Unless a disposable QA lane exists. |
| 27 | tenant-administration-16-integration-mapping-mapped-outbound-delivery | UNBUILT_FEATURE | #3201 | blocked | `Webhooks.deliver/3` still has no production caller (checked). |
| 28 | tenant-administration-31-print-override-second-administrator-activation-and-audit | ENV_NOT_SUPPORTED | #3289 | blocked | Needs an owner-approved second SwiftRoute administrator (roster has two TENANT_ADMIN actors: swiftroute-alice, bilimbaga-admin). |
| 29 | tenant-administration-53-notification-delivery-assign-sends-and-logs | GAP | #3310 | permanent | Needs a failing mail adapter or direct DB writes; backend tests cover the rest. |
| 30 | tenant-administration-59-print-templates-screen-second-administrator-activates-and-retires | ENV_NOT_SUPPORTED | #3436 | blocked | Same second-administrator need as row 28. |
| 31 | tenant-administration-65-solution-pack-override-closed-list-and-reason-refusals | GAP | #3353 | **closable** | `review` says "revisit when a shipped module declares a settings schema": `assets` (`assets.ex:192`, pack `modules/assets/pack.json`, built in #3929) and `stock` now do. Follow-up: write the accepted and undeclared-key steps against assets, run, then remove. Confirm first that the QA company has assets installed. |
| 32 | tenant-administration-73-pack-overrides-screen-list-create-edit-and-retire | GAP | #3523 | permanent | Loading and server-error states need a held or failing request; they stay web unit tests. |
| 33 | tenant-administration-75-pack-update-report-override-outcomes-errors-and-languages | GAP | #3523 | blocked | No roster user holds module-management without override-management (same roles in `docs/roles.md`); `property_gone` needs a shortened list. |
| 34 | tenant-administration-78-role-sidebar-storekeeper | GAP | T-1583 | blocked | No STOREKEEPER account in the roster (checked); owner or infra provisions it. |
| 35 | tenant-administration-extension-points-declaration-and-site-checks | ENV_NOT_SUPPORTED | 3256 | blocked | No upload route for a module and no shipped module declares an extension point (only the test fixture module). |

## Totals

* closable now: 1 (row 31).
* permanent: 7 (rows 16, 17, 18, 25, 26, 29, 32).
* still blocked: 27 (the rest, including row 6; most wait on a roster addition, a second exam tenant, an assignment route, the
  exam notification switch, or a mailbox, all owner or infra decisions).

## Reading notes

* Row 26 is "permanent" with a condition in the line; if the condition changes the verdict moves to blocked. Row 6 is blocked (audit screen) with a permanent row-lock limitation inside the line.
* Row 31 is the only removal the audit proves. Removing it needs a scenario run, so it is a follow-up task, not this one.
* Several groups share one unblocker, worth one owner decision each: a second bilimbaga candidate and an
  exam-tenant auditor/worker (rows 1, 2, 7, 14); an exam assignment route (rows 4, 5, 10, 13); the exam
  notification switch on QA (rows 9 to 12); a second SwiftRoute administrator (rows 28, 30).
* Sources opened: the 35 sidecars (fields `classification`, `reason`, `review`, `issue_ref`), `test/fixtures/uat/actors.yaml`
  (grep only), the greps listed under Checks run, `docs/uat/ba-decisions/T-1665.md`, and the stat of `e2cfb154b`.
  Not read: the cited scenario files, backend tests, and issue bodies.
