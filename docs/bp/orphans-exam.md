# Orphans of the area exam

Every item of `python3 scripts/uat/bp_inventory.py exam` (15 routes, 13 screens, 2 rules) is used by a task of
`docs/bp/exam.json`; no inventory item is orphaned.

Orphan review D-169 (T-2561, 2026-11-21): the inventory has no orphan item; one function outside the inventory is a
real orphan and is recorded below as prose (decision (c)); the table only takes inventory items. Only callers found by
`grep -rn create_assignment lib web/src`: `lib/letflow/modules/catalog.ex:201` (`create_via_module_surface/2`,
documented "a system path with no HTTP user, for the mix seed task"), whose only callers are
`lib/mix/tasks/letflow.seed.exam_fixtures.ex:597` and `:655`. No router, no screen, no pack handler reaches it
(`web/src/modules/exam/BilimBagaAdminPage.tsx` states the assignment gap in its header comment).

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|

## Real orphan outside the inventory (decision (c), keep)

- function: `Letflow.Modules.Exam.Authoring.create_assignment/2`, `lib/letflow/modules/exam/authoring.ex:131`
- what it does: writes one `exam_assignment` record (who may sit which exam); `check_assigned` reads it at exam start
- who added it and when: Vladimir Titenko, 2026-10-27, commit 465bb04ba `feat(REQ-582): exam assignment part B` (#3374); the seed path `create_via_module_surface` came with REQ-510 slice 3, d4f5fb0d4 (2026-10-24)
- why it exists: REQ-582 made assignment a stored model enforced at exam start, but no admin route or screen to write it was added; the seed task fills it for fixtures
- proposed action (owner decides): give it a process (an assignment screen and route, then a task in BP-EXAM-02), otherwise keep it as a seed-only platform function. No removal is proposed: enforcement at exam start depends on the records it writes. Nothing was deleted.
