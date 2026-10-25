# Letflow core roadmap (2026-10-14)

- **Priority:** the user set platform core as PRIORITY 1 and WMS/procurement as PRIORITY 2 (relayed by the supervisor).
- **Wave order:** from the user's advisor (letflow-ec, answers Q6–Q8, relayed).
- **Target:** "a system like Odoo, but better", meaning better in applications, solutions, dynamic configuration and on-board scripting that is not Python. It is not about breadth or accounting parity.

The table covers each core item: the decision record it needs (DR), the gates, and who changes behaviour. Every core item is opt-in or backward compatible for existing tenants unless stated.

## Wave 1: foundations of correct data and the scripting path

| Step | Item | DR | Gates | Notes |
|---|---|---|---|---|
| W1a | Optimistic concurrency on entity update/delete (expected version, 409 on mismatch) | none expected | SECURITY-REVIEWER (tenant-data write path) | Prerequisite for the client API contract and for safe stock. Issue #2528. **Merged**: PR #2542, 78cc6574. |
| W1b | Append-only entity types (update/delete refused) | none expected | SECURITY-REVIEWER | Needed by ledgers (stock, audit-like records). Issue #2529. **Merged**: PR #2546, 2be0d51d. |
| W2a | Pack install activates definitions, per module `on_install` | **0052** | REVIEWER | Unblocks the `org`/`catalog` foundation modules. Issue #2531. **Merged**: PR #2539, 5d6ead53. |
| W2b | Field min/max and non-negative | none expected | SECURITY-REVIEWER | Issue #2532. |
| W3a | Org-scoped role grants and enforcement | **0051** (+ backfill) | REVIEWER, SECURITY-REVIEWER, advisor ruling Q9 | Fail-closed; backfill before enforcement. Issues: #2533 (stage 1), #2535 (stage 2). |
| W3b | Task carries `scope_node`; candidate resolution filters by it | in 0051 (follow-up) | SECURITY-REVIEWER | Closes the pilot limit "any approver approves any department". Starts after 0051 stage 2 (GH #2535); not yet an issue. |
| W4a | Tenant scripted rules: decision record | **0053** | REVIEWER, SECURITY-REVIEWER | Supersedes 0029 §1 and 0039 D7 on scripts. |
| W4-7a | Tenant script runtime: exact allow-list sandbox, supervised watchdog, `ScriptAdmission` | 0053 | SECURITY-REVIEWER | Issue #2534. **Merged**: PR #2544, 02c682e0. Dependency hazards: last section of 0053. |
| W4-7b-1 | Script registry (`script_rules`, versions, publish with SoD, stored tests) | 0053 | SECURITY-REVIEWER | Issue #2534. Not merged. |
| W4-7b-2 | Policies: `script_policy` and `script_readable_master` tenant tables | 0053 | SECURITY-REVIEWER | Issue #2534. Not merged. |
| W4-7c | SERVICE_TASK `script` handler (first invocation point) | 0053 | SECURITY-REVIEWER | Closes #2534. Not merged. |
| W4d | Dry-run endpoint and per-run audit (wire `LuaScriptAudit`) | 0053 | SECURITY-REVIEWER | Issue #2534. |

**Foundation modules alongside wave 1** (decision 0050; issue #2530):
- `org`: legal entity, site, org-unit tree, membership.
- `catalog`: item, UoM, later counterparty.

**WMS/procurement slices 1–2 run alongside wave 1:**
- Purchase request with approval.
- Procurement task and line status.

Neither slice needs a core change.

### New issues (2026-10-14)

| Issue | Subject | Wave / precedes |
|---|---|---|
| #2547 | TENANT_ADMIN grant-path audit and admin count (0053 D6 amendment) | W3a: precedes 0051 stage 1 (#2533) |
| #2552 | API token issuer not recorded (`api_tokens`) | W3a: 0051 M2 |
| #2548 | `AuditRead` holders reading script source | W4 (7b) |
| #2543 | Idempotency key reuse | W1 follow-up |
| #2550 | Idempotency key squatting | W1 follow-up |
| #2551 | Import with a nil key | W1 follow-up |
| #2540, #2541 | Module install follow-ups (after #2539) | W2a follow-up |
| #2545 | 7a structs | W4 (7a follow-up) |
| #2553 | Vortex 8D waiver to reminder | HUMAN_TASK reminder follow-up (PR #2549) |
| #2554 | Reminder re-arm race | HUMAN_TASK reminder follow-up (PR #2549) |
| #2555 | `timer_type` enum | HUMAN_TASK reminder follow-up (PR #2549) |
| #2556 | Simulation runner and two timers | HUMAN_TASK reminder follow-up (PR #2549) |
| #2557 | A deactivated user's API token still authenticates (incl. TENANT_ADMIN) | W3 (precedes 0051 stage 1 enforcement; security prio 1) |
| #2558 | RoleBackfill resets the IdP sync marker for every user and can re-grant a revoked TENANT_ADMIN | W3 (after #2547; semantic decision needed) |

## Wave 2: transactional processes and lifecycle

| Item | DR | Notes |
|---|---|---|
| Process step writes entity in the same transaction | **0054** (Accepted 2026-10-15, advisor letflow-ec under the user's delegation) | Prerequisite for script commands and for stock posting. MVP: steps create records on append-only types only (0054 D1a.4). |
| Module upgrade and migration of installed modules (entity definitions included) | **0055** (Accepted 2026-10-15, advisor letflow-ec under the user's delegation) | Without it, shipped applications are frozen at their first install. Module uninstall (wave 3) and the tenant `x_` layer are NOT part of 0055; each gets its own follow-up record. |
| Entity pre-write validation and derived-field scripts (second invocation point) | 0053 | |
| Versioned documents (numbering, versions, signing hooks) | **0056** (Accepted 2026-10-15, advisor letflow-ec under the user's delegation; CUSTOMER DECISION REQUIRED items remain open for Kazakhmys) | Needed by every domain; KZ legal documents depend on it. Slice 1 = model, numbering, versions, `verify_binding`. Slice 2 = signatures, PDF, retention, legal hold, each with its own record. |
| Org-relative task assignment (resolver via the module Catalog, not in the engine) | yes (new) | For example "the requester's department head". |

**Filed requirements and their state (2026-10-15, filer letflow-2; GitHub is the work board):**

| Record | Requirement | Issue | State |
|---|---|---|---|
| 0055 D12 step 2a | REQ-498 effective-permission golden file in CI | #2586 | **done** (merged #2612, fe06bdd9) |
| 0054 | REQ-499 process step writes entity | #2587 | **in progress**: PR A (A1..A4) and PR B (B3 #2640, B1 #2642, B2 #2645) delivered; remaining PR C (SERVICE_TASK) after C0 and REQ-501 (#2590); #2587 stays open |
| 0054 option A | REQ-501 module write handlers for managed types (2 PRs) | #2590 | ready; depends on #2587 PR A and #2583 (merged 4242547e) |
| 0056 slice 1 | REQ-500 versioned documents (3 PRs) | #2588 | ready; pluggable OrgResolver accepted, so the org module is not a prerequisite of slice 1 |
| 0051 stage 1 | REQ-497 (PR 1a merged #2592, c55baa4f; PR 1b open #2601) | #2533 | in flight |
| 0053 hook 1 | scripts stage 1 (7a, 7b-1, 7b-2a, 7b-2b, 7c-1 #2605, 7c-2 #2607) | #2534 | closed |


Engine test seam note (PR B2, #2645): the B1 execution flag was deleted, and the engine's test seams are now gated by the compile-time test flag `:engine_test_seams` (`config/test.exs`), so no seam is compiled outside the test environment.

**WMS slice 5 (stock ledger) starts after "process step writes entity" (0054, Accepted).**

**Hard ordering blocker for slice 5** (supervisor ruling, 2026-10-15): no stock-ledger implementation starts, and no ledger entity type is installed in any tenant, until all four hold:
1. REQ-499 (GH #2587, process step writes entity, 0054) has merged; it replaces the local WMS draft REQ-484;
2. REQ-501 (GH #2590, module write handlers; 0054 option A: a managed type is written by a step only through a handler its module registers) has merged;
3. GH #2583 (core `Records` callers bypass the `managed_by` route guard) has merged;
4. the ledger type declares `managed_by` (`manages_entity_types`), and its posting runs in a write handler of its module, never as a declarative `entity_write`.

A stock ledger writable through the generic route would bypass every module check.

## Wave 3: breadth of configuration

| Item | DR | Notes |
|---|---|---|
| Generic list, pivot and graph views and a report builder over entities | yes (new) | Odoo's main breadth lever. |
| Solution versioning and per-tenant overrides | yes (amends 0039 D7) | |
| Module uninstall | yes (new): follow-up record to 0055, after `managed_by` (#2530) | Split out of 0055 (D11). 0039 D5 "No uninstall" stands until that record is ratified. Record: [0066](decisions/0066-module-uninstall-soft-uninstall-and-reactivate.md) (proposed). |
| Form-hook scripts (server-side form validation) and after-commit entity-event triggers via outbox | 0053 | Invocation points 3 and 4. |

## Customization beyond scripts

These are requirement candidates listed in the 0053 appendix, not yet scheduled:
- tenant-owned entity types: runtime definitions already exist. Missing are module references by id under 0050, relations and lookups in the UI, form and list generation, per-type write permissions, and 0051 scope declarations. Depends on 0050 and 0051 stage 2 (see 0053, "Requirement candidates");
- tenant extensions to module entities: an `x_` tenant layer of fields, validations and list/form/print overrides that module upgrades never overwrite. Depends on the wave-2 module upgrade record (0055, Accepted); its own follow-up record (0055 D4 keeps only the constraints an upgrade imposes);
- per-tenant form, list and print-template overrides, including KZ print forms;
- number sequences;
- extension points in module processes;
- integration mappings, scheduled jobs, notification templates and label overrides;
- data import;
- configuration export/import from test to production.

## Rules for every core item

- Each item is opt-in or backward compatible, so existing definitions, records and API clients keep working.
- Anything on a tenant-data path goes through SECURITY-REVIEWER.
- Anything that changes a decision record or a documented contract needs its own decision record and REVIEWER.
- The sole filer files the requirements GitHub-first (work board, decision 0049).

## Operational notes

- **Role binding seeds (PR #2537, GH #2524, merge 1465df2a).** The platform-role seed no longer "repairs" a built-in role binding that an administrator moved with `POST /roles/:id/rebind`. Instead it keeps the existing binding. A tenant with a ROUTING row named like any built-in role now fails closed: tenant onboarding and recovery fail, and `RoleBackfill` halts for that tenant. Before running onboarding, recovery or `RoleBackfill` on an existing environment, check for routing rows that carry a built-in role name (infra is running a read-only QA inventory). Rename them through the rebind or role flow first.
