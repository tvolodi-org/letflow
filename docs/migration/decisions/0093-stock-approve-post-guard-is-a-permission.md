# 0093 -- The guard of stock approve and post tasks is a permission (`StockApprove`), not the role label TENANT_ADMIN

Status: PROPOSED (T-2305, 2026-11-19; from `docs/status/qoimeks-decision-check-2.md` finding D2). Documents only: no code,
migration, route or permission change in this task. PM direction of 2026-11-19: guard as a permission, with security review.
Amends the application of 0088 D1/D5 to the stock module; it does not change 0088. The number 0093 was the next free one on
origin/main at T-2305 (0092 is the highest).

Legend: **V** = verified by reading the file on this branch; **G** = architect's judgement.

## The question

Today a storekeeper cannot approve a count or post a receipt only because the task is ADDRESSED to the role name `TENANT_ADMIN`.

* V: the shipped stock processes name `"role" => "TENANT_ADMIN"` on the post, approve and reverse HUMAN_TASK nodes
  (`priv/modules/stock/generate_pack.exs`, the `process_definition` and the opening `approve` node); the same label is used in
  `priv/modules/assets/generate_pack.exs` (lines 222, 257, 298).
* V: `Letflow.Tasks.apply_claim/5` and `apply_completion_authz/3` refuse with `:assignee_role_not_held` when `ref in scope.role_names`
  is false (`lib/letflow/tasks.ex`, the `assignee_type: "ROLE"` clauses).
* V: the pack's own comment says the label "is only a label ... the ledger authority step decides who may complete the task
  (StockPost / StockReverse)". That is not true as a refusal of the storekeeper: STOREKEEPER holds `StockPost` and `StockReverse`
  (`Letflow.Modules.Stock` `role_grants`), and `TasksComplete` (`core_role_allows?(:STOREKEEPER, ...)` in
  `lib/letflow/api/authorization.ex`). So when the addressing check is absent, nothing else stops the storekeeper.
* V: the addressing answer changes when an administrator reassigns the task (`TasksReassignRouted`, `lib/letflow/api/authorization.ex`),
  when a tenant renames or replaces the routing role, or when a module version changes the label.

0088 D1: "would renaming the role change an access answer? If yes, it is a role-name check and must be replaced." 0088 D5: routing is
addressing and never grants or refuses. Today the refusal of the storekeeper is produced by addressing. That is the contradiction.

## Decision

**D1. Option (a): the guard is a permission; addressing stays a label.** A HUMAN_TASK node that approves or posts stock names a
required permission. The engine refuses to claim or complete the task for a caller who does not hold that permission in scope,
whoever the task is addressed to and however it was reassigned. The `"role"` attribute stays and keeps one meaning: who finds the
task in My Tasks (0088 D5, 0081 D1 "routing roles carry no permissions"). Option (b) (addressing as the rule) is rejected: it makes
the answer to "may the storekeeper approve" depend on a name a tenant can change or an administrator can reassign, which is
exactly what 0088 D1 forbids, and it cannot be proven by a test that survives reassignment.

**D2. One new permission `StockApprove`.** Tenant scope. Meaning: "may approve a count, post a held stock document or complete a
stock reversal task that another person prepared". Declared by the stock module (version bump, see F2). Held by the tenant-admin
protected row automatically (`grants = all_tenant_scope`, 0088 D3). **Not** in the STOREKEEPER `role_grants` and not in the closed
core list for STOREKEEPER. Assignable (0088 D4): a tenant's own role, for example a chief accountant or a warehouse manager, may be
given it; a one-person company has one person who is the tenant admin and holds it. Rejected alternative: reusing `StockReverse`
or `StockPost` -- the storekeeper holds both and needs them for his own work (issue, receipt, start a reversal), so they cannot
separate the two people.

**D3. Where the check lives.** One generic node attribute `required_permission` (string, a permission atom name) on HUMAN_TASK
nodes, read by `Letflow.Tasks` in `apply_claim` and `apply_completion_authz` through `Authorization` (pure, tenant-free, 0088 D1),
in addition to the addressing comparison, not instead of it. The process-definition validator (graph checks) refuses an unknown
atom and a non-tenant-scope one. The check fails closed: a missing or unreadable permission set refuses. The refusal code is the
existing not-found/forbidden shape for tasks, so INV-5 holds (a caller who may not see the task is not told that it exists).
Alternative considered and rejected: a stock-specific check inside the module-write handler. It would run after the task step, only
for stock, and the assets module (same label, three nodes) would need a copy; the generic attribute serves both. G: the assets
nodes use the same attribute with a permission of the assets module in a later slice (F5); not decided here.

**D4. Interaction with the four-eyes switch.** `distinct_from` (`SeparationOfDuties`) is a different rule ("a different person") and
stays; `docs/design/four-eyes-switch.md` is unchanged. `required_permission` answers "may this kind of person do it", the switch
answers "may it be the same person who prepared it". With four eyes off, a tenant admin who prepared a document may still approve it
(audit line of that design); a storekeeper may not, with the switch on or off. Reassignment (`TasksReassignRouted`) can move a task
to another addressee but can never make a holder-less caller able to complete it.

**D5. Existing rows.** Process definitions already deployed on QA keep the node attribute set they have (definitions are versioned
and pinned). The new `required_permission` goes into a new definition version of each stock process (module version bump), exactly
as every other process change. Running tasks of old pinned definitions keep addressing-only behaviour until they finish; nothing
widens (a storekeeper is still refused by addressing there). No data migration; no tenant row changes; nothing is granted by an
upgrade (0088 D7).

**D6. Not changed.** The pack comment ("the ledger authority step decides") is corrected in F1 to say the permission on the node
decides and the label only routes. The routing comparisons in `tasks.ex` stay as data (0088 D5).

## Which scenarios change wording

All four are `test/fixtures/uat/scenarios/`. The behaviour they expect (the storekeeper cannot approve or post) stays; the reason in
the text changes from "routed to the administrator role" to "the approver must hold the approve permission, which the storekeeper
does not".

| Scenario | Where | Change |
|---|---|---|
| `qoimeks-count-3` | steps 3 and 5 | "the second person is the administrator" becomes "the second person holds StockApprove (here the administrator)". |
| `qoimeks-count-6` | header actors line (the long "routed to the role TENANT_ADMIN, so the storekeeper does not see them" sentence), step 5, EO-003 | Replace "approval task is routed to the administrator role" by the permission rule; keep "not offered in My Tasks" as a separate routing fact; add an expectation that a direct API attempt by the storekeeper on the administrator's task is refused (today only the absence from the list is checked). |
| `qoimeks-count-7` | the reversal-task step | Same wording as count-3 for the reversal task. |
| `qoimeks-ledger-2` | :57 and EO-002 (:145) | "the storekeeper issues a receipt, the administrator completes the posting task": say that the completer holds StockApprove; note that in a one-person company the person is the tenant admin and holds it (matches `four-eyes-switch.md` section 6). |

New expectation common to all four after F2: the same refusal still holds after the administrator reassigns the task to the
storekeeper, and after the routing role is renamed.

## Tests that prove it (written in F2)

* T1: storekeeper (holds `TasksComplete`, `StockPost`, `StockReverse`, no `StockApprove`) claims and completes an approve task
  addressed to TENANT_ADMIN: refused. Same for a post task and a reverse task. Through the real router with a real token.
* T2: administrator reassigns the task to the storekeeper (`TasksReassignRouted`): storekeeper still refused on claim and complete.
* T3: the routing role in the definition is changed to a name the storekeeper holds (or the label is removed from the fixture):
  storekeeper still refused; a holder of `StockApprove` in a tenant role (not named TENANT_ADMIN) is allowed.
* T4: cross-tenant: a holder in tenant B cannot touch tenant A's task, and the answer is indistinguishable from not found (INV-5, INV-10).
* T5: graph validator refuses `required_permission` with an unknown atom, a platform-scope atom and a non-string value.
* T6: `permission_matrix` golden contains `StockApprove` for TENANT_ADMIN and PLATFORM_ADMIN rules as computed, not for STOREKEEPER;
  the 0088 D1 scan (no access answer by role name) is extended to the new clause.

## Follow-up implementation (not in this task), with sizes

| # | Task | Size | Notes |
|---|---|---|---|
| F1 | Engine and tasks: `required_permission` attribute on HUMAN_TASK, graph validation, check in `apply_claim` and `apply_completion_authz`, tests T1-T5 for a core fixture process | M (about 1 day; touches `tasks.ex`, `definitions/graph.ex`, pins on task refusals) | Security review mandatory (tenant data path, INV-5/INV-10). First, no module change. Correct the misleading pack comment. |
| F2 | Stock module: add `StockApprove` (module version bump), set it on the post, approve and reverse nodes in `generate_pack.exs` and regenerate the pack, `mix letflow.permission_matrix --write`, tests T1-T3, T6 against the real stock processes | M | After F1. About 15 pinned spots move (new permission atoms, golden, tenant-auditor refused set, module version pins, previous-pack G1); do not run beside another permission task. |
| F3 | Runbook and docs: `docs/roles.md`, pilot runbook (who holds approval), module doc | S | With F2. |
| F4 | Scenario wording of count-3, count-6, count-7, ledger-2 and the new reassignment and rename expectations | S | After F2 merges (scenarios describe delivered behaviour). |
| F5 | Same attribute on the three assets nodes with an assets permission (decision for the assets owner) | S-M | Optional; not decided here. |

## Owner table

| # | Question | Recommendation |
|---|---|---|
| Q1 | Name `StockApprove`? | Yes; the name is a working name until F2. |
| Q2 | Should the tenant admin be able to give `StockApprove` to a custom role? | Yes (assignable, 0088 D4), so a warehouse manager need not be the tenant admin. |

## Not decided here

* Any code, migration, route, flag or version number. The assets nodes (F5).
* Whether the My Tasks list should also hide tasks the caller cannot complete (today it is addressing; a separate UI matter).

## Verified vs guess

* V: the label, the claim and complete comparisons, STOREKEEPER's grants, `TasksReassignRouted`, the pack comment, the four scenario files exist as cited.
* G: the attribute name, the permission name, the sizes, and the claim that the refusal cannot be bypassed through other routes of the
  module (the module-write handlers still check their own permission; F1 must read every completion path of `tasks.ex` first).
