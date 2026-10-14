# Letflow core roadmap (2026-10-14)

- **Priority:** the user set platform core as PRIORITY 1 and WMS/procurement as PRIORITY 2 (relayed by the supervisor).
- **Wave order:** from the user's advisor (letflow-ec, answers Q6–Q8, relayed).
- **Target:** "a system like Odoo, but better", meaning better in applications, solutions, dynamic configuration and on-board scripting that is not Python. It is not about breadth or accounting parity.

The table covers each core item: the decision record it needs (DR), the gates, and who changes behaviour. Every core item is opt-in or backward compatible for existing tenants unless stated.

## Wave 1: foundations of correct data and the scripting path

| Step | Item | DR | Gates | Notes |
|---|---|---|---|---|
| W1a | Optimistic concurrency on entity update/delete (expected version, 409 on mismatch) | none expected | SECURITY-REVIEWER (tenant-data write path) | Prerequisite for the client API contract and for safe stock. |
| W1b | Append-only entity types (update/delete refused) | none expected | SECURITY-REVIEWER | Needed by ledgers (stock, audit-like records). |
| W2a | Pack install activates definitions, per module `on_install` | **0052** | REVIEWER | Unblocks the `org`/`catalog` foundation modules. |
| W2b | Field min/max and non-negative | none expected | SECURITY-REVIEWER | |
| W3a | Org-scoped role grants and enforcement | **0051** (+ backfill) | REVIEWER, SECURITY-REVIEWER, advisor ruling Q9 | Fail-closed; backfill before enforcement. |
| W3b | Task carries `scope_node`; candidate resolution filters by it | in 0051 (follow-up) | SECURITY-REVIEWER | Closes the pilot limit "any approver approves any department". |
| W4a | Tenant scripted rules: decision record | **0053** | REVIEWER, SECURITY-REVIEWER | Supersedes 0029 §1 and 0039 D7 on scripts. |
| W4b | Script registry (`script_rules`, versions, publish with SoD, stored tests) | 0053 | SECURITY-REVIEWER | |
| W4c | SERVICE_TASK `script` handler (first invocation point) | 0053 | SECURITY-REVIEWER | The answer to the row-lock question decides inline vs async. |
| W4d | Dry-run endpoint and per-run audit (wire `LuaScriptAudit`) | 0053 | SECURITY-REVIEWER | |

**Foundation modules alongside wave 1** (decision 0050):
- `org`: legal entity, site, org-unit tree, membership.
- `catalog`: item, UoM, later counterparty.

**WMS/procurement slices 1–2 run alongside wave 1:**
- Purchase request with approval.
- Procurement task and line status.

Neither slice needs a core change.

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
- extension fields in a tenant layer (`x_` namespace) that a module upgrade can never overwrite or collide with. Storage already exists (the JSONB `field_values` blob); the gap is definition ownership on upgrade, so this follows the wave-2 module upgrade/migration record (see 0053, "Requirement candidate: extension fields");
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
