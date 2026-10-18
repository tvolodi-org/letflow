# REQ-519: enforced-tenant writers (2e) and the flag value `on` (2f), org-scoped role grants stage 2 (GH #2535)

AGENT: CODE-DESIGNER. Workflow WF-02, run `WF02-REQ519-ENFORCED-WRITERS-20261018`, step 01.
Base: `main` 12a6587b7 (REQ-517 2a #2765 and 2b #2782, REQ-518 2c-i-a #2806, 2c-i-b #2817, 2c-ii #2835, 2d #2838 merged).
Branch `feature/WF02-REQ519-ENFORCED-WRITERS-20261018`. Design only: signatures are `@spec`-shaped text, queries are
prose, no function bodies, no `.ex` blocks.

Sources read in full: `docs/requirements.yaml` REQ-519 (22 ACs, `depends_on: [REQ-518, REQ-517]`, line 36798), decision
0051 (D1, D8, D11, D12, Rollout 3 and 4, Q3, Amendment 1 A1 to A7), `docs/agents/instructions/security-invariants.md`
(INV-1, 2, 4, 5, 8, 10), designs `req517-scoped-grants-admin-plane.md` (3.5 lock order, 4.7 and 4.8 shadow evidence,
13, 14, 16) and `req518-compiler-scope-filter.md` (4.2, 7, 8), handoffs `WF02-REQ517-.../step-04, 07, 12, 13` and
`WF02-REQ518-.../step-01, 18, 24` (conditions carried), the open issues #2832 #2833 #2834 #2840 #2809 #2800, and the
as-built code: `Letflow.ScopeEnforcement`, `Identity.RoleScopeGrants` (+ `Backfill`), `Identity.RoleRegistry`,
`Identity.TenantAdminMigration`, `Identity` (membership writers, `sync_role_claims_from_token/3`, counts, lock A),
`Identity.PendingAdminGrants`, `Identity.TokenPreconditions`, `Identity.TenantAdminGuard`, `Identity.ScopedGrants`,
`Api.Scope`, `Api.RouteScope`, `Api.Scope.Enforce`, `Api.Scope.Shadow`, `Api.Scope.ShadowEvidence`, `Routers.TenantScopeEnforcement`,
`Routers.Identity` (flag, service-principal, roles, members), `Tasks` (F1), `Entities.ScopeDeclaration`,
`Modules.Catalog` rule 11, `Audit`, `Plugs.Authorize`, `Plugs.AuthPipeline`, `config/test.exs`, the 115-line route
snapshot, `docs/roles.md`, and the existing tests that pin today's `on`-is-unsettable behaviour.

## Changelog

| Rev | Date (UTC) | Change |
|---|---|---|
| r0 | 2026-10-18 | Initial design: 2e (enforced-tenant writers) and 2f (flag `on`, last), route census for SEC C-1/C-2, evidence gate algorithm, requirement amendments RA-1..RA-9, SEC ruling requests S-1..S-10. |
| r1 | 2026-10-18 | CDV FAIL rework (step-02): G1 typed suppressed sync result via a new sibling in `Identity` (3.9a); G2 Backfill gap-check, audit and dry-run behaviour for an enforced tenant (3.6a); G3 scan narrowed to the AC's six functions plus `Backfill.run`, registry keyed by those call sites, indirect rows verified separately (3.4); lows: `mode_under_lock!` absent-row behaviour and test survey (3.2), `copy_members` M-row, TAM skip also skips legacy-binding removal and token rewrite (S-1), integrity test moved to 2f-a, RA-10. |
| r2 | 2026-10-18 | SEC design gate PASS_WITH_FINDINGS (step-04) folded. C-1 (2e-a): production `mode_under_lock!` RAISES for a malformed prefix or a missing `tenants` row; the lenient `:off` exists only behind a TEST-ONLY key (3.2), REPLACING the S-1b softening of r1. C-2 (2e-a): a raised mode read rolls the write back, sweeps report that tenant (3.2a). C-3 (2e-b): roles each candidate group binds are read AFTER lock A; routing roles never widen (3.9). C-4 (2f-a): fact 4 counts only INTERACTIVE explicit tenant-wide admins (4.4). C-5 (2f-b): the flip 500 path logs one constant line (4.2). C-6 (2f-b): platform tenant stored `on` test (4.2a). C-7: ruling ids in sections 11 and 13, per-PR SEC verdict list in the PR checklist (section 1), ON_IN_PRODUCTION text in sections 6 and 4.10. Folded: S-1 seeding audit key, S-3 behaviour-change list, S-5 scans and docs sentences, RA-1 T-C2 reachability, RA-6 filed before 2f-b merges, advisories A-1..A-8. |
| r2a | 2026-10-18 | CDV step-05 tiny fix: dry-run mode read in 3.6a uses `get_mode/1`, not `mode_under_lock!/1` (which raises outside a transaction). |
| r1a | 2026-10-18 | CDV step-03 tiny fixes: INV-1 row aligned with S-1b; W-e row names the mix-task `Backfill.run` caller as scanned row W-e2. |
| r0a | 2026-10-18 | CODE-DESIGN-VALIDATOR step-02 small fixes (design NOT yet approved, FAIL, see handoff): F5 marker-stamping description corrected to the as-built `group_ids != []` condition; exam census 12 -> 8 snapshot lines; test id collision T-W1..T-W4 -> T-RW1..T-RW4; T-E16 defined; T-B1..T-B14 mapped to registry order; MU-5 killers; integrity test PR assignment note. |

---

## 0. Findings against the requirement text and the as-built 517/518 (read first)

| # | Finding | Decision |
|---|---|---|
| F1 | The FACTS line numbers are stale. As built on main 12a6587b7: `reconcile_binding!` callers are `role_registry.ex` 304, 534, 565, 576, 789 and `tenant_admin_migration.ex` 349, 398 (unchanged); `flip/4` is `scope_enforcement.ex` 141, `do_flip` 173, `enable_checks!` 202, `parse_mode` 90; `sync_role_claims_from_token/3` is `identity.ex` 1539, `add_group_member/3` 890, `remove_group_member/3` 1158, `delete_group/2` 1006 (rows deleted 1026). | Anchors below are by function, with the verified line only as orientation. |
| F2 | AC 1 classifies the seven call sites of the six named functions but MISSES two writers that reach `reconcile_binding!` through `upsert_role/4`: the platform-role SEEDING nil branch (`RoleRegistry.ensure_platform_role_binding/2` creates the binding through `upsert_role`, role_registry.ex ~304 to 311) and the `TenantAdminMigration.ensure_binding(nil, schema)` branch (tenant_admin_migration.ex 365). Under AC 1 row (a) both would be REFUSED inside a nested transaction. For seeding that is an availability defect: `RoleBackfill.run/0` uses `Enum.reduce_while` and HALTS the whole all-tenants sweep on the first `{:error, _}`, so one `on` tenant missing a newly added platform role would block seeding of every tenant after it. | RA-1: two rows added to the writer table. Seeding nil branch is NO-ROW (empty seeded group, binding created without a row, reported; sweep continues). TAM nil branch: the per-tenant run reports `skipped_enforced` (3.6). SEC ruling S-1. |
| F3 | AC 1 (c) requires an explicit `{:skipped, :enforced}` "that the caller logs and surfaces", but `upsert_role/4`, `seed_default_platform_role_groups/1` and the TAM report return fixed shapes that callers pattern-match, and `reconcile_binding!/3` returns `:ok` today (callers write `:ok = reconcile_binding!(...)`). | `reconcile_binding!/3` returns `:ok | {:skipped, :enforced} | {:refused, :scope_required}`; every existing `:ok =` match becomes a case (a forgotten caller raises `MatchError` and rolls back: loud, safe). The public return shapes of `upsert_role/4` and seeding are UNCHANGED; the report travels through NEW sibling functions (3.5). |
| F4 | AC 2 and AC 3 say the sync is suppressed "into a group whose applicable row is tenant_wide". A group can be bound to SEVERAL roles (`tenant_roles.group_id` is not unique), and a membership grants every platform role the group binds. Evaluating only the claimed role would let a claim for role R1 silently widen the user for R2 through the same group. | The suppression test is the NO-WIDENING principle: compute the user's effective scope per platform role bound to the group, before and after the hypothetical membership; suppress when any role goes to `tenant_wide` from a non-tenant-wide state. One event per (user, role). SEC ruling S-2. |
| F5 | `sync_role_claims_from_token/3` stamps `role_claims_synced_at` whenever the RESOLVED `group_ids` list is non-empty (identity.ex, `if group_ids != []` around the `Multi.update(:user ...)`; the ISS-0773 comment says 'only when a grant was written' but the code stamps on a non-empty resolution, and an already-existing membership is a no-op `{:cont, acc}`); an empty resolution leaves the marker nil so the next login retries. CDV correction of r0 (which said the stamp needs a written membership). Consequence: the stamp condition must stay `group_ids != []` evaluated on the list resolved BEFORE the suppression partition; if the partition filtered `group_ids` first, a user whose every claimed group is suppressed would retry on every login (lock A with a bounded 2s wait plus a dedup lookup, forever). | A sync in which every candidate was suppressed (and recorded) STILL stamps the marker. Recorded as RA-9 / S-2. |
| F6 | `group_member.added` / `group_member.removed` already exist (GH 2547) with `roles_gained` / `roles_lost`, but NOT the effective-scope delta `(role, from, to)` that AC 4 and 0051 D1/D8 require. | Additive key `scope_delta` on both entries (3.8); existing keys and tests unchanged. |
| F7 | AC 7 and AC 15 say "`Audit.list_entries` and its action filter". `Audit.list_entries/1` has NO action filter (filters: from, to, actor_id, resource_id, resource_type, cursor); SEC 517 step-04 already noted "F8 (no action filter)". | The test reads through `list_entries` with the `resource_type`/`resource_id` filters and asserts the action in the returned items. One NEW read, `Audit.latest_matching/4`, serves the shadow-window start (4.5). RA-4 corrects the wording. |
| F8 | AC 8 asserts "`:ScopeEnforcementManage` maps to a tenant-scope permission (`Authorization.permission_scope/1 == :tenant`)". `permission_scope/1` of the KEY atom classifies an unlisted atom as `:platform` (the trap named in the REQ-497 PR 1b comment above the `required_permission/1` clauses of the scope-enforcement keys); the right assertion is `permission_scope(required_permission(:ScopeEnforcementManage)) == :tenant` (the permission is `:UsersGroupsRolesManage`). | Test T-H1 asserts the composed form. No code change. |
| F9 | AC 8 narrows PUT to "a tenant-wide TENANT_ADMIN authenticated as an interactive user". Stage 1's PUT used `Scope.require_tenant_wide(conn, :UsersGroupsRolesManage)`, which also admits a platform-tenant PLATFORM_ADMIN (holds every permission) and API tokens. Decision 0051 D12 says "tenant-wide TENANT_ADMIN or platform scope". The AC is the narrower rule and matches AC 12 of REQ-517 (service-principal flag: `require_oidc` plus `require_tenant_admin_tenant_wide`, routers/identity.ex 741 to 757). | Built as the AC says; the platform-tenant PLATFORM_ADMIN losing the right to flip its OWN tenant's flag is listed as a behaviour change in the PR body. The check helper is hoisted so the two routes cannot diverge (4.2). SEC ruling S-3. |
| F10 | AC 13 re-keys `check_reason` "on the transition". The stage-1 pre-transaction check is keyed on the TARGET, and `off` without a reason answers 422 `reason_required` even for a same-mode off -> off request (stage-1 test pins it). A fully transition-keyed check would change that answer to 200 unchanged. | Minimal change: the pre-transaction check stays target-keyed (`off` mandatory, `shadow`/`on` validated when present); ONE new rule is evaluated inside the transaction after the tenants row lock: previous `on` and target `shadow` with no reason is `reason_required`. RA-8. |
| F11 | AC 9 and the REQ-517 follow-up ask that the evidence gate "count requests on EVERY day" and that `counts_between` "is called once per UTC day". `ShadowEvidence.counts_between/3` returns ONE sum over a range, so the per-day rule cannot be computed from it, and calling it once per day issues N+1 queries (default 8) inside the flip transaction. | New `ShadowEvidence.counts_by_day/3` returns the per-day, per-metric map in ONE grouped query (4.5). `counts_between/3` is untouched. RA-7. |
| F12 | The shadow window start T0 ("latest audit entry of a transition into shadow with no later transition away") is not available from any function: stage 1 wrote `scope.enforcement_enabled` (off -> shadow) and after 2f `on -> shadow` is audited as `scope.enforcement_disabled` (AC 13: "any flip away from `on`"). | T0 = the latest entry of EITHER action for the tenant resource whose `after_state.mode` is `"shadow"`, read with one indexed query (index #3 of audit_entries: resource_type, resource_id, timestamp desc, id desc). If the latest such entry's after mode is not `shadow` or none exists, (a) fails closed. |
| F13 | SEC C-1 ("`on` not added until every `/me/*`, `/help/*` and any other tenant-level read is classified") — the route walk checked NOW: `@self_service_routes` (route_scope.ex 141 to 160) lists `GET /me/memberships` (`0051-A7`), `GET /me/modules` (`SEC-518-R2-modules`), `GET /help/resolved` (`SEC-518-R2-help`), all `:self_service`, none `:pending_sec_ruling`, none default-sourced; classified by #2817. The literal C-1 and AC 22 are therefore SATISFIED on main. The broader clause "any other tenant-level reads" is NOT closed by the walk: 115 default-sourced `:tenant_wide` routes remain, among them reads a scoped TASK_WORKER holds the coarse permission for (section 5). | Census in section 5. No reclassification in 519 (each would need its own SEC verdict, C-2, and the fail-closed 403 is safe). AC 22 is a test plus a PR-body statement. The wider gap is recorded as residual R-2 and follow-up RA-6. |
| F14 | `tasks.scope_node_id` has NO production writer (`TaskScopeFixture.set_scope_node!/3` is the only one; `scope_node_id_no_writer_scan_test.exs` pins it). Does 519 need one? No: AC 10 makes "scoped approver" a flip BLOCKER precisely because no writer exists, the out-of-scope paragraph assigns the writer to W3b, and AC 16 uses the test helper. | No writer in 519. After 519, `on` means a scoped worker sees zero tasks and a scoped approver cannot act (section 6). The scan test stays untouched. |
| F15 | The production allowlist for unmanaged scope declarations is `[]` (the key is set in config/test.exs 325 only, so the code default `[]` applies elsewhere; Catalog rule 11) and NO module manifest ships `:scope_declarations` (grep of `lib/` and `priv/`: only catalog.ex, manifest_hash.ex and module.ex name the key). So in production every entity type is `:undeclared` and a scoped caller gets NO entity data. | `on` is safe (fail closed) but the data path is empty for scoped users until a module declares scope. Section 6 states what must be true for `on` to be meaningful; it is documented, not gated (OQ-6). |
| F16 | AC 6 says the writer "sees `on` and refuses". For the NO-ROW writers the observable is "writes no row" and for REFUSED writers a 409; for the platform tenant and for a tenant whose registration is missing the mode cannot be resolved. | `ScopeEnforcement.mode_under_lock!/1` RAISES `ModeUnavailableError` in production for a failed read, a malformed prefix and a well-formed prefix with no `tenants` row (INV-8: a fail-open default on a flag read is forbidden). The lenient `:off` for the last two exists ONLY behind a test-only application key (r2, SEC C-1, see 3.2). |
| F17 | `retention` default 90 days (ShadowEvidence) must be >= `:scope_shadow_min_days` or no window can ever have a counter row for its oldest day; the gate would refuse forever without saying why. | Effective thresholds are validated; `min_days > retention_days` is a configuration failure that fails the (a)/(b) criteria closed and is named in the refusal body (4.5). |
| F18 | Two of the open issues touch files 519 edits: #2833 (router extraction out of `routers/entities.ex`) and #2834/#2809 (scope-set typing). 519 edits neither (no entity route changes class). #2800 (single source of the six reasons) is touched: the gate needs the blocking and reported subsets. | 519 reads the reasons through ONE accessor (4.5) and derives "reported" as "all six minus blocking", so it adds no new literal copy; if #2800 lands first the accessor delegates to `Scope.deny_reasons/0`. |

---

## 1. PR split and boundary

The requirement says TWO PRs (2e then 2f). Both are large, so this design proposes four sub-PRs (RA-5), the same
device 518 used (2c-i-a/2c-i-b). If RA-5 is rejected, the sub-PR boundaries are the commit order inside 2e and 2f.

| PR | Contents | ACs | Why this boundary |
|---|---|---|---|
| 2e-a | mode read under lock A, `reconcile_binding!` result type, mode-aware `ensure_tenant_wide_group_row!`/`repair_group_row!`/`move_group_rows!`, `BindingWriters` registry and scan, `scope_required` refusal and `binding.refused`, NO-ROW reporting for role_registry, TAM, Backfill, seeding; docs/roles.md remedy | 1, 5, 6, 7 (binding.refused), 21 | All behaviour that changes only inside an `on` tenant; no login path touched |
| 2e-b | IdP sync suppression (`grant.sync_suppressed`, `binding.pending_scope`), marker stamping rule, `scope_delta` on `group_member.*` | 2, 3, 4, 7 (rest), 21 | Touches the login path (`sync_role_claims_from_token/3`) and `Identity` audit payloads; independent of 2e-a except the shared mode read |
| 2f-a | The gate machinery as functions NOT yet reachable from `flip/4` or the route: `OnGate`, `ScopedApprovers`, `ShadowWindow`, `ShadowEvidence.counts_by_day/3`, `Audit.latest_matching/4`, `RefusedAudit`, integrity `on_gate` block, config keys; all tested by calling the modules directly | 9, 10, 11, 12, 14 (writer), 15 (refused), 18 (gate half), 21 | `on` is still unsettable after this PR; reviewers judge the gate in isolation. NOT dead code in intent: 2f-b wires it, the moduledoc says so |
| 2f-b | `parse_mode/1` accepts `on`, `flip/4` transition table, route authority (interactive tenant-wide TENANT_ADMIN), refusal HTTP mapping, success audit, the C-1 walk test, AC 16/17 end-to-end suite, docs, source scan | 8, 13, 14 (wiring), 15, 16, 17, 18 (route half), 19, 20, 21, 22 | The ONLY PR in stage 2 that lets a tenant turn enforcement on; its SEC verdict records the C-1 check (AC 22) |

Order: 2e-a, 2e-b (either order after 2e-a), 2f-a, 2f-b. 2f-a and 2f-b must come after 2e-a (the gate's integrity text and
the `on` writers are meaningless otherwise) and 2f-b after BOTH 2e PRs (AC 16 drives the writers). Every PR needs
SECURITY-REVIEWER (INV-1, 2, 4, 5, 6, 8, 10) and REVIEWER. Blast radius: 2e changes writer behaviour only in a tenant stored
`on`, which no tenant can reach before 2f-b.

PR checklist (AC 21, SEC C-2): each PR body lists every route whose class or snapshot line changed (519 changes NONE: the
table is empty and says so), quotes its OWN SECURITY-REVIEWER verdict id, and pastes the gate output of section 12.

PER-PR SEC VERDICT LIST (SEC C-2, step-04; ALL FOUR PRs are mandatory-SEC, a design verdict does not carry). Every PR body contains: (1) the SEC code verdict id and status for THAT PR; (2) a "routes changed: NONE" table citing that `test/fixtures/route_scope/tenant_wide_default_routes.txt` and `test/support/route_inventory.ex` are unchanged (git diff stat); (3) the section 12 gate output with real results; (4) the INV-1/2/4/5/7/8 statements the diff supports (rerun `grep -rn Repo.query` on the diff and the INV-4 grep pair). Extras: **2e-a** the writer registry table with each row's state and the T-C1 scan output; the S-1 statement (NO-ROW, `rows = skipped_enforced` audit key); proof that `binding_policy` occurs only in `role_registry.ex`; `mix letflow.check_role_scope_grants_writers` output; the statement that no tenant can reach `on` yet. **2e-b** the audit key sets of `grant.sync_suppressed`, `binding.pending_scope` and the `scope_delta` of `group_member.*`; the C-3 ordering (roles per group read after lock A); the statement that `sync_role_claims_from_token/3` still returns `User.t()`; the INV-4 grep result (no claim value added; the pre-existing warning that prints `claimed_roles` is not extended, A-6, dropping it is an optional drive-by). **2f-a** the statement that `on` is still unsettable and `parse_mode/1`, `@modes`, the transition clauses and the route are unchanged (a test pins it); the list of facts and read order; the field-by-field integrity body diff; the config defaults and the T-E9/T-E9b prod-config scan; no `Repo.query`. **2f-b** the C-1 route walk at the PR head (`@self_service_routes` three rulings, none pending, no `/me` or `/help` snapshot line); the behaviour-change list (4.10); existing tests changed and why; the AC 19 amendment link or pending status; the RA-6 follow-up id (filed BEFORE 2f-b merges); the open follow-up for the platform-scope flip route; the ON_IN_PRODUCTION text; confirmation that no 0050 D7 interim (c) is in force. 2f-b merges only after 2e-a, 2e-b and 2f-a are merged with their own SEC code verdicts.

## 2. Decision summary

| # | Decision |
|---|---|
| D-1 | The tenant's mode is read INSIDE the writer transaction, after `Identity.lock_tenant_admins!/1`, with a plain read of the public `tenants` row (no row lock). Lock A is the serialisation point with `flip/4` (which takes A first), exactly as AC 6 says. |
| D-2 | A binding-row writer cannot create a tenant-wide row in `on` BY CONSTRUCTION: the two low-level functions that insert one (`ensure_tenant_wide_group_row!/3`, `repair_group_row!/3`) check the mode themselves and return `{:skipped, :enforced}`; `reconcile_binding!/3` refuses `nil -> P` and `not P -> P` before reaching them. The explicit make-tenant-wide act uses `insert_tenant_wide/4`, a different function. AC 5 is then a structural property plus a property test. |
| D-3 | Every binding writer is a row of ONE registry, `Letflow.Identity.BindingWriters`; an AST scan of `lib/` fails when a call site of an entry point (the six named functions, `upsert_role`, `rebind_role`, `seed_default_platform_role_groups`, `Backfill.run`) is not registered. |
| D-4 | REFUSED writers roll back and then write `binding.refused` in their OWN transaction (the `TenantAdminGuard.refuse/4` pattern); the refusal is still returned if that audit write fails. |
| D-5 | The sync (cases 3) is decided by the no-widening principle (F4), in the same transaction and under the same lock A as the other sync writes. |
| D-6 | `flip/4` becomes a transition table (4.1). `off -> shadow` keeps `enable_checks!` unchanged; `shadow -> on` runs `OnGate`; `on -> shadow`, `on -> off`, `shadow -> off` run NO precondition; `off -> on` is `shadow_required`. |
| D-7 | The `on` gate reads, after lock A, the tenants row and the scope-tree lock S, in this order: T9, org consistency, tokens, explicit admins, scoped approvers, shadow evidence. All plain reads. Any raise refuses the flip with no flag change (INV-8). |
| D-8 | The evidence gate uses persisted counters only: one grouped query per window (`counts_by_day/3`), T0 from the audit chain, thresholds from application env only, a clock injectable ONLY through the internal `attrs[:now]` that the route never sets. |
| D-9 | Refused flips to `on` are audited in a separate transaction after the rollback (`scope.enforcement_refused`); a server fault (a raise) is a 500 and is NOT audited as a refusal. |
| D-10 | No route changes class in 519. C-1 is satisfied by the 518 `@self_service_routes` rulings; the wider tenant-level read gap is a documented residual and a follow-up requirement. |
| D-11 | No writer for `tasks.scope_node_id`; the scoped-approver blocker stays until W3b ships it. |

---

# PART A: PR 2e-a and 2e-b, enforced-tenant writers

## 3.1 Module map (2e)

| Module | Status | Purpose |
|---|---|---|
| `Letflow.ScopeEnforcement` | changed | + `mode_under_lock!/1` (reader for writers) |
| `Letflow.Identity.RoleScopeGrants` | changed | `reconcile_binding!/3` result type; mode-aware `ensure_tenant_wide_group_row!/3`, `repair_group_row!/3`, `move_group_rows!/4` |
| `Letflow.Identity.RoleScopeGrants.Backfill` | changed | per-tenant `skipped_enforced` |
| `Letflow.Identity.RoleRegistry` | changed | refusal rollback, `*_report` siblings, `converge_existing_role`/`insert_role`/`move_role` handle the new result |
| `Letflow.Identity.TenantAdminMigration` | changed | `skipped_enforced` per tenant |
| `Letflow.Identity.BindingWriters` | NEW | the writer registry (data only) |
| `Letflow.Identity.BindingRefusal` | NEW | writes `binding.refused` after a rollback (the `TenantAdminGuard.refuse` pattern) |
| `Letflow.Identity.MembershipScope` | NEW | per-user effective scope snapshot, delta, widening test (used by 2e-b) |
| `Letflow.Identity.SyncScopeGuard` | NEW | the sync decision and the two audit writers (2e-b) |
| `Letflow.Identity` | changed (2e-b) | `sync_role_claims_from_token/3` partitions candidate groups; `insert_membership_audit/6` gains `scope_delta` |
| `Letflow.Routers.Identity` | changed | 409 `scope_required`; `grant_rows` field when skipped |
| `docs/roles.md` | changed | remedy paragraph, known limitations |
| `lib/mix/tasks/letflow.backfill_role_scope_grants.ex` | changed | prints `skipped_enforced` |

No migration. No new table. No new route. No new permission. No new process.

## 3.2 The mode read (D-1, F16)

```
Letflow.ScopeEnforcement
  @spec mode_under_lock!(prefix :: String.t()) :: stored_mode()
```

Contract: runs inside a transaction (raises `ArgumentError` otherwise, the `lock_tenant_admins!/1` convention); derives
the tenant id with `TenantProvisioning.tenant_id_for_schema_name/1`; ONE plain read of `tenants.scope_enforcement` by
primary key, public schema, no `FOR` clause. Raises `Letflow.ScopeEnforcement.ModeUnavailableError` (no fields, constant
message) in PRODUCTION when (i) the read itself fails, (ii) the prefix is not a `tenant_<32 hex>` name, or (iii) a well-formed prefix has no `tenants` row. It never returns `:off` for any of them (r2, SEC C-1; this REPLACES the r1 softening S-1b, which SEC did not accept for production). The internal read distinguishes "no row" from "a row holding `off`". The lenient branch exists only for tests that call writers on schemas without a registration: it is taken ONLY when the application key `:scope_mode_lenient_for_tests` is `true`; the key is set in `config/test.exs` ONLY (never in `config.exs`, `prod.exs` or `runtime.exs`), is pinned like the 518 T-D8 key (a scan test asserts the string occurs in no `config/*.exs` except `test.exs`, and a `Config.Reader` evaluation of `config.exs`, `prod.exs`, `runtime.exs` with env `:prod` yields the key unset), and the lenient branch emits one constant log line `scope_mode_read_lenient` (no prefix, no id). ELIXIR-DEV first tries to drop the key: if no existing test needs the leniency (the writer tests in `role_scope_grants_writers_test.exs` use `TenantFixture.provisioned_tenant!`, which has a row; `role_registry_test.exs` and the simulation tests were not provable without running them), the key and its branch are not built. The caller
must already hold lock A; this is documented and tested (T-L1, held-lock test), not checked at runtime (an advisory-lock
ownership probe would itself change lock state).

### 3.2a A raised mode read (SEC C-2, INV-8)

A writer whose `mode_under_lock!/1` raises NEVER proceeds as `off`. The raise propagates out of the writer's transaction, which rolls back every write of that call: `upsert_role/4` and `rebind_role/4` already `rescue` around the transaction and return `{:error, {:transaction_failed, exception}}` (HTTP 500, detail-free); `sync_role_claims_from_token/3` already rescues around `Repo.transaction(multi)`, logs one constant line (exception module only) and returns the original user with the marker still nil (the next login retries); the membership writers do the same. Sweeps treat the raise as THAT tenant's error and never write for it: `Backfill.run/1` reports `{:backfill_failed, tenant_id, {:unexpected_exception, module}}` as today; `RoleBackfill.run/0` and `TenantAdminMigration` do the same through their existing rescue. The sweeps keep their halt-or-continue behaviour of today (the report names the failing tenant; nothing is hidden). Test T-L7 (above) covers a writer, the sync, seeding and a Backfill run by renaming the public `tenants` table inside the sandbox transaction; mutant MU-48.

Why a plain read is enough: `flip/4` takes A and then the tenants row `FOR UPDATE` and commits the new mode while holding
A. A writer takes A first, so after it acquires A the committed value is final for the writer's transaction (READ
COMMITTED; the repo sets no other isolation). The `tenants` row is therefore never locked by a writer: no new lock rank.

Cost: one primary-key read per binding write or sync (a rare, admin-rate path; the login path pays it only when
`group_ids != []`, after lock A is already taken).

## 3.3 `reconcile_binding!/3` and the low-level functions (AC 1, AC 5)

```
Letflow.Identity.RoleScopeGrants
  @type reconcile_result :: :ok | {:skipped, :enforced} | {:refused, :scope_required}
  @spec reconcile_binding!(before :: TenantRole.t() | nil, after :: TenantRole.t() | nil, prefix) :: reconcile_result()
  @spec ensure_tenant_wide_group_row!(group_id, role, prefix) :: :inserted | :exists | {:skipped, :enforced}
  @spec repair_group_row!(group_id, role, prefix) :: :inserted | :covered | {:skipped, :enforced}
  @spec move_group_rows!(role, from_group_id, to_group_id, prefix) :: {:moved, non_neg_integer()} | {:skipped, :enforced}
```

Behaviour by transition. P = `kind == :platform_role`. M = `mode_under_lock!(prefix)` read ONCE at the top of
`reconcile_binding!` and passed down privately (the three low-level functions also read it when called directly, so no
caller can bypass the check).

| Transition | `off` / `shadow` (unchanged) | `on` |
|---|---|---|
| `nil -> P` | `ensure_tenant_wide_group_row!` | `{:refused, :scope_required}`, nothing written by this module |
| `not P -> P` | `ensure_tenant_wide_group_row!` | `{:refused, :scope_required}` |
| `P -> P`, same group | `repair_group_row!` | `{:skipped, :enforced}` only if the binding has NO row; otherwise `:ok` (rows exist, nothing to do) |
| `P -> P`, other group | `move_group_rows!` | rows move: `:ok`; none moved: `{:skipped, :enforced}` (no repair fallback) |
| `P -> not P`, `P -> nil` | `remove_group_rows!` | `remove_group_rows!` (UNCHANGED: removal never widens) |
| anything else | `:ok` | `:ok` |

`move_group_rows!/4` previously returned a bare count; it now returns a tagged value so a caller cannot confuse "zero
moved, skipped" with "zero moved, repaired". Its only caller is `do_reconcile`. The stale-row clearing at the start
(`remove_group_rows!(to_group_id, ...)`) is kept as today.

In `off` and `shadow` every return is as today (`:ok`), so the stage-1 tests T-W1..T-W14 pass unedited (the new tagged
return of `move_group_rows!/4` is internal; `reconcile_binding!/3` still returns `:ok`).

Invariant (AC 5): in `on`, nothing under `lib/` except `insert_tenant_wide/4` (called only by `ScopedGrants.make_tenant_wide`)
inserts a `tenant_wide = true` row. `mix letflow.check_role_scope_grants_writers` already pins which files may write the
table; its moduledoc gains one sentence naming `insert_tenant_wide/4` as the only unconditional tenant-wide insert and the
mode check as the guard of the other two.

## 3.4 The writer registry and the completeness scan (AC 1)

`Letflow.Identity.BindingWriters` is data only (no DB, no side effects). r1 (CDV G3): the registry has two kinds of row. SCANNED rows are keyed by CALL SITE of the AC's six functions (`reconcile_binding!`, `ensure_tenant_wide_group_row!`, `repair_group_row!`, `move_group_rows!`, `delete_group_principal_rows!` and `RoleScopeGrants.Backfill.run`), the only ways a binding's grant row is written or removed, so completeness over them is completeness over every row writer. INDIRECT rows (W-g1, W-g2, W-h and the membership rows M-a..M-f) name an entry point that reaches a scanned site (`upsert_role`, `rebind_role`, seeding, `sync_role_claims_from_token`, the membership writers); they are NOT subject to the completeness scan. Their callers (tenant_onboarding.ex, role_backfill.ex, routers/identity.ex, auth_pipeline.ex, pending_admin_grants.ex, identity.ex membership code) are covered because each reaches a scanned site. A second test asserts that each indirect row's named function exists in its file (T-C2), so a rename cannot orphan a row. No new public function is added to `RoleScopeGrants` (`scope_grants_route_walk_test.exs` pins its exact exports): every new function of this design lives in `ScopeEnforcement`, `Identity`, `BindingWriters`, `BindingRefusal`, `MembershipScope`, `SyncScopeGuard`, `RoleRegistry` or `Backfill`; the existing exports only change return types.

```
@type state :: :refused | :no_row | :unchanged
@type transition :: :nil_to_p | :not_p_to_p | :p_to_p_same | :p_to_p_other | :p_to_not_p | :p_to_nil
@type site :: %{file: String.t(), function: {atom(), arity()}, index: non_neg_integer()}   # index = nth entry-point call in that function, source order
@type row :: %{id: atom(), site: site(), transition: transition(), state: state(), why: String.t(), audit: atom() | nil}
@spec binding_rows() :: [row()]
@spec membership_rows() :: [%{id: atom(), site: site(), state: :delta_audited | :suppressed_in_on | :unchanged, why: String.t()}]
@spec entry_points() :: [{module(), atom()}]     # the names the scan looks for
```

Binding rows (every row has one test per mode `off`, `shadow`, `on`; in `off` and `shadow` the result is today's):

| Id | Site (function, call) | Transition | State in `on` | Notes |
|---|---|---|---|---|
| W-a | `RoleRegistry.insert_role/5` #0 (role_registry.ex ~534) | `nil_to_p` | REFUSED 409 `scope_required`, `binding.refused` | AC 1 (a) |
| W-b | `RoleRegistry.converge_existing_role/5` #1 (~576) | `not_p_to_p` | REFUSED, same | AC 1 (b), includes re-creation after platform -> routing |
| W-b2 | same site | `p_to_not_p` | UNCHANGED (removal) | asserted: the N1 guard still runs |
| W-c1 | `RoleRegistry.converge_existing_role/5` #0 (~565) | `p_to_p_same` | NO-ROW when the binding has no row | AC 1 (c); returns `{:skipped, :enforced}` through `*_report` |
| W-c2 | `RoleRegistry.ensure_platform_role_binding/2` #0 (~304) | `p_to_p_same` | NO-ROW | AC 1 (c) seeding repair |
| W-c3 | `TenantAdminMigration.ensure_binding/2` #0 (~349) | `p_to_p_same` | NO-ROW | AC 1 (c) |
| W-d1 | `RoleRegistry.move_role/6` (~789) | `p_to_p_other`, rows move | UNCHANGED (scoped rows follow the binding) | AC 1 (d), asserted |
| W-d2 | same | `p_to_p_other`, zero rows move | NO-ROW | AC 1 (d); no repair fallback |
| W-e | `Backfill.repair_tenant/2` (`repair_group_row!`) | repair | NO-ROW per tenant, `skipped_enforced` | AC 1 (e); the scanned site is `backfill.ex` ~193 (`repair_group_row!`); `Backfill.run/1` has ONE scanned caller, the mix task (`letflow.backfill_role_scope_grants.ex` ~42), registered as row W-e2 (`Backfill.run`, UNCHANGED call, reports `skipped_enforced_tenants`) |
| W-f1 | `TenantAdminMigration.remove_legacy_binding/2` (~398) | `p_to_nil` | UNCHANGED | removal never widens |
| W-f2 | `Identity.delete_group/2` (`delete_group_principal_rows!`) | n/a | UNCHANGED | removal never widens |
| W-g1 (NEW, RA-1) | `RoleRegistry.ensure_platform_role_binding/2` nil branch (calls `upsert_role/4`) | `nil_to_p` | NO-ROW (see 3.6, S-1) | F2 |
| W-g2 (NEW, RA-1) | `TenantAdminMigration.ensure_binding/2` nil branch (calls `upsert_role/4`) | `nil_to_p` | tenant skipped `skipped_enforced` (see 3.6, S-1) | F2 |
| W-h | `Routers.Identity.upsert_role/5` HTTP | `nil_to_p`, `not_p_to_p` | = W-a, W-b | route mapping 3.9 |

Membership rows (decided by AC 2 to 4, listed so they are classified, not silent):

| Id | Site | State | Reason asserted by a test |
|---|---|---|---|
| M-a | `Identity.add_group_member/3` | `:delta_audited` | writes no row; the group's rows decide; AC 4 audit |
| M-b | `Identity.remove_group_member/3` | `:delta_audited` | removal never widens; AC 4 audit |
| M-c | `Identity.sync_role_claims_from_token/3` | `:suppressed_in_on` | AC 2 and 3 |
| M-d | `PendingAdminGrants.bind_on_login/5` | `:unchanged` | the 0048 explicit audited tenant-wide admin act joins the TENANT_ADMIN group |
| M-e | `Identity.delete_group/2` membership side | `:unchanged` | memberless group only |
| M-f | `TenantAdminMigration.copy_members/3` | `:unchanged` (unreachable in `on`: the tenant is skipped, 3.6) | bulk membership copy; its test calls it directly in `on` and asserts it is reached only through the guarded `real_tenant` |

Completeness scan (test `binding_writers_scan_test.exs`, NOT a mix task): parse every `lib/**/*.ex` with
`Code.string_to_quoted/2`, resolve aliases of `RoleScopeGrants`, `RoleScopeGrants.Backfill`, `RoleRegistry`, find every
call of the SIX scanned functions (`reconcile_binding!`, `ensure_tenant_wide_group_row!`, `repair_group_row!`, `move_group_rows!`,
`delete_group_principal_rows!`, `Backfill.run`; nothing else), record `{file, enclosing def,
nth call}`, EXCLUDING calls inside `lib/letflow/identity/role_scope_grants.ex` itself (internal dispatch) and
`BindingWriters` itself. The set must equal the SCANNED rows' site set (on main: role_registry.ex 304/534/565/576/789, tenant_admin_migration.ex 349/398, identity.ex 1026, backfill.ex 193, plus the `Backfill.run` caller in the mix task). The scanner is proven live on a seeded source holding a
new unregistered call (mutant MU-1). Doc text and comments are not in the AST. This follows the AST approach of
`scope_node_id_no_writer_scan_test.exs`, which already handles aliases, `@doc` skipping and enclosing-def labels.

## 3.5 Surfacing NO-ROW and REFUSED (AC 1)

Every NO-ROW is reported three ways: (i) an explicit result, (ii) ONE constant log line
`binding_row_skipped reason=enforced writer=<registry id>` (no ids, no names, INV-4), (iii) the T9 query and the integrity
endpoint already show the zero-row binding (`bindings_without_row`).

| Writer | Explicit result (public shapes unchanged) |
|---|---|
| `RoleRegistry.upsert_role/4` | unchanged `{:ok, role}` and the log line; NEW `upsert_role_report/4 :: {:ok, TenantRole.t(), rows :: :written \| :covered \| :skipped_enforced} \| {:error, upsert_error()}`; the HTTP route uses it |
| `RoleRegistry.rebind_role/4` | same pattern: `rebind_role_report/4 :: {:ok, TenantRole.t(), rows :: :moved \| :skipped_enforced}`; route adds the field |
| `RoleRegistry.seed_default_platform_role_groups/1` | unchanged; NEW `seed_default_platform_role_groups_report/1 :: {:ok, %{roles: [TenantRole.t()], skipped_enforced: [String.t()]}} \| {:error, term()}`; `RoleBackfill.run/0` uses it and adds the additive key `skipped_enforced` to its result |
| `TenantAdminMigration` per-tenant report | gains `rows: :written \| :skipped_enforced` (additive key) |
| `RoleScopeGrants.Backfill` tenant report | gains `skipped_enforced: boolean()` and, for a skipped tenant, `group_rows_inserted: 0`; the mix task prints `skipped_enforced` per tenant |

HTTP: `POST /roles` and `POST /roles/:id/rebind` add the response key `"grant_rows": "skipped_enforced"` ONLY when the
result is skipped (in every other case the body is byte-identical to today). `role_map/1` is unchanged.

REFUSED: `reconcile_binding!/3` returns `{:refused, :scope_required}`; the registry code turns that into
`Repo.rollback({:binding_refused, %{case: :nil_to_platform | :routing_to_platform, role: name, group_id: id}})`. After the
transaction returns, `BindingRefusal.refuse/3` runs OUTSIDE any transaction:

```
Letflow.Identity.BindingRefusal
  @spec refuse(prefix :: String.t(), refusal :: %{case: atom(), role: String.t(), group_id: Ecto.UUID.t()}, AuditContext.t()) ::
          {:error, :scope_required}
```

It writes ONE `binding.refused` entry in its own transaction: `actor_id` = the audit context actor, `resource_type`
`"tenant_role"`, `resource_id` = the role name (the binding row does not exist), `before_state` nil, `after_state` exactly
`{actor, role, group, case, trace_id}` (id and fixed-string values only, key-set asserted), `trace_id` from the context. A
raise or a failed audit write logs one constant line `binding_refusal_not_recorded reason=<audit_failed|exception>` and the
refusal is STILL returned (the `TenantAdminGuard.refuse/4` precedent); inside an open transaction it writes nothing and logs
`binding_refusal_not_recorded reason=inside_transaction`. Nested callers (seeding, TAM) never reach it (3.6).

## 3.6 Nested writers: seeding and TAM (F2, RA-1, S-1)

`ensure_platform_role_binding/2` nil branch creates the group named after the role and calls `upsert_role/4`. In `on`
that nested call would be W-a (REFUSED), rolling back the seeding transaction and halting the sweep. Decision: the nested
call passes the INTERNAL option `binding_policy: :no_row_when_enforced` (an `opts` key that `Routers.Identity` never
passes; a scan test asserts the string appears only in `role_registry.ex`). With it, the `nil -> P` branch of
`insert_role/5`, in `on`, inserts the binding WITHOUT calling the row writers and reports `:skipped_enforced`. The normal `role_binding.created` audit entry of that write is KEPT (SEC S-1 (b)) and its payload gains the FIXED key `rows` = `"skipped_enforced"`, so the trail shows the binding was created without a row; the key is absent in every other mode. A seeded NO-ROW binding makes T9 positive, so the next flip to `on` is refused until an admin grants scope (test T-N3 asserts this chain: seed in `on`, T9 > 0, `shadow -> on` refused `bindings_without_row`). Fail-closed
analysis (S-1): the seeded group is the group NAMED after the role; if it pre-exists with members, those members now hold
the role through the coarse check but `allowed?/3` answers `{:deny, :no_grant_rows}` (404-equivalent on data routes, 403 on
the route plane) until an admin grants scope; before the binding they held nothing. No widening, T9 becomes positive and is
reported. REFUSING instead is the alternative the SEC ruling may prefer; the cost is the halted sweep (mitigation: make the
sweep per-tenant tolerant, a separate change).

`TenantAdminMigration.real_tenant/4` reads the mode right after `lock_tenant_admins!` and, in `on`, returns
`{:ok, %{tenant_id, slug, idp_realm_id, rows: :skipped_enforced, ...zero counts}}` without planning: it is a one-shot
legacy migration (REQ-447) that copies PLATFORM_ADMIN members into the TENANT_ADMIN group; in an enforced tenant a bulk
membership copy is an unreviewed grant of the group's scope. W-c3 stays registered (it is unreachable in `on` through
`real_tenant` but is the row a direct caller of `ensure_binding/2` would hit; its test calls it directly). r1: skipping an `on` tenant skips the WHOLE `real_tenant` plan, so it ALSO skips the legacy PLATFORM_ADMIN binding removal (W-f1) and the token rewrite (`token.roles_migrated`) for that tenant. Both are one-shot legacy cleanups of a migration that completed for every tenant before `on` was reachable; a tenant that is `on` and still carries a legacy binding is reported (`rows: :skipped_enforced`) for manual handling. Folded into SEC ruling S-1.

## 3.6a Backfill in an enforced tenant (CDV G2)

`RoleScopeGrants.Backfill.repair_tenant/2` rolls back with `:gap_remains` when T9 is still positive after its repairs, and `Backfill.run/1` halts the sweep on the first tenant error. In `on` the NO-ROW rule leaves the gap by design, so r1 defines:

* Under lock A the tenant's mode is read (`mode_under_lock!/1`). In `on`: NO repair is attempted, the gap check is SKIPPED (not an error), NO `scope.backfill_completed` audit entry is written (it writes nothing, the stage-1 rule "a re-run that inserts nothing writes nothing"), and the tenant report is `%{tenant_id, platform_role_bindings, group_rows_inserted: 0, skipped_enforced: true, bindings_without_row_after: n}` with `n` the current T9 count (the type of `bindings_without_row_after` widens from the literal `0` to `non_neg_integer()`).
* `off` and `shadow`: unchanged, including `:gap_remains` and the audit entry.
* Dry run: the report gains `skipped_enforced: boolean()` (mode read with `ScopeEnforcement.get_mode/1` on the tenant id derived from the schema name, because `mode_under_lock!/1` raises outside a transaction; a snapshot; an unreadable or absent mode reports `false` and never errors a dry run) beside `bindings_without_row_before`; it never returns `{:error, _}`, as today.
* The sweep continues past an `on` tenant; `Backfill.run/1` adds `skipped_enforced_tenants: [tenant_id]` and the mix task prints it. `inserted_total` is unaffected.
* Tests T-N5a (real run in `on`: no error, no audit entry, no row inserted, T9 unchanged, report flags), T-N5b (dry run flags it), T-N5c (a sweep over an `on` tenant followed by an `off` tenant repairs the second); mutants MU-43 and MU-44.

## 3.7 Lock order (AC 6)

No new lock. Ranks of REQ-517 3.5 apply: **A** < R < G < N < B < T < S < C. Every writer takes A first, then (as today)
R, G, the role row, then B rows and C last. The mode read is a plain read after A. `flip/4` takes A, T, S, C. So:
a writer that acquires A before the flip commits its binding and its row (or its refusal) against the old mode, and the
flip then sees them (T9 counts the binding); a writer that acquires A after the flip commits sees `on`. Test T-L2/T-L3
(held lock A, writer first / flip first). The refusal audit (D-4) and the T0 audit read take no lock beyond the audit
chain tail lock of `Audit.insert_entry`, which is rank C and last.

## 3.8 Membership audit: the effective-scope delta (AC 4)

```
Letflow.Identity.MembershipScope
  @type scope :: :deny | :tenant_wide | {:nodes, [String.t()]}
  @type snapshot :: %{role :: String.t() => scope()}
  @type delta_entry :: %{String.t() => String.t() | map()}      # "role", "from", "to"
  @spec snapshot(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: snapshot()
  @spec delta(before :: snapshot(), after :: snapshot()) :: [delta_entry()]
  @spec would_widen?(before_scope :: scope(), after_scope :: scope()) :: boolean()
  @spec render(scope()) :: String.t() | map()
```

`snapshot/2` = for each role in `Identity.list_effective_role_names/2` (the roles held through groups, same coarse
rule as the principal), the effective scope computed with the pure function of `Api.Scope` over
`RoleScopeGrants.applicable_rows_for_user/2` (one query); `Api.Scope` gains one PUBLIC pure function
`effective_from_rows(rows :: [map()]) :: :deny | :tenant_wide | {:nodes, [String.t()]}` extracted from the private
`rows_scope/1` (no behaviour change; `effective_scope/2` calls it). `delta/2` lists only roles whose scope changed.
`render/1`: `"deny"`, `"tenant_wide"`, or `%{"nodes" => [ids, sorted, at most 50], "count" => n}` (ids are org-unit record
ids, no PII; 0051 D8 payload rule; AuditRead holders already see ids in grant entries).

`Identity.insert_membership_audit/6` adds `"scope_delta" => [delta_entry]` to `after_state` of BOTH `group_member.added`
and `group_member.removed`, in EVERY mode (AC 4), computed from a `snapshot` taken before the write (the existing
`before_roles` read site) and one after (the existing `after_roles` read site), inside the same transaction. Existing
keys (`roles_gained`, `roles_lost`, `group_roles`, `member`, ...) are unchanged; existing GH 2547 tests pass unedited. Cost:
2 extra queries per membership change (admin-rate).

## 3.9 IdP sync suppression (AC 2, 3; 2e-b)

In `sync_role_claims_from_token/3`, in the `:memberships` step, AFTER lock A and the lock_timeout (unchanged order):

1. `mode = mode_under_lock!(prefix)`. If not `:on`, the current code runs unchanged (AC 2 shadow test: legacy membership added).
2. (SEC C-3) The platform roles each candidate group binds are read AFTER lock A, INSIDE this step: one query over `tenant_roles` with `kind = platform_role` and `group_id IN (candidate ids)` (bound values). They are NOT carried from the pre-lock result of `resolve_group_ids_for_role_names/2`, which keeps returning group ids only (its signature and the public signature of `sync_role_claims_from_token/3` are unchanged). A concurrent `rebind_role` or `upsert_role` that moved a binding between the resolve and the lock therefore cannot make the suppression decision stale: lock A serialises the binding writers, so the read after A is final. `:process_routing_role` bindings are IGNORED by the decision: `would_widen?/2` and the role query consider `:platform_role` only, so a routing-role-only group never widens and its membership is inserted as today.
3. For each candidate group G the user is not already a member of: `before = MembershipScope.snapshot(user)`, `after` =
   the snapshot as if G were added (computed in memory: add G's applicable group rows for the roles G binds to the user's
   rows; no write). For each role R bound to G where `would_widen?(before[R], after[R])` is true (after is `:tenant_wide`
   and before is not), G is SUPPRESSED for that role; if no role widens, the membership is inserted as today.
   (A group with a mix: suppressed entirely if ANY bound role widens, because a membership cannot be split by role.)
4. Per suppressed (G, R): if `before[R]` is `{:nodes, _}` the entry is `grant.sync_suppressed` (user already holds scoped
   rows for R), else (`:deny`) it is `binding.pending_scope`.

Audit shapes (key-set asserted; no IdP claim value, INV-4):

| Action | resource_type / resource_id | `after_state` keys (exactly) |
|---|---|---|
| `grant.sync_suppressed` | `"user_role"` / `"<user_id>:<role>"` | `user`, `group`, `role`, `trace_id` |
| `binding.pending_scope` | `"user_role"` / `"<user_id>:<role>"` | `user`, `group`, `role`, `trace_id` |

Both are written inside the same transaction as the sync's other writes (the `Multi`), actor = the user, source
`"idp_sync"`. A failed audit write fails the step (the whole sync rolls back and the marker stays nil, as for
`group_member.added`).

Dedup (AC 3): ONE event per (user, role), derived from stored data: before writing a `binding.pending_scope` (and a
`grant.sync_suppressed`) the step runs `Audit.latest_matching(prefix, "user_role", "<user_id>:<role>", [action])`; if an
entry exists, no new entry. Survives a restart (data, not memory); three syncs yield one entry; a second role yields a second
entry. Residual: after an admin resolves the situation and it recurs, the first entry is the only one (R-4).

Marker (F5, S-2): when `group_ids != []` and every candidate was suppressed (and recorded or deduped), the marker is
STILL stamped (`role_claims_synced_at`), so the sync does not rerun at every login. When at least one membership is written
the marker is stamped as today. When there were no candidates at all, unchanged (marker nil, retried; ISS-0773).

### 3.9a The typed suppressed result (AC 2, CDV G1)

AC 2 requires the suppressed sync to return "a typed suppressed result", but `Identity.sync_role_claims_from_token/3` returns `User.t()` and its callers (auth pipeline, `upsert_by_external_identity/4`, `re_select_on_conflict/3`) depend on that. Decision: the existing export keeps its contract unchanged (it delegates and discards the extra information); a NEW sibling in `Letflow.Identity` (NOT in `RoleScopeGrants`, whose exports are pinned):

```
@type suppressed_item :: %{group_id: Ecto.UUID.t(), role: String.t(), kind: :sync_suppressed | :pending_scope}
@type suppressed_summary :: %{suppressed: [suppressed_item(), ...], deduped: non_neg_integer()}
@spec sync_role_claims_report(User.t(), IdentityContext.t(), opts()) ::
        {:ok, User.t()} | {:suppressed, User.t(), suppressed_summary()}
```

`{:ok, user}` is returned when nothing was suppressed (as today, including the failure fallback that returns the original user). `{:suppressed, user, summary}` is returned when at least one (group, role) was suppressed in this call, whether or not other memberships were written and whether or not the audit entry was new (`deduped` counts the pairs whose entry already existed). The `User` is the one the existing function would return. Items carry ids and the fixed kind only (no claim value, INV-4). `sync_role_claims_from_token/3` becomes a thin wrapper that returns the user of either tuple; the pipeline stays unchanged, and the pipeline MAY log one constant line `role_claims_sync_suppressed count=<n>` from the sibling. Tests T-S13 (existing export returns `User.t()` in every mode, byte-for-byte as before), T-S14 (the sibling returns `{:suppressed, ...}` exactly for the T-S1/T-S6 cases and `{:ok, _}` otherwise; items hold no claim value). Mutants MU-45, MU-46.

Post-conditions (tests): no membership row for a suppressed group; `list_effective_role_names/2` omits the role; the
coarse check answers the existing 403 and `Scope.allowed?/3` returns `{:deny, :role_not_held}` (not `:no_grant_rows`);
after an admin `POST /groups/:id/members` into a group with scoped rows the user holds exactly that scope.

## 3.10 HTTP mapping (2e-a)

| Route | New outcome |
|---|---|
| `POST /roles` | `{:error, :scope_required}` -> 409, detail `scope_required`, extension `remedy` = fixed string ("create the binding before enabling enforcement, or set enforcement to off with a reason, create it, narrow its scope, and enable again"); `grant_rows` key when skipped |
| `POST /roles/:id/rebind` | `grant_rows` key when skipped; no new error |
| `POST /groups/:id/members`, `DELETE ...` | unchanged status codes; audit payload gains `scope_delta` |

`Response.conflict/2` takes a detail string only, so the extension is added with the same struct-update idiom the flip route
already uses (`%{Error.conflict(...) | extensions: ...}`).

## 3.11 Docs (2e-a)

`docs/roles.md` gains a section "Creating role bindings while scope enforcement is on": the 409 `scope_required`, the
remedy (create-before-flip, or flip down with a reason, create, narrow with REQ-517 AC 6/7, flip up through the gate),
the NO-ROW cases and how to see them (integrity endpoint, T9), the seeding NO-ROW case. No new column in the permission
matrix (no permission changes), so the parity test is untouched.

---

# PART B: PR 2f-a and 2f-b, the flag `on` (settable last)

## 4.1 `flip/4`: transition table (D-6)

```
Letflow.ScopeEnforcement
  @type mode :: :off | :shadow | :on                      # settable modes (was :off | :shadow)
  @spec modes() :: [mode()]                               # [:off, :shadow, :on]
  @spec parse_mode(term()) :: {:ok, mode()} | {:error, :invalid_mode}     # exactly "off" | "shadow" | "on"
  @spec flip(tenant_id, prefix, target :: mode(), attrs :: %{actor_id: Ecto.UUID.t() | nil, reason: term(),
                                                              trace_id: String.t() | nil, optional(:now) => DateTime.t()}) ::
          {:ok, %{mode: mode(), previous: mode(), changed: boolean()}} | {:error, flip_error()}
  @type flip_error ::   (existing members, plus)
          :shadow_required
        | {:on_precondition_failed, [on_precondition()], on_gate_report()}
  @type on_precondition :: :bindings_without_row | :org_inconsistent | :tokens_exceed_owner
                         | :zero_tenant_wide_admins | :scoped_approvers_without_task_scope | :shadow_evidence_insufficient
```

2f-a adds everything except the parse/transition change; 2f-b flips `parse_mode/1`, `@modes` and the transition clauses.
`stored_modes/0` stays (`[:off, :shadow, :on]`); `modes/0` becomes equal to it after 2f-b (the stage-1 distinction is kept in
the code as a comment, not as two lists, to avoid drift: `stored_modes/0` delegates to `modes/0`).

Inside the one transaction (order fixed): lock A -> tenants row `FOR UPDATE` -> `previous`:

| previous -> target | Action | Audit | Preconditions |
|---|---|---|---|
| same mode | `changed: false`, no write | none | none (and the on -> shadow reason rule is not reached) |
| `off -> shadow` | `enable_checks!` UNCHANGED (S lock, three facts) | `scope.enforcement_enabled` | the three stage-1 facts, error shape `{:precondition_failed, ...}` UNCHANGED |
| `shadow -> on` | `on_checks!` (S lock, six facts, 4.4) | `scope.enforcement_enabled` | the ON gate |
| `off -> on` | refuse | `scope.enforcement_refused` (own transaction) | `shadow_required`, nothing else evaluated |
| `on -> shadow` | reason mandatory in-transaction (F10), else `reason_required` | `scope.enforcement_disabled` | NONE (must succeed with a failing fact seeded, AC 13) |
| `on -> off`, `shadow -> off` | reason mandatory (pre-transaction, stage 1) | `scope.enforcement_disabled` | NONE |

Audit action rule (replaces `target == :shadow`): rank off < shadow < on; `enabled` when rank(target) > rank(previous), else
`disabled`. This reproduces stage 1 (off -> shadow enabled, shadow -> off disabled) and AC 13 (shadow -> on enabled; on ->
shadow and on -> off disabled).

`flip_entry/6` gains, for `shadow -> on`, `after_state["preconditions"]` = the six counts and `after_state["evidence"]` =
the evidence summary of 4.5 (counts and booleans only), plus `reason` when given. The update and the entry commit together;
a forced audit failure rolls the flip back (`{:audit_failed, _}`, test).

Before the transaction, for `target == :on` only: `ShadowEvidence.flush/0` is called best-effort (result ignored, never
raises): the persisted counts then include requests of the last flush interval, so "requests > 0 today" is not defeated by
a 30 second flush lag. A failed flush can only make the gate stricter. It is outside the transaction so it never extends
lock hold time.

## 4.2 The route: authority and responses (AC 8, 14)

`Routers.TenantScopeEnforcement`:

* `GET /`, `/integrity`, `/token-preconditions` keep `with_tenant_wide` (tokens allowed; AC 8 "GET routes unchanged").
* `PUT /` uses a NEW `with_interactive_tenant_admin/2`, whose checks live in `Letflow.Api.Scope` as the hoisted
  `require_interactive_tenant_admin(conn) :: {:ok, conn} | {:error, conn, :forbidden}` (credential `:oidc`, then
  `require_tenant_wide(conn, :UsersGroupsRolesManage)`, then `:TENANT_ADMIN in principal.roles` and
  `effective_scope(principal, "TENANT_ADMIN") == :tenant_wide`). `Routers.Identity.handle_service_principal/2` is changed to
  call the same function (its private `require_oidc/1` and `require_tenant_admin_tenant_wide/1` are deleted), so the two
  admin gates cannot diverge. Every refusal is the unchanged uniform `403 insufficient permissions` (a scoped admin, a
  non-admin, an API token holding TENANT_ADMIN, a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN).
* Response mapping (new rows marked NEW):

| Result | Status / code | Body extras |
|---|---|---|
| `{:error, :invalid_mode}` | 422 `invalid_enforcement_mode` | none |
| `:reason_required`, `:invalid_reason` | 422 | none |
| NEW `:shadow_required` | 409 `shadow_required` | `current_mode` |
| `{:precondition_failed, ...}` (off -> shadow) | 409 `enforcement_precondition_failed` UNCHANGED | `failed`, `report` (three counts) |
| NEW `{:on_precondition_failed, failed, report}` | 409 `enforcement_precondition_failed` | `failed` (codes), `report` (counts incl. `explicit_tenant_wide_admins`, `scoped_approvers`, `scoped_task_workers_without_task_scope`), `evidence` when evaluated: window, counts of ALL SIX reasons, requests, per-criterion booleans, `evidence_scope` |
| `{:audit_failed, _}`, `{:transaction_failed, _}`, other | 500, detail-free, NO flag change; ONE constant log line `scope_enforcement_flip_failed reason=<tag> exception=<module\|none>` (reason tag and exception module only, no ids, no values; the stage-1 `flip_response` dropped the exception silently) | none |

`GET /` returns `available_modes` = `["off","shadow","on"]` after 2f-b. Bodies are built field by field (INV-2); no ids, no
names, no token data, no group or user information.

## 4.2a Platform tenant under `on` (SEC C-6, INV-10)

Grants never decide PLATFORM_ADMIN or platform-scope access (0051 D1 clarification, INV-10). Two tests in `scope_enforcement_on_e2e_test.exs` (or the router test file): T-O7 the PLATFORM tenant stored `on` does NOT lock its PLATFORM_ADMIN out of the platform-scope routes (`/tenants*`, `/onboarding*`, `/platform-migrations*`, `/event-retention*`; `Scope.allowed?/3` answers `{:allow, :platform}` for a platform-scope permission regardless of grant rows) and the flag route `PUT /tenant/scope-enforcement` stays TENANT_ADMIN-only there (a PLATFORM_ADMIN without TENANT_ADMIN gets the uniform 403); T-O8 in a NON-platform tenant stored `on`, a `PLATFORM_ADMIN` role claim stays inert (`effective_roles` drops it). docs/roles.md gains the sentence "A platform tenant stored as on does not restrict its PLATFORM_ADMIN on platform-scope routes; grants never decide platform scope."

## 4.3 Refused flips: the audit (AC 14; D-9)

```
Letflow.ScopeEnforcement.RefusedAudit
  @spec record(tenant_id, prefix, previous :: mode(), failed :: [atom()], detail :: map(), attrs) :: :ok
```

Called by `flip/4` AFTER `Repo.transaction` returned `{:error, {:on_precondition_failed, ...}}` or `{:error, :shadow_required}`
(outside any transaction; inside one it writes nothing and logs a constant line). ONE `scope.enforcement_refused` entry,
`resource_type "tenant"`, `resource_id` tenant id, actor and trace from `attrs`, `before_state %{"mode" => previous}`,
`after_state %{"target" => "on", "failed" => [codes], "preconditions" => counts, "evidence" => six-reason counts + requests
+ criteria + "evidence_scope"}` (AC 14). No flag change. Best-effort like `TenantAdminGuard.refuse/4`: a failed write logs
`scope_enforcement_refusal_not_recorded` and the 409 is still returned (S-6). Guard test (SEC A-5): in a test sandbox `Repo.in_transaction?/0` is always true, so the inside-transaction guard of `RefusedAudit` and of `BindingRefusal` is tested the way the `TenantAdminGuard.refuse/4` precedent does (tenant_admin_guard_test.exs, which runs on committed, non-sandboxed state and `refute Repo.in_transaction?()` before calling, plus one case that calls the function inside an explicit `Repo.transaction`); T-R3, T-F1 use that setup or they will not see the entry. A refusal that is a SERVER FAULT (a precondition
read raised) is a 500 and is NOT recorded as a refusal (the facts are unknown). Refused `off -> shadow` stays unaudited
(AC 14, as stage 1). `shadow_required` is audited (it is a refused flip to `on`) with `failed ["shadow_required"]` and no counts.

## 4.4 The ON gate (AC 9, 10; 2f-a)

```
Letflow.ScopeEnforcement.OnGate
  @type report :: %{bindings_without_row: non_neg_integer(), org_consistency: :ok | :inconsistent | :unavailable,
                    tokens_exceeding_owner: non_neg_integer(), explicit_tenant_wide_admins: non_neg_integer(),
                    scoped_approvers: non_neg_integer(), scoped_task_workers_without_task_scope: non_neg_integer(),
                    evidence: ShadowWindow.report()}
  @spec evaluate(tenant_id, prefix, now :: DateTime.t()) :: {report(), failed :: [on_precondition()]}
```

Called inside `flip/4` after the S lock (`ScopeNodePaths.lock!/1`), in this read order, all plain reads:

| # | Fact | Source (as built) | Fails when | Code |
|---|---|---|---|---|
| 1 | T9 | `RoleScopeGrants.bindings_without_row_count/1` (includes a group left with zero rows by REQ-517 AC 7) | > 0 | `bindings_without_row` |
| 2 | org consistency | `ScopeNodePaths.Consistency.check/1` | status not `:ok` or error | `org_inconsistent` |
| 3 | tokens | `TokenPreconditions.exceeding_owner_count/1` (flagged owners still count: AC 9 explicit test) | > 0 | `tokens_exceed_owner` |
| 4 | explicit INTERACTIVE admins (SEC C-4) | NEW `Identity.count_interactive_explicit_tenant_wide_admins/1`: the group-or-user-sourced half of `count_explicit_tenant_wide_admins/1` (a `tenant_wide = true` TENANT_ADMIN row for the user or the bound group), over ACTIVE users whose `admin_flagged_service_principal` is false; it does NOT count live TENANT_ADMIN token owners and does NOT count a flagged service principal | = 0 | `zero_tenant_wide_admins` |
| 5 | scoped approvers | `ScopedApprovers.count/1` (4.5) | > 0 | `scoped_approvers_without_task_scope` |
| 6 | shadow evidence | `ShadowWindow.evaluate/4` (4.6) | any criterion false | `shadow_evidence_insufficient` |

ALL six are evaluated every time so the refusal names every failure (AC 9 "refuses with EVERY failing one"). A raise anywhere
propagates out of the transaction (rolled back, no flag change, `{:transaction_failed, exception}` -> 500; INV-8; test T-G9
renames the table each fact reads inside the sandbox transaction, no lib hook). The fact records are counts and enums; the
refusal discloses no ids.

Why the variant (C-4, OQ-5): the PUT is interactive-only (AC 8), so a tenant reaching `on` with no interactive explicit tenant-wide TENANT_ADMIN could not be turned off through the API (no platform break-glass in this release). `count_explicit_tenant_wide_admins/1` (517) counts token owners and flagged principals for the guards of 517; the gate uses the stricter interactive variant, a read added next to it in `Identity` (no change to the existing function). Tests, added to T-G4: (i) a tenant whose only explicit admin is a flagged service principal is refused `zero_tenant_wide_admins`; (ii) a tenant whose only TENANT_ADMIN is a live token owner is refused; (iii) one human explicit admin plus a flagged service principal passes; (iv) an inactive human admin does not count. Mutant MU-51. The integrity `on_gate.blocking` uses the same count. OQ-5 default changes accordingly.

Integrity endpoint (AC 9 last sentence): `ScopeEnforcement.integrity/1` keeps its map and its `findings` array of strings (the
stage-1 informational `zero_tenant_wide_admins` on the OLD count, so off -> shadow's gate is unchanged); it gains the key
`on_gate :: %{blocking: [on_precondition()], information: %{scoped_task_workers_without_task_scope: n}, counts: %{...}}`
computed by `OnGate.evaluate/3` WITHOUT locks (a snapshot, labelled so). In `on_gate.blocking`, `zero_tenant_wide_admins`
is computed from the EXPLICIT count. The two spellings of the same code on the same endpoint are documented in the
moduledoc and docs/roles.md ("`findings` is the stage-1 informational list; `on_gate` is what the `on` flip will check").
The endpoint writes no audit (counts only).

## 4.5 Scoped approvers (AC 10)

```
Letflow.Identity.ScopedApprovers
  @spec count(prefix) :: %{approvers: non_neg_integer(), task_workers_not_approvers: non_neg_integer()}
```

Definitions (one query each, plain, bound values, INV-7): over ACTIVE users (S-4; an inactive user cannot act and returns
through reactivation, which the integrity endpoint shows):

* HOLDER(U): U is a member of a group bound as `:platform_role` to `TASK_WORKER`.
* SCOPED_TW(U): HOLDER(U) and an applicable `TASK_WORKER` row of U with `tenant_wide = false` exists (user row, or group row
  of a group U belongs to and that group binds `TASK_WORKER`) and NO applicable `TASK_WORKER` row has `tenant_wide = true`.
* ROUTED(U): U is a member of a group bound as `:process_routing_role` (any name).
* `approvers` = |SCOPED_TW and ROUTED|; `task_workers_not_approvers` = |SCOPED_TW and not ROUTED|.

This is the AC's literal text ("holds TASK_WORKER only through scoped rows (no tenant-wide TASK_WORKER)"). Known
over-block (RA-2, S-4): the 518 F1 rule exempts a principal who holds the ROUTE permission tenant-wide through ANOTHER role
(RA-13: scoped TASK_WORKER plus tenant-wide PROCESS_OPERATOR is not stopped by F1). The AC definition would still count
that user. The F1-aligned alternative adds "and not allowed `:TasksComplete` tenant-wide". Default built: the AC's literal
definition (it can only refuse more, never allow a lockout); switch needs RA-2 plus a SEC ruling. Zero-row TASK_WORKER holders
are not scoped approvers (they are denied outright and are already counted by fact 1).

The count is read after lock A and S: every input (memberships, bindings, grant rows) is written under lock A, so the count
is stable for the transaction. The blocker is removed ONLY by the requirement that ships the `tasks.scope_node_id` writer;
the moduledoc says so (AC 10). No writer is added here (F14).

## 4.6 The shadow-evidence gate (AC 11, 12; 2f-a)

```
Letflow.ScopeEnforcement.ShadowWindow
  @type thresholds :: %{min_days: pos_integer(), min_requests: pos_integer(), retention_days: pos_integer()}
  @type criteria :: %{duration: boolean(), requests: boolean(), every_day_has_requests: boolean(),
                      no_blocking_would_deny: boolean(), configuration: boolean()}
  @type report :: %{shadow_since: DateTime.t() | nil, window_from: Date.t(), window_to: Date.t(), requests: non_neg_integer(),
                    days_without_requests: non_neg_integer(), would_deny: %{ShadowEvidence.metric() => non_neg_integer()},
                    criteria: criteria(), evidence_scope: String.t()}
  @spec thresholds() :: thresholds()
  @spec evaluate(tenant_id, prefix, now :: DateTime.t()) :: {report(), satisfied? :: boolean()}
  @spec evidence_scope() :: String.t()      # "tenant_wide_and_admin_plane_routes_only"
  @spec scope_sentence() :: String.t()      # the AC 12 sentence docs/roles.md must contain verbatim
```

Thresholds (application env only, never a request field; `attrs` accepts no thresholds): `:scope_shadow_min_days` (default 7,
integer, FLOOR 1), `:scope_shadow_min_requests` (default 100, FLOOR 1). Defaults live in `config/config.exs`; `config/test.exs`
may lower them; `config/runtime.exs` does NOT read them from `System.get_env` in this requirement (S-5: an operator override
can be added later with its own review). A non-integer or below-floor value is replaced by the DEFAULT (stricter or equal), never
by the floor. `retention_days` = `:scope_shadow_retention_days` (default 90). If `min_days > retention_days`, criterion
`configuration` is false (F17): the gate refuses and names it.

Algorithm (one call, one `now`):

1. T0 = `Audit.latest_matching(prefix, "tenant", tenant_id, ["scope.enforcement_enabled", "scope.enforcement_disabled"])`. If
   nil, or its `after_state["mode"] != "shadow"`: `shadow_since = nil`, criterion `duration` false.
2. (a) `duration` = T0 present and `DateTime.diff(now, T0.timestamp) >= min_days * 86400` (measured on TIMESTAMPS, AC 11).
3. Window dates: `window_from = Date.add(date(now), -min_days)` through `window_to = date(now)` INCLUSIVE; that is
   `min_days + 1` dates; both end dates are partial days counted IN FULL.
4. `counts_by_day(prefix, window_from, window_to)` (ONE grouped query, F11): `%{Date.t() => %{metric => count}}`; a date with no
   row is the all-zero map.
5. (b) `requests` = sum of `requests` over the window >= `min_requests`; `every_day_has_requests` = `requests > 0` on EACH date
   of the window (RA-4 of 517). `days_without_requests` is reported.
6. (c) `no_blocking_would_deny` = sum over the window of `no_grant_rows` + `grants_unavailable` == 0. The other four reasons
   are returned with counts and do not block. The two blocking reasons are a module attribute; the reported four are DERIVED
   as the six minus blocking (no second literal list, F18); T-E12 asserts blocking is a subset of `ShadowEvidence.reasons/0`
   (NEW public accessor, `@spec reasons() :: [metric()]`, delegating to `Scope.deny_reasons/0` once #2800 lands).
7. satisfied? = all five criteria true.

Partial-day rule (AC 11, pinned by T-E7): (a) is on timestamps; (b) and (c) sum whole dates; a date shared with an earlier
shadow period counts in full (conservative for (c); at most one extra partial date for (b)); with `min_days = N` the oldest
counted date can precede T0's date only when T0 is at least N days before `now`, never otherwise.

New reads: `ShadowEvidence.counts_by_day(prefix, from, to) :: %{Date.t() => %{metric() => non_neg_integer()}}` (same prefix
validation and `ArgumentError` as `counts_between/3`; reads the table only) and `Audit.latest_matching(prefix, resource_type,
resource_id, actions) :: Entry.t() | nil` (one query `ORDER BY timestamp DESC, id DESC LIMIT 1`, index #3).

Statement of scope (AC 12): `evidence_scope()` is a fixed constant carried by the refusal body, the refusal audit, and the
success audit; the moduledoc, docs/roles.md and the PR body state (verbatim sentence, `scope_sentence/0`): "The shadow period
proves only the denials of tenant-wide and admin-plane routes; denials on the data path (compiler predicate, 404 equivalence,
writes, bulk and import, F1) are proven by the REQ-518 tests and the end-to-end suite, not by shadow." A test reads
docs/roles.md and asserts the sentence, and asserts the field in the refusal.

Limits stated in the moduledoc (OQ-2 of the requirement): shadow evaluates only `:tenant_wide` and admin-plane routes; a crash
loses at most one flush interval of counts (only more lenient for (c), stricter for (b)); a tenant with no traffic on some day
(a weekend) cannot pass until every day of the window has requests (accepted, RA-4).

## 4.7 Route walk and SEC C-1 (AC 22; 2f-b)

As built the walk already enforces everything AC 22 names (route_scope.ex `audit_self_service/2`). 2f-b adds ONE test file,
`route_scope_on_flip_blocker_test.exs`, that asserts on the REAL mounted routes and the REAL list: (1) no route whose path
starts with `/me` or `/help` is default-sourced; (2) no `@self_service_routes` entry has `ruling: :pending_sec_ruling`, and
every `:tenant_wide` entry carries a binary ruling id; (3) the three routes are `:self_service` with the three ruling ids
(`0051-A7`, `SEC-518-R2-modules`, `SEC-518-R2-help`); (4) `RouteScope.audit_routes/3` returns `[]` on main. The check is a
BUILD-ORDER dependency recorded in the `ScopeEnforcement` moduledoc, not a runtime check (AC 9). The PR 2f-b body names
REQ-518 PR #2817 (fee577cf6) as the classifying PR and quotes SEC's 2f-b verdict as the C-1 check (S-8).

## 4.8 End-to-end suite (AC 16, 17; 2f-b)

One file, `test/letflow/scope_enforcement_on_e2e_test.exs`, real HTTP and real database, `async: false`. It FIRST asserts the
route walk is green (4.7). Fixture: module `fixture_scoped` with a declared scope column (518 AC 4, config/test.exs), the
`TaskScopeFixture.set_scope_node!/3` helper, an org tree with a retired intermediate node, users: scoped TASK_WORKER (subtree
A), scoped approver in a routing group, tenant-wide user, scoped TENANT_ADMIN, API token.

The tenant reaches `on` through the REAL flip (shadow -> on with seeded counters, backdated through `attrs[:now]` only in the
direct `flip/4` calls; the HTTP flip test seeds an audit entry and counters that satisfy the gate with floor thresholds
configured in test env), not through `set_stored_mode!`, so the suite also proves the gate end to end. Scenarios, one per AC
16 clause: scoped TASK_WORKER sees only its subtree through query, aggregate, export and cursor pages (aggregate counts and
buckets exclude other rows; there is no `total` on query/export, 518 F2); an out-of-scope id is byte-identical to a
nonexistent id on PUT/DELETE record, attachment GET, GET /tasks/:id, claim, complete, and on POST /entities/query it is the
same empty page; a PUT moving a record out of scope is refused; an import with one out-of-scope row is refused whole; with all
real types undeclared a scoped worker sees nothing and a tenant-wide user everything; a scoped approver outside the node's
subtree or routing role cannot claim or complete; a scoped TENANT_ADMIN is refused on the admin plane (one assertion per
admin-plane route class representative, the existing `admin_plane_under_on_test.exs` pattern); a tenant-wide user and a token
are unaffected; flipping back with a reason restores today's behaviour (byte-identical responses for the same requests).
Added (REVIEWER 518 F-6, S-7): a scoped caller's `upsert_by external_ref` import row answers the generic 404 while a
tenant-wide caller's upsert is unchanged (the known limitation, T-Z13). AC 17: a principal with a binding but zero rows is
denied `:no_grant_rows` and gets the 404-equivalent on data routes; removing a user's last scoped row (REQ-517 AC 7) and
retiring a referenced node (AC 5) cannot make a user tenant-wide, re-run in `on`.

Suite size is bounded: it reuses the 518 per-route fixtures through the existing `ScopedGrantsFixture`, `TaskScopeFixture`,
`ScopeEnforcementFixture`; it adds no new fixture module beyond a gate-satisfying seed helper `OnGateFixture.satisfy!/2`
(test/support) that inserts the audit entry and counter rows.

## 4.9 Source scan (AC 8)

`test/letflow/scope_enforcement_flip_authority_test.exs` (name fixed by the AC), AST-based: (1) the only module under `lib/`
that calls `ScopeEnforcement.flip(` is `lib/letflow/routers/tenant_scope_enforcement.ex`; (2) `Tenant.scope_enforcement_changeset(`
is called only by `scope_enforcement.ex` (existing T-O5 assertion, kept); (3) no `lib/` file other than `scope_enforcement.ex`
contains `update_all` / `UPDATE ... tenants ... scope_enforcement` / a `Repo.update` of a `Tenant` with `scope_enforcement`;
(4) (SEC S-5) the router builds the `attrs` argument of `flip/4` as a LITERAL three-key map (`actor_id`, `reason`, `trace_id`), never from body or merged input, and no `lib/` file other than `scope_enforcement.ex` contains the `:now` key in a `flip` call; `flip/4` ignores a non-DateTime `:now`; (4b) the `:credential` assign is set only by the auth pipeline (scan of `lib/` for `assign(.., :auth_context` writers that set `credential`), and T-H2 includes a token carrying TENANT_ADMIN; (4c) neither `config/runtime.exs` nor `config/prod.exs` sets `:scope_shadow_min_days`, `:scope_shadow_min_requests` or `:scope_shadow_retention_days`, and `Application.get_env` under prod config evaluation yields the defaults (test config lowers them in `config/test.exs` only; T-E9b); (5) `permission_scope(required_permission(:ScopeEnforcementManage)) == :tenant`
(F8); (6) the PUT handler uses `require_interactive_tenant_admin`. The scan is proven live on seeded sources.

## 4.10 Moduledoc and docs obligations (2f-b)

`Letflow.ScopeEnforcement` moduledoc: the transition table, the lock order A, T, S (then plain reads), the six facts, the
evidence limits, the build-order note (C-1), the scoped-approver blocker removal condition, the service-principal sentence
("the flagged-service-principal exemption covers ONLY the mint subset check; tokens of a flagged owner STILL block the flip"),
and "`on` is reached only from `shadow`". `docs/roles.md`: the flip procedure for an operator, the gate list with stable codes,
the evidence sentence (4.6), "what `on` means today" (section 6), "functional envelope of a scoped user under `on`" (section 5),
the scoped-upsert limitation. The 2f-b PR body links the letflow-2 decision-record amendment of 0051 D12/D8 or states it is
pending, and lists the platform-scope flip route for ANOTHER tenant as an open follow-up (AC 19, 20).

The 2f-b PR body, docs/roles.md and the operator runbook carry the following text (SEC ON_IN_PRODUCTION, verbatim in substance): (1) after this change a tenant that passes the gate can be set to `on` by an interactive tenant-wide TENANT_ADMIN, only from `shadow`, with an audit trail; (2) in production today `on` delivers: closure of the admin plane to scoped admins, a uniform 403 for scoped users on every tenant-wide route, no new tenant-wide grant rows from binding writers or IdP sync, and fail-closed grant tables; (3) `on` does NOT deliver data-level scoping in production: no installed module declares scope (scoped users see no entity data) and tasks have no scope-node writer (scoped task workers see no tasks, scoped approvers cannot claim or complete); (4) the shadow period proves only the denials of tenant-wide and admin-plane routes (the AC 12 sentence, verbatim); the flip request itself is counted as a shadow request and request counts include every authorized request of any principal, including the admin's own, so the every-day rule is effectively about the previous `min_days` dates and criterion (b) is an operator-safety control, not an adversarial one; (5) scoped users lose definitions, entity-definition, instance and service reads until the RA-6 follow-up ships; (6) do not scope the CANDIDATE binding (exam routes stay tenant-wide); (7) to turn `on` off: an interactive tenant-wide TENANT_ADMIN with a mandatory reason; tokens cannot; there is no platform-scope break-glass in this release (R-10); (8) pilot tenants only until RA-6 and the task scope writer exist. The PR body also lists the BEHAVIOUR CHANGES (SEC S-3): API tokens and a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN lose `PUT /tenant/scope-enforcement`, for off -> shadow as well (stage 1 allowed tokens); the existing tests changed and why; the AC 19 amendment link or its pending status; the RA-6 follow-up id; and the confirmation that no time-boxed 0050 D7 interim option (c) is in force (0051 Rollout 5). Evaluation time: the scoped-approver blocker is evaluated at flip time only; a scoped approver created after `on` is fail-closed and shown in the integrity `on_gate` information count.

---

# 5. Route census for SEC C-1 and C-2 (which `:tenant_wide` routes does a scoped user need?)

Method: the committed snapshot `test/fixtures/route_scope/tenant_wide_default_routes.txt` (115 default-sourced lines) crossed with
the role matrix of `docs/roles.md` (coarse permission per role). A scoped user is a holder of a non-admin role whose grant rows
are scoped. Under `on`, a `:tenant_wide` route requires the permission held TENANT-WIDE (`Enforce.require_tenant_wide`), so a
scoped holder gets the uniform 403.

| Family (snapshot lines) | Permission(s) | Roles holding it besides TENANT_ADMIN | Scoped holder under `on` | Disposition in 519 |
|---|---|---|---|---|
| `/me/memberships`, `/me/modules`, `/help/resolved` | MembershipsRead, MyModulesRead, HelpRead | all (CANDIDATE only MyModulesRead) | `:self_service`, allowed | classified by #2817 with rulings; C-1 literal satisfied |
| `GET /definitions*`, `POST /definitions/:id/validate`, `/solution-packs/export`, `/solution-packs/update-review`, `GET /services` | DefinitionsRead | PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_AUDITOR | 403 | stays; tenant-level metadata CANDIDATE for a later `:self_service` ruling (RA-6); a scoped worker cannot read a definition |
| `GET /entities/definitions*` (E3 to E6, declared `:tenant_wide` by 518) | EntitiesDefinitionsRead | same four | 403 | stays; a scoped worker cannot read the column catalogue of a type it queries; same follow-up (RA-6) |
| `GET /instances`, `/instances/:id`, `/history`, `/pins`, `/timeline` | InstancesRead | same four | 403 | stays: instances have NO scope node (T13 not built); a resolver would be empty |
| `/instances/:id/attachments*`, `/instances/storage-usage` | AttachmentsRead / Manage | same four / PROCESS_OPERATOR | 403 | stays; link routes pinned `:tenant_wide` (M7) |
| `POST /instances`, `cancel`, `advance-timer`, `rebind-pins`, `reconstruct` | InstancesStart / Cancel / AdvanceTimer | PROCESS_DESIGNER, PROCESS_OPERATOR | 403 | stays: a scoped operator cannot start or cancel an instance; needs an instance scope node |
| `/audit`, `/dlq*`, `/webhooks/*`, `/script-*`, `/promotions*`, `/tenant/settings`, `/tenant/modules`, `/tenant/solutions`, `/admin/services*`, `/public-read-handles` | AuditRead, DlqOperate, WebhooksManage, Scripts*, Promotions*, TenantSettingsManage, ModulesManage, PlatformServicesManage, PublicReadHandlesIssue | PROCESS_OPERATOR / PROCESS_DESIGNER / TENANT_AUDITOR for some | 403 | stays: tenant-level operations; correct to require tenant-wide |
| `/tenants*`, `/onboarding*`, `/platform-migrations*`, `/event-retention*` | TenantsManage (platform scope) | none | n/a | stays; platform scope never reads grants |
| `/modules/exam/*` (8 snapshot lines) | exam module permissions | CANDIDATE, exam roles | 403 for a SCOPED CANDIDATE | stays by SEC-518-R1: the exam data-access sites use the literal `:all` and are safe only while every exam route is `:tenant_wide` (walk rule `:exam_route_reclassified`). Consequence recorded: narrowing the CANDIDATE binding breaks exam sessions; docs/roles.md says do not scope CANDIDATE |
| `GET /modules/fixture/items/:id` | FixtureRead | test module | test only | stays |

Findings: (1) NO default-sourced route that a scoped user needs for the task-worker flow (`/tasks*`, entity query/record/attachment
routes) remains: those were reclassified in 518. (2) The reads a scoped worker is blocked from are tenant-level metadata
(definitions, entity definitions, services) and instance routes. The first group is a candidate `:self_service` class
extension (definition: tenant-level metadata, no per-resource data) that needs its own SEC ruling per route (C-2). (3) 519
reclassifies NOTHING: the census is residual R-2, the function-level answer for operators is "a scoped user can use tasks and
declared entity types and the `/me`, `/help` reads, and nothing else", and RA-6 asks REQ-ANALYST for a follow-up requirement.
C-2 is satisfied vacuously for 519 (no reclassification, no snapshot change); the PR bodies say so.

# 6. What must be true before `on` is meaningful (R-8, F14, F15)

`on` is SAFE after 519 (every unclassified or undeclared surface denies a scoped caller), but it is not USEFUL until:

1. at least one installed module ships `:scope_declarations` for its managed types (production: none do; the unmanaged allowlist key is unset, default
   `[]`, T-D8 of 518 pins it) — otherwise a scoped caller sees no entity data;
2. the W3b requirement ships the writer of `tasks.scope_node_id` and instances get a scope node (T13) — otherwise a scoped
   worker sees no task and a scoped approver cannot claim or complete (the reason for the AC 10 blocker);
3. the tenant-level metadata reads of section 5 are ruled into `:self_service` or a scoped user is accepted to lack them.

ON IN PRODUCTION (SEC S-9, OQ-6; the text of 4.10 items 1 to 8 is mandatory in the PR body, docs/roles.md and the runbook): `on` closes the admin plane to scoped admins, gives scoped users a uniform 403 on tenant-wide routes, stops writers and IdP sync from widening, and keeps the grant tables fail-closed; it does NOT scope data in production, scoped users lose definitions, entity-definition, instance and service reads until RA-6, the CANDIDATE binding must not be scoped, only an interactive tenant-wide TENANT_ADMIN can turn it off (mandatory reason, no platform break-glass), and only pilot tenants may be flipped until RA-6 and the task scope writer exist. Process control replaces the missing signal (OQ-6 not built).

What `on` DOES deliver in production today: the admin plane is closed to scoped admins (D11), scoped users are denied on every
`:tenant_wide` route, writers cannot widen (2e), and the grant tables are fail-closed (AC 17). The PR body and docs/roles.md say
exactly this and no more ("do not claim data-level scoping in production until items 1 and 2 hold"). OQ-6 asks whether to add an
informational integrity count for item 1; default not built.

# 7. AC map

| AC | PR | Design element | Section | Tests |
|---|---|---|---|---|
| 1 | 2e-a | registry, three states, per-mode tests, scan, REFUSED/NO-ROW/UNCHANGED, reports | 3.3 to 3.6 | T-B1..T-B14, T-R1..T-R6, T-N1..T-N6, T-C1 |
| 2 | 2e-b | case (3) suppression with delta rule, one audit in the sync transaction | 3.9 | T-S1..T-S5 |
| 3 | 2e-b | pending_scope, exact key set, dedup from stored data, remedy | 3.9 | T-S6..T-S10 |
| 4 | 2e-b | `scope_delta` on `group_member.*`, every mode | 3.8 | T-D1..T-D5 |
| 5 | 2e-a | by-construction guard and property test over the writer set | 3.3 | T-I1, T-I2 |
| 6 | 2e-a | lock A serialisation, mode read after A | 3.2, 3.7 | T-L1..T-L3 |
| 7 | 2e-a/2e-b | action listing without error, no secret in payloads | 3.5, 3.8, 3.9 | T-A1..T-A4 |
| 8 | 2f-b | parse_mode, transitions, authority, source scan, not settable elsewhere | 4.1, 4.2, 4.9 | T-X1..T-X8, T-H1..T-H8 |
| 9 | 2f-a/2f-b | six facts in lock order, explicit count, integrity block | 4.4 | T-G1..T-G10 |
| 10 | 2f-a | scoped approver definition, informational count | 4.5 | T-P1..T-P7 |
| 11 | 2f-a | evidence algorithm, partial-day rule, env-only thresholds | 4.6 | T-E1..T-E13 |
| 12 | 2f-a/2f-b | `evidence_scope` field, sentence in docs | 4.6, 4.10 | T-E14, T-E15 |
| 13 | 2f-b | audit of success, reasons, ungated de-escalation, forced audit failure | 4.1 | T-X9..T-X14 |
| 14 | 2f-a/2f-b | refused audit, own transaction, per failing precondition | 4.3 | T-F1..T-F8 |
| 15 | 2f-a/2f-b | action listing for refused, enabled/disabled with mode `on` | 4.3 | T-A5, T-A6 |
| 16 | 2f-b | end-to-end suite | 4.8 | T-Z1..T-Z14 |
| 17 | 2f-b | fail-closed re-run in `on` | 4.8 | T-Z15..T-Z17 |
| 18 | 2f-a/2f-b | INV-1, 2, 4, 8 on gate and route; captured-log assertions; raise forces refusal | 4.2, 4.4, 9 | T-G9, T-G10, T-F9, T-H9 |
| 19 | 2f-b | PR body link to the amendment | 4.10 | (process; checked by ORCH) |
| 20 | 2f-b | open follow-up listed; scan T-X8 proves not built | 4.9, 4.10 | T-X8 |
| 21 | all | gates | 12 | commands |
| 22 | 2f-b | C-1 walk test, named PR | 4.7 | T-RW1..T-RW4 |

# 8. Tests (TEST-DESIGNER writes them; ids are the contract)

Naming follows the repo: `test/letflow/...`. `DataCase`, `async: false` for committed writes, locks and the sync.

## 8.1 PR 2e-a

* `identity/binding_writers_modes_test.exs`: T-B1..T-B14, one per registry row in the ORDER of 3.4 (W-a=T-B1, W-b=T-B2, W-b2=T-B3, W-c1=T-B4, W-c2=T-B5, W-c3=T-B6, W-d1=T-B7, W-d2=T-B8, W-e=T-B9, W-f1=T-B10, W-f2=T-B11, W-g1=T-B12, W-g2=T-B13, W-h=T-B14), EACH
  asserted in `off`, `shadow` and `on` (`ScopeEnforcementFixture.set_stored_mode!/2`); in `off`/`shadow` the row behaves as today and
  the existing `role_scope_grants_writers_test.exs` (T-W1..T-W14) is untouched.
* `identity/binding_refusal_test.exs`: T-R1 409 `scope_required` for POST /roles nil -> platform; T-R2 kind change routing ->
  platform incl. re-creation after platform -> routing; T-R3 `binding.refused` exists after the rollback, key set exactly
  `{actor, role, group, case, trace_id}`, no binding row and no grant row written; T-R4 a failing audit write still returns the
  refusal and logs the constant line; T-R5 inside an open transaction nothing is written and the line is logged; T-R6 remedy text
  present and constant.
* `identity/binding_no_row_report_test.exs`: T-N1 `upsert_role_report` `:skipped_enforced`; T-N2 rebind with zero rows moving is
  skipped and the scoped-rows case moves them (UNCHANGED asserted); T-N3 seeding report and `RoleBackfill` result key; T-N4 TAM
  tenant skipped; T-N5a/b/c `Backfill` in an enforced tenant (3.6a) and the mix task output; T-N6 the T9 query and the integrity endpoint show
  the zero-row binding; every case asserts the ONE constant log line and no id in it (captured-log).
* `identity/binding_writers_scan_test.exs`: T-C2 each INDIRECT row names a function that exists in its file AND whose body still reaches a scanned site (an AST reachability check over the module's own functions, so an indirect writer that stops calling `reconcile_binding!` cannot silently become unclassified); T-C1 the AST scan over the six functions equals the SCANNED rows, proven live on a seeded unregistered call
  (MU-1) and on a seeded call in an alias form; the `binding_policy` option appears only in `role_registry.ex`.
* `identity/enforced_writers_invariant_test.exs`: T-I1 property test (StreamData): random sequences over the writer set in `on`
  never increase the count of `tenant_wide = true` rows, except the explicit make-tenant-wide route; T-I2 in `off`/`shadow` a
  legacy writer still inserts the row.
* `identity/enforced_writers_lock_test.exs`: T-L1 `mode_under_lock!/1` raises outside a transaction, raises `ModeUnavailableError` when the read fails (table renamed inside the sandbox), and T-L4 production-shaped config (Config.Reader over config.exs, prod.exs, runtime.exs, env :prod): the lenient key is unset and `mode_under_lock!/1` RAISES for a malformed prefix and for a well-formed prefix with no `tenants` row; T-L5 the key occurs only in `config/test.exs` (scan); T-L6 with the key set, the same two cases return `:off` and log the constant line without the prefix (only if the key is built); T-L7 a raised mode read rolls back the writer, the sync and seeding with no binding, row or audit written (C-2); T-L2 lock A held, writer queued first then flip: the writer's binding and row are visible to the flip's T9; T-L3 flip
  queued first: the writer sees `on` and refuses. Waiting is detected through `pg_stat_activity` wait events, not sleeps.
* `identity/enforced_audit_actions_test.exs` (2e part): T-A1 `binding.refused` listed through `Audit.list_entries` (resource_type /
  resource_id filters) without error; T-A2 no token value, hash or IdP claim in any 2e payload.

## 8.2 PR 2e-b

* `identity/sync_scope_guard_test.exs`: T-S1 sync into a tenant-wide group for a user holding scoped rows in `on`: no membership,
  login succeeds, ONE `grant.sync_suppressed` in the same transaction with keys `{user, group, role, trace_id}`, effective scope
  unchanged; T-S2 same in `shadow`: legacy membership added; T-S3 a group binding two roles where the unclaimed one is tenant-wide
  is suppressed (F4); T-S4 a group with scoped rows is NOT suppressed; T-S5 a user already tenant-wide for the role is not
  suppressed; T-S6 user with no rows: no membership, `binding.pending_scope` key set EXACTLY `{user, group, role, trace_id}`; T-S7
  the role is absent from `list_effective_role_names/2`, the coarse check is 403, `allowed?/3` is `{:deny, :role_not_held}`; T-S8
  three syncs yield one entry, a second role a second; T-S9 dedup survives a process restart (state in the table only); T-S10
  after an admin adds the user to a scoped group the user holds exactly that scope; T-S11 marker stamped when all suppressed (F5);
  T-S12 an audit failure rolls the whole sync back and the marker stays nil; T-S15 held-lock rebind: lock A held, the sync queued, a rebind of a role onto a tenant-wide group queued behind it is resolved before the lock and committed after: the decision uses the bindings read after A (use the T-L2 technique); T-S16 a group bound only as `:process_routing_role` is never suppressed even when it has a tenant-wide row; T-S17 docs/roles.md states that the whole group is withheld when any bound platform role would widen (A-7).
* `identity/membership_scope_delta_test.exs`: T-D1 add to a tenant-wide group (deny -> tenant_wide); T-D2 add to a scoped group
  ({nodes}); T-D3 remove; T-D4 the entry exists in `off`, `shadow` and `on`; T-D5 the pre-existing keys and the GH 2547 tests are
  unchanged (`roles_gained`, `group_roles`); node ids capped at 50 with `count`.
* `identity/enforced_audit_actions_test.exs` (2e-b part): T-A3 `grant.sync_suppressed`, `binding.pending_scope`, `group_member.*`
  listed without error; T-A4 key sets and no claim value.

## 8.3 PR 2f-a

* `scope_enforcement/on_gate_test.exs`: T-G1..T-G8, one per fact, each alone and a combined case naming EVERY failing code (T-G8);
  T-G2 a flagged service-principal owner with an exceeding token is refused `tokens_exceed_owner`; T-G4 a tenant whose only
  TENANT_ADMIN member sits in a zero-row binding is refused `zero_tenant_wide_admins`; a tenant with zero admins is refused and
  after an admin is bound the same call passes (AC 9); T-G9 each fact's table renamed inside the sandbox raises and the flip is
  refused with no flag change (INV-8); T-G10 a held lock A makes the evaluation wait and a changed admin count after the lock is
  seen (lock-order test).
* `identity/scoped_approvers_test.exs`: T-P1 one scoped approver blocks; T-P2 making that user a tenant-wide TASK_WORKER clears; T-P3
  removing the scoped row clears; T-P4 removing the routing membership clears; T-P5 a scoped TASK_WORKER in no routing group does not
  block and is counted informationally; T-P6 an inactive user is not counted (S-4); T-P7 a zero-row TASK_WORKER holder is not a
  scoped approver.
* `scope_enforcement/shadow_window_test.exs`: T-E1 (a) alone refuses; T-E2 (b) total alone; T-E3 (b) every-day alone (100 requests
  on one day and zero on another); T-E4 (c) alone; T-E5 all satisfied passes; T-E6 shadow -> off -> shadow restarts (a); T-E7 the
  partial-day rule: counters seeded on both end dates and on T0's date; T-E8 no request field or `attrs` key lowers a threshold
  (body with `min_days` fields; `attrs` unknown keys ignored); T-E9 invalid or below-floor env falls back to the default; T-E9b prod-config evaluation yields the defaults and runtime.exs/prod.exs never set the three keys; T-E10
  `min_days > retention_days` fails `configuration`; T-E11 injectable `now`; T-E12 blocking reasons subset of
  `ShadowEvidence.reasons/0`, the reported four derived; T-E16 the flush-before-flip: a request recorded just before the flip with a 1h flush interval is counted for `date(now)` (kills MU-42); T-E13 `counts_by_day/3` equals the per-day sums of `counts_between/3`,
  absent days are zero maps, ONE statement (query-count helper); T-E14 `evidence_scope` constant in the report; T-E15 the sentence
  is verbatim in docs/roles.md.
* `scope_enforcement/refused_audit_test.exs`: T-F1..T-F8 one per failing code plus `shadow_required`: `scope.enforcement_refused`
  in its OWN transaction after the rollback, failing names, six reason counts, actor, trace, no flag change; T-F9 captured-log
  assertion (no ids, no token data) on gate and flush paths; T-F10 a failed refusal audit still returns the refusal.
* `audit/latest_matching_test.exs`: ordering, action filter, nil.
* `routers/tenant_scope_enforcement_integrity_test.exs` (moved here from 2f-b in r1; 2f-a ships the integrity `on_gate` block): the `on_gate` block, `blocking`/`information`, explicit-count semantics, the two spellings, no audit written.

## 8.4 PR 2f-b

* `scope_enforcement_transitions_test.exs`: T-X1 `parse_mode/1` accepts exactly `off|shadow|on`, rejects `ON`, `nil`, atoms, maps, no
  atom minted; T-X2 shadow -> on; T-X3 on -> shadow; T-X4 on -> off; T-X5 off -> on is `shadow_required` and audited; T-X6 same mode
  unchanged, no audit; T-X7 the actions: enabled for shadow -> on and off -> shadow, disabled for on -> shadow, on -> off, shadow ->
  off; T-X9 on -> shadow and on -> off need a reason (blank is `reason_required`, nothing written); T-X10 a seeded failing precondition
  (binding without row, exceeding token): on -> shadow with a reason succeeds and audits while off -> shadow with the same seed is
  refused; T-X11 on -> off never gated; T-X12 forced audit failure rolls the flip back; T-X13 stage-1 `off` same-mode without a reason
  is still 422 (F10); T-X14 `GET /` lists three modes.
* `scope_enforcement_flip_authority_test.exs`: T-X8 plus the scan of 4.9.
* `routers/tenant_scope_enforcement_on_test.exs`: T-H1 composed permission scope (F8); T-H2 scoped admin, non-admin, API-token
  TENANT_ADMIN and platform-tenant PLATFORM_ADMIN get the byte-identical 403 on PUT; T-H3 the GET routes still serve tokens; T-H4
  `PUT` of the same key through the generic entities API and the tenant_config/tenant settings API leaves the column unchanged; T-H5
  409 bodies for each refusal (field-by-field, no ids); T-H6 `shadow_required` body; T-H7 `evidence` carries all six counts; T-H8 the
  service-principal route still behaves the same after the helper hoist; T-H9 500 detail-free on a raised precondition; T-H10 captured log: exactly one `scope_enforcement_flip_failed` line with the reason tag and exception module only (C-5, MU-52), and `flip/4`'s `rescue` encloses the WHOLE transaction including `OnGate.evaluate/3` (a raise from any fact reaches it).
* `api/route_scope_on_flip_blocker_test.exs`: T-RW1..T-RW4 (4.7; renamed from T-W1..T-W4 by CDV, which collide with the stage-1 writer tests T-W1..T-W14).
* `scope_enforcement_on_e2e_test.exs`: T-Z1..T-Z17 (4.8).

Existing tests that MUST change (forced by behaviour): `scope_enforcement_on_test.exs` T-O2 and T-O4 (`on` is no longer rejected;
`available_modes`), `scope_enforcement_test.exs` and `routers/tenant_scope_enforcement_test.exs` cases asserting `"on"` is
`invalid_enforcement_mode`, the stage-1 `flip/4` gating test keyed on `target == :shadow`, the shadow-reason-keyed audit action
test, and `req497` spec cases listing `["off","shadow"]`. Each is listed in the PR body with its reason.

# 9. Mutants (the suite must kill each)

| Id | Mutation | Killed by |
|---|---|---|
| MU-1 | a new unregistered call site of an entry point | T-C1 |
| MU-2 | `ensure_tenant_wide_group_row!` ignores the mode | T-B1, T-I1 |
| MU-3 | `repair_group_row!` inserts in `on` | T-B5, T-N1 |
| MU-4 | `move_group_rows!` repairs when zero moved in `on` | T-N2 |
| MU-5 | `reconcile_binding!` refuses `P -> P` or `P -> nil` | T-B3 (P -> not P), T-B4 (P -> P), T-N2 |
| MU-6 | `mode_under_lock!` swallows a failed read, a malformed prefix or a missing row as `:off` in production | T-L1, T-L4 |
| MU-47 | the lenient key is read in runtime/prod config or defaults to true | T-L4, T-L5 |
| MU-48 | a writer, the sync or seeding proceeds as `off` after a raised mode read | T-L7 |
| MU-7 | mode read BEFORE lock A | T-L2, T-L3 |
| MU-8 | `binding.refused` written inside the rolled-back transaction | T-R3 |
| MU-9 | refusal audit raise propagates | T-R4 |
| MU-10 | seeding nil branch REFUSES in `on` (sweep halts) | T-N3 |
| MU-11 | `binding_policy` option accepted from the HTTP route | T-C1 option scan, T-R1 |
| MU-12 | sync evaluates only the claimed role | T-S3 |
| MU-13 | sync suppresses when the group has scoped rows | T-S4 |
| MU-14 | sync suppresses a user already tenant-wide | T-S5 |
| MU-15 | pending_scope payload gains a claim value or a key | T-S6 |
| MU-16 | dedup kept in memory | T-S9 |
| MU-17 | marker not stamped when all suppressed | T-S11 |
| MU-18 | `scope_delta` only in `on` | T-D4 |
| MU-19 | `scope_delta` replaces `roles_gained` | T-D5 |
| MU-20 | `parse_mode/1` accepts `ON` or mints an atom | T-X1 |
| MU-21 | `enable_checks!` still runs for `on -> shadow` | T-X10 |
| MU-22 | `shadow -> on` skips the S lock or reads a fact before it | T-G10 |
| MU-23 | `off -> on` allowed | T-X5 |
| MU-24 | audit action keyed on `target == :shadow` | T-X7 |
| MU-25 | gate uses `count_tenant_wide_admins/1` | T-G4 |
| MU-51 | fact 4 counts a flagged service principal or a token owner | T-G4 (i), (ii) |
| MU-26 | flagged service principal exempts a token | T-G2 |
| MU-27 | gate returns on the first failing fact | T-G8 |
| MU-28 | a raised read is rescued as "no failure" | T-G9 |
| MU-29 | scoped approver counts inactive or zero-row users | T-P6, T-P7 |
| MU-30 | evidence total-only (no every-day rule) | T-E3 |
| MU-31 | `>` instead of `>=` at the duration boundary | T-E1 |
| MU-32 | (c) counts only one blocking reason | T-E4 |
| MU-33 | window excludes either end date | T-E7 |
| MU-34 | threshold readable from `attrs` or body | T-E8 |
| MU-35 | N+1 `counts_between` calls | T-E13 |
| MU-36 | T0 taken from the first, not the latest, shadow entry | T-E6 |
| MU-52 | the 500 path logs nothing or logs ids/values | T-H10 |
| MU-53 | a platform tenant stored `on` blocks its PLATFORM_ADMIN on platform-scope routes | T-O7 |
| MU-37 | PUT admits a token or a platform-tenant PLATFORM_ADMIN | T-H2 |
| MU-38 | refused flip not audited, or audited inside the rolled-back transaction | T-F1..T-F8 |
| MU-39 | a raised precondition recorded as a refusal | T-G9 |
| MU-40 | `evidence_scope` field missing | T-E14 |
| MU-41 | the helper hoist drops the credential check of the service-principal route | T-H8 |
| MU-43 | Backfill gap check still rolls back in `on` | T-N5a, T-N5c |
| MU-44 | Backfill writes `scope.backfill_completed` in `on` | T-N5a |
| MU-45 | the sync sibling changes the return of `sync_role_claims_from_token/3` | T-S13 |
| MU-49 | the group-role read happens before lock A (stale after a concurrent rebind) | T-S15 |
| MU-50 | `would_widen?` counts a routing-role binding | T-S16 |
| MU-46 | suppressed result omits a suppressed pair or carries a claim value | T-S14 |
| MU-42 | flush-before-flip dropped (spurious "no requests today") | T-E16 (flip right after a request, flush interval 1h) |

# 10. Security: INV analysis and residual risks

| INV | Where | Statement |
|---|---|---|
| INV-1 | writers, gate, route | tenant from the plug's `scoped_opts[:prefix]` and `auth_context.tenant_id` only; the mode read derives the tenant id from the schema name; a failed read, a malformed prefix or a missing `tenants` row RAISES in production (3.2, SEC C-1; the lenient `:off` is test-config only); no tenant value from body, query or path |
| INV-2 | route bodies, audit | bodies built field by field; counts and enums only; no ids in refusals; `scope_delta` carries org-unit ids only |
| INV-4 | all new log lines and audits | constant lines (`binding_row_skipped`, `binding_refusal_not_recorded`, `scope_enforcement_refusal_not_recorded`); no token value, hash, prefix or IdP claim value in any audit payload or log; captured-log tests |
| INV-5 | data path | untouched in 519; AC 16/17 re-prove 404 equivalence under a flip made through the real gate |
| INV-6 | sync | no new input from the claim beyond the already-resolved role names; no claim value stored |
| INV-8 | `mode_under_lock!`, gate, route | every failure refuses or rolls back, never allows; a precondition read that raises refuses the flip (T-G9); the writer mode read raising rolls the write back |
| INV-10 | grants vs PLATFORM_ADMIN | unchanged: grant rows for the PLATFORM_ADMIN binding are never consulted; the flip authority excludes a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN |

Residual risks (for SECURITY-REVIEWER):

* R-1 (accepted): a crash loses at most one flush interval of counters: (b) stricter, (c) more lenient by that amount; the 7-day
  window and every-day rule bound the effect.
* R-2 (documented): the tenant-level metadata and instance routes of section 5 deny scoped users under `on`; this is the safe
  direction; RA-6 follow-up.
* R-3 (documented): `on` delivers no data-level scoping in production until module declarations and the task scope writer exist
  (section 6); operators are told in docs/roles.md.
* R-4 (accepted): `binding.pending_scope` and `grant.sync_suppressed` dedup is permanent per (user, role): a recurrence after an
  admin resolved the first is not re-recorded.
* R-5 (accepted): the refusal audit is best-effort (a failed write logs and the 409 is returned), as for `tenant_admin.guard_refused`.
* R-6 (known limitation, documented): a scoped caller's `upsert_by external_ref` import is refused with the generic 404 (518 5.4).
* R-7 (accepted): the evidence gate cannot pass for a tenant with a day of zero traffic in the window (weekend), by design.
* R-8 (accepted): the gate's facts are read as a snapshot under A and S; token mint/revoke are not serialised by A in all paths, so
  `tokens_exceed_owner` retains its stage-1 race window (pre-existing, unchanged by 519).
* R-9 (accepted): the seeding NO-ROW case lets a pre-existing named group with members acquire the role at the coarse level with
  zero rows (denied by `allowed?/3`); reported by T9 and integrity.
* R-10 (not built): the platform-scope route that flips ANOTHER tenant's flag (0046 D4, 0051 M5); T-X8 is the machine check.

# 11. SECURITY-REVIEWER rulings requested at the design gate

| Id | Question | Default built |
|---|---|---|
| S-1 | Seeding nil -> P in an `on` tenant: NO-ROW (binding without a row, sweep continues) or REFUSED (sweep halts)? And TAM nil branch: whole tenant skipped? | NO-ROW for seeding; TAM tenant skipped (this also skips legacy-binding removal and token rewrite); S-1b (r2): NOT accepted for production; `mode_under_lock!` raises, lenient `:off` only behind a test-only key (C-1) |
| S-2 | Sync suppression: the no-widening principle over every role the group binds; marker stamped when everything was suppressed; permanent per-(user, role) dedup | as stated in 3.9 |
| S-3 | Flip authority narrowing (token and platform-tenant PLATFORM_ADMIN lose PUT) and the shared helper | built per AC 8 |
| S-4 | Scoped-approver definition: AC literal vs F1-aligned; active users only | AC literal, active only |
| S-5 | Gate details: flush-before-flip, defaults on invalid env, `configuration` criterion, T0 from the audit chain, no runtime.exs override, the `attrs[:now]` seam | as stated in 4.6 |
| S-6 | Refusal audit best-effort and not written for server faults | as stated in 4.3 |
| S-7 | Route census disposition: no reclassification in 519, C-1 satisfied by #2817 rulings, C-2 vacuous; exam routes keep the tenant-wide requirement | as stated in section 5 |
| S-8 | Sub-PR split with `on` unreachable until 2f-b; the 2f-b verdict is the C-1 check | RA-5 |
| S-9 | Accept `on` with no declared types in production (fail-closed, documented) | accepted, documented |
| S-10 | The audit payload `scope_delta` includes org-unit ids readable by AuditRead holders | ids only, as in grant entries |

RULED (SEC design gate PASS_WITH_FINDINGS, handoffs/WF02-REQ519-ENFORCED-WRITERS-20261018/step-04-security-reviewer-design.json): S-1 ACCEPTED (NO-ROW seeding with `rows = skipped_enforced` audit key and T9 chain; TAM whole-tenant skip incl. legacy removal and token rewrite); S-1b NOT ACCEPTED for production, test-only key (C-1); S-2 ACCEPTED with C-3 and the routing-role rule; S-3 ACCEPTED (behaviour-change list); S-4 ACCEPTED AC-literal, active only; S-5 ACCEPTED with scan conditions (4.9); S-6 ACCEPTED with C-5; S-7 ACCEPTED; S-8 ACCEPTED; S-9 ACCEPTED with the ON_IN_PRODUCTION text; S-10 ACCEPTED (ids only, key set asserted, no names or paths). RA-1..RA-10 ACCEPTED; RA-6 is REQUIRED before 2f-b merges. OQ-1, OQ-3, OQ-4, OQ-6 ACCEPTED. Required changes: C-1/C-2 before 2e-a is built, C-3/C-4 before 2e-b (C-4 lands in 2f-a), C-5/C-6 before 2f-b, C-7 this revision. Advisories: A-1 sync lock_timeout fails closed (accepted); A-2 repeated PUT can force flushes (admin-only, accepted); A-3 integrity `on_gate` readable by tokens like `GET /` today (accepted); A-4 token race pre-existing (R-8); A-5 inside-transaction guard test technique (4.3); A-6 do not extend the `claimed_roles` warning; A-7 docs state the whole group is withheld (T-S17); A-8 audit growth bounded by admin traffic (no rate-limit change, decision 0040).

Each of 2e-a, 2e-b, 2f-a, 2f-b ends with its own SECURITY-REVIEWER code verdict (C-2); the PR template of 7.5 of the 518 design is
reused.

# 12. Gates and commands (AC 21)

Per PR: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix letflow.check`, `mix letflow.check_boundaries`,
the scoped `mix test` over `test/letflow/identity*`, `test/letflow/routers/identity*`, `test/letflow/routers/onboarding*`,
`test/letflow/plugs`, `test/letflow/api`, `test/letflow/scope_enforcement_test.exs`, `test/letflow/routers/tasks*_test.exs` and the
new files, real output quoted; `mix letflow.check_requirements_registration`; `mix letflow.check_role_scope_grants_writers`.
New tests with committed writes run one file at a time (machine constraint). Requirement text is CRLF in the working tree: edits to
`docs/requirements.yaml` preserve it.

# 13. Requirement amendments proposed (REQ-ANALYST / letflow-2; not edited here)

| # | Amendment | Source |
|---|---|---|
| RA-1 | AC 1 table gains rows W-g1 (seeding nil -> P, NO-ROW) and W-g2 (TAM nil branch, tenant skipped), and the completeness scan stays on the AC's six functions plus `Backfill.run` (r1); the indirect entry points are classified by rows but not scanned | F2 |
| RA-2 | AC 10: optionally align "scoped approver" with the F1 exemption predicate (add "and not allowed the task route permission tenant-wide"); default stays the literal text | 3 over-block, S-4 |
| RA-3 | AC 8: state the platform-tenant PLATFORM_ADMIN consequence and the composed permission-scope assertion | F8, F9 |
| RA-4 | AC 7 and 15: "action filter" does not exist; rewrite as "returned by `Audit.list_entries` with the resource filters" | F7 |
| RA-5 | Sizing: 2e split into 2e-a/2e-b and 2f into 2f-a/2f-b (otherwise commit order inside 2e/2f) | section 1 |
| RA-6 | New follow-up requirement (not 519): rule the tenant-level metadata reads (definitions, entity definitions, services) into `:self_service` one by one with SEC, and decide instance scope (T13) | F13, section 5 |
| RA-7 | AC 11: "counted per UTC day" is computed with ONE grouped read; `counts_between/3` unchanged | F11 |
| RA-8 | AC 13: the transition-keyed reason rule is only `on -> shadow`; `off` stays target-keyed | F10 |
| RA-10 | AC 16 "totals excluding other rows": query, export and cursor pages carry no `total` (518 F2); read as the aggregate counts and buckets plus the item set of each page | CDV |
| RA-6 (REQUIRED, SEC) | the follow-up requirement of RA-6 is filed by REQ-ANALYST BEFORE PR 2f-b merges; 2f-b cites its id | SEC step-04 |
| RA-9 | AC 2/3: marker stamped when every candidate was suppressed; the suppression principle is "no widening over any role the group binds" | F4, F5 |

# 14. Open questions (with the default this design builds)

| # | Question | Default built | Needs |
|---|---|---|---|
| OQ-1 | Refusal body: one `detail` `enforcement_precondition_failed` with codes in `failed`, or the single code as `detail` when exactly one fails | uniform detail, codes in `failed` | REQ-VALIDATOR/CDV |
| OQ-2 | `modes/0` and `stored_modes/0` | one list, `stored_modes/0` delegates | none |
| OQ-3 | TAM in an `on` tenant | whole tenant skipped | SEC S-1 |
| OQ-4 | Scoped approvers: active users only | yes | SEC S-4 |
| OQ-5 | Should an `on` tenant whose only explicit admins are tokens or flagged service principals be refused? | YES (r2, SEC C-4): fact 4 counts interactive explicit tenant-wide admins only | none |
| OQ-6 | Informational integrity count of installed modules that declare scope | not built | product |
| OQ-7 | `GET /integrity` computes `on_gate` without locks and without audit | yes, labelled snapshot | none |
| OQ-8 | Evidence window when the audit chain has no transition entry (older than retention of audit) | fails closed (`duration` false) | none |
| OQ-9 | Clustered nodes: each node flushes its own ETS; the gate reads the table only | accepted; a second node's unflushed counts only make (b) stricter | none |

# 15. Interplay with open issues

#2832 (tenant-wide FK 500) does not block 519; AC 16 never drives a nonexistent reference as a tenant-wide caller. #2833
(extract handlers from `routers/entities.ex`) and #2834/#2809/#2840 (typing) are independent: 519 changes none of those files and
adds no scope-set producer. #2800 (single source of reasons): 519 adds an accessor, not a copy (F18). The 517 SEC items are all
carried: requests on every day (4.6), per-day counts without N+1 (F11), explicit admin count (4.4), flip preconditions in the D12
lock order A, T, S (4.1).

# 16. Self-review against the brief

* AC-by-AC map: section 7 (22 ACs, each to a design element and a test id).
* No implementation code: signatures and shapes only.
* Slices stated and what needs SEC rulings: sections 1 and 11.
* Conflicts of an AC with the as-built 517/518: F3, F6, F7, F8, F9, F10, F11, F12, F17 with RA-1..RA-9.
* Every claim about the code was read: orientation lines are cited per function; the route census is derived from the committed
  snapshot and the role matrix; the "no `:scope_declarations` in production" claim is from a grep of `lib/` and `priv/` and
  `config/test.exs`; NOT verified by running anything (no `mix`), as instructed.
