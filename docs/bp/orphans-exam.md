# Orphans of the area exam

Every item of `python3 scripts/uat/bp_inventory.py exam` (15 routes, 13 screens, 2 rules) is used by a task of
`docs/bp/exam.json`; no inventory item is orphaned.

Orphan review D-169 (T-2561, 2026-11-21): the inventory has no orphan item; one function outside the inventory is a
real orphan and is recorded below as prose (decision (c)); the table only takes inventory items. Only callers found by
`grep -rn create_assignment lib web/src`: `lib/letflow/modules/catalog.ex:201` (`create_via_module_surface/2`,
documented "a system path with no HTTP user, for the mix seed task"), whose only callers are
`lib/mix/tasks/letflow.seed.exam_fixtures.ex:597` and `:655`. No router, no screen, no pack handler reaches it
(`web/src/modules/exam/BilimBagaAdminPage.tsx` states the assignment gap in its header comment).

Gaps that keep BP-EXAM-02..06 partial (T-2551): there is no way to give a candidate an exam through a route or a screen, so the runner cannot play the candidate's start, sit, grade and certificate processes (no assignment, no session). Needed: a route and screen that write `exam_assignment` (or a runner fixture that does), then scenarios for BP-EXAM-03..06. Their refusal paths are already played by BP-EXAM-07.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|

## Gaps found by the dry run (T-2551)

- Answer option writes: on the dry-run tenant the administrator is refused (403, restricted fields) when writing is_correct, so BP-EXAM-01 plays no answer option step. Needs the field restriction to be lifted for the exam author or a tenant without it.
- parent_id: the active category/question definitions of the dry-run tenant do not declare parent_id (REQ-586 rollout), so the tree and lineage refusals are not played.

## Real orphan outside the inventory (decision (c), keep)

- function: `Letflow.Modules.Exam.Authoring.create_assignment/2`, `lib/letflow/modules/exam/authoring.ex:131`
- what it does: writes one `exam_assignment` record (who may sit which exam); `check_assigned` reads it at exam start
- who added it and when: Vladimir Titenko, 2026-10-27, commit 465bb04ba `feat(REQ-582): exam assignment part B` (#3374); the seed path `create_via_module_surface` came with REQ-510 slice 3, d4f5fb0d4 (2026-10-24)
- why it exists: REQ-582 made assignment a stored model enforced at exam start, but no admin route or screen to write it was added; the seed task fills it for fixtures
- proposed action (owner decides): give it a process (an assignment screen and route, then a task in BP-EXAM-02), otherwise keep it as a seed-only platform function. No removal is proposed: enforcement at exam start depends on the records it writes. Nothing was deleted.
