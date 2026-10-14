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
| Process step writes entity in the same transaction | yes (new) | Prerequisite for script commands and for stock posting. |
| Module upgrade and migration of installed modules (entity definitions included) | yes (new) | Without it, shipped applications are frozen at their first install. |
| Entity pre-write validation and derived-field scripts (second invocation point) | 0053 | |
| Versioned documents (numbering, versions, signing hooks) | yes (new) | Needed by every domain; KZ legal documents depend on it. |
| Org-relative task assignment (resolver via the module Catalog, not in the engine) | yes (new) | For example "the requester's department head". |

**WMS slice 5 (stock ledger) starts after "process step writes entity".**

## Wave 3: breadth of configuration

| Item | DR | Notes |
|---|---|---|
| Generic list, pivot and graph views and a report builder over entities | yes (new) | Odoo's main breadth lever. |
| Solution versioning and per-tenant overrides | yes (amends 0039 D7) | |
| Module uninstall | yes (new) | |
| Form-hook scripts (server-side form validation) and after-commit entity-event triggers via outbox | 0053 | Invocation points 3 and 4. |

## Customization beyond scripts

These are requirement candidates listed in the 0053 appendix, not yet scheduled:
- tenant-owned entity types: runtime definitions already exist. Missing are module references by id under 0050, relations and lookups in the UI, form and list generation, per-type write permissions, and 0051 scope declarations. Depends on 0050 and 0051 stage 2 (see 0053, "Requirement candidates");
- tenant extensions to module entities: an `x_` tenant layer of fields, validations and list/form/print overrides that module upgrades never overwrite. Depends on the wave-2 module upgrade record;
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
