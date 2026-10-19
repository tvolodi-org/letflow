# GH #2869 parts (a) and (c): last-interactive-admin guard for an `on` tenant, and the decision-record amendment (REQ-519 GATE)

AGENT: CODE-DESIGNER. Workflow WF-02, run `WF02-REQ519-2869-LASTADMIN-20261019`, step 01. Risk tier HIGH (0004 addendum, ORCHESTRATOR section 13).
Base: `main` 2dfb1233f (REQ-519 2f-a, 2f-b, GH #2883 break-glass merged). Branch `feature/WF02-REQ519-2869-LASTADMIN-20261019`.
Design only: signatures are `@spec`-shaped text, queries and flows are prose, no function bodies, no source blocks. Nothing was run (no `mix`, no tests).

Sources read in full: GH #2869 (body, UPDATE/GATE section, comments); `docs/migration/decisions/0051-...md` D11, A1, A6 to A11; the design
`gh2883-scope-enforcement-break-glass.md` (format, lock order, section 3.13 interface assumptions); `lib/letflow/identity.ex` (`update_locked_user`, `admin_guard`,
`do_remove_group_member`, `do_add_group_member`, `delete_group`, `sync_role_claims_report`, `insert_token`, `revoke_locked_token`, `count_tenant_wide_admins/1`,
`count_explicit_...`, `count_interactive_explicit_tenant_wide_admins/1`, `tenant_wide_admins_query/3`, `lock_tenant_admins!/1`, `record_guard_refused/2`);
`identity/tenant_admin_guard.ex` (whole); `identity/service_principal.ex` (whole); `identity/scoped_grants.ex` (create, delete, make_tenant_wide, lock_writers!);
`identity/role_registry.ex` (`do_upsert_role`, `converge_existing_role`, `move_role`, `rebind_transaction`, `ensure_platform_role_binding`);
`identity/pending_admin_grants.ex` (`revoke`, `last_grant_guard`), `tenant_admin_migration.ex` and `role_scope_grants/backfill.ex` (the `on` branches),
`identity/binding_writers.ex`, `scope_enforcement.ex` (`mode_under_lock!/1`, `lock_tenant_row!/2`), `scope_enforcement/on_gate.ex` (fact 4), the routers that map
the guard error (`routers/identity.ex`, `onboarding.ex`, `tenant_role_scope_grants.ex`), `docs/runbooks/scope-enforcement-on.md`, `docs/roles.md`, and the pins in
`test/letflow/docs/roles_on_flip_docs_test.exs` and `test/letflow/identity/enforced_writers_lock_test.exs` (T-L8). NOT read: the bodies of `Letflow.Scripts` /
`Scripts.Policy` beyond their lock call and moduledoc (classified as non-writers of the admin set, section 3.6, OQ-7).

## Changelog

| Rev | Date (UTC) | Change |
|---|---|---|
| r0 | 2026-10-19 | Initial design. |
| r1 | 2026-10-19 | (internal draft revision before the first gate; no separate content) |
| r4 | 2026-10-19 | CDV r3 FAIL fixed: Gate paragraph keeps `is delivered by GH #2883` (pins :736, :738, :984 unchanged, 10 and 6 row (3)); row (0) claims corrected with a literal A10 needle; F8 tidied; route line refs and T-LA-18(ii) spec note. |
| r3 | 2026-10-19 | SEC r2 folded (T-LA-23 table-driven, R-LA-7, fixture property). CDV r2 FAIL fixed: the `:record_has_an_unexpected_a12` pin named and replaced (F8, 6, T-LA-31); A12 wording narrows A1 (13); service-principal route clause before the catch-all plus set_flag spec (3.8); T-LA-P6 reason case; section 8 P19 claim corrected. |
| r2 | 2026-10-19 | CDV and SEC PASS_WITH_FINDINGS folded: T-LA-18(ii) reworded to one query definition; OQ-7 closed and the refuse/3,4 spec given (3.2); A12 heading reworded (13); T-LA-P4 proves the old-guard-passes premise (F3); MU-LA-9 and T-L8 stated; T-LA-P11a fourth case; OQ decisions recorded (14). |

---

## 0. Findings against the issue text and the as-built code (read first)

* F1. The existing N1 guard (`TenantAdminGuard`) counts with `count_tenant_wide_admins/1` (mode `:counted`) or `count_explicit_tenant_wide_admins/1` (`:explicit`). Both
  count a live TENANT_ADMIN token owner, and `:counted` also counts a member of a zero-row binding and a flagged service principal. So in a tenant with ONE live
  admin token the guard never fires when the last HUMAN admin is removed. That is exactly the #2869 hole. Fact 4 of the `on` gate uses a third counter,
  `count_interactive_explicit_tenant_wide_admins/1` (`:interactive_explicit`, SEC C-4): group half only, a `tenant_wide = true` TENANT_ADMIN row, user active,
  `admin_flagged_service_principal` false. That counter already exists and is the ONE definition this design reuses (D-1).
* F2. The service-principal flag writer (`ServicePrincipal.set_flag/5`) takes lock A but has NO admin guard at all today: flagging the last interactive admin silently
  removes them from the interactive count (the issue says "silently"). It needs a new guard call and a new guard action name.
* F3. In an `on` tenant a rebind of the TENANT_ADMIN binding (`rebind_role/4`) SKIPS the move of grant rows (`{:skipped, :enforced}`, 2e-a). The new group's binding
  has no `tenant_wide` row, so its members are NOT explicit tenant-wide admins even though they are members. The existing N1 guard (`:counted`) still counts them
  (stage-1 rule: a zero-row binding is counted) and does not fire, while the interactive count drops to zero. So rebind is a live path to the lock-out, not only deactivation and member removal.
* F4. "Scoping" cannot lower the interactive count through today's writers. `ScopedGrants.create/3` refuses (`tenant_wide_row_exists`) when the principal already has a
  tenant-wide row, and the interactive predicate needs a `tenant_wide = true` row, which a principal with only scoped rows does not have. The writers that CAN lower it are
  the delete of a tenant-wide TENANT_ADMIN user row (`revoke_tenant_admin_grant`) and the others in the inventory. `create` keeps its existing `:explicit` guard and gets no
  new call (D-6); an invariance test proves the claim (T-LA-P11) and OQ-2 asks whether to add a defensive call anyway.
* F5. Tokens, role-claim sync, delete_group, pending-grant revoke and bind, seeding, TAM, Backfill, `add_group_member`, `make_tenant_wide`, the flip and the break-glass
  cannot lower the interactive count (adds only, memberless group, token half is never counted, or skipped in `on`). They take lock A, are classified one by one in 3.6 and
  each gets ONE test that the count is unchanged or the write is allowed (the positive control of the guard).
* F6. `mode_under_lock!/1` RAISES `ModeUnavailableError` when the mode cannot be read (INV-8, C-1). T-L8 of 2e-a pins "removal never reads the mode: an unreadable tenant still
  lets a removal through". The new guard must read the mode on a removal, so T-L8 changes in a bounded way (D-4, section 6): the mode is read ONLY when a guarded write
  would take the interactive count from above 0 to 0; every other removal still never reads it.
* F7. The refusal event is a pinned contract (`tenant_admin.guard_refused`, six keys, `reason_code` "the only value" `last_tenant_wide_admin`). The new typed 409 needs a second
  `reason_code` value and a second `action` value (`flag_service_principal`). `Identity.record_guard_refused/2` already accepts an optional `reason_code` and a `resource_type`; the
  pinned tests assert the old value only for the old paths (the default stays). The docs of the contract change (3.4).
* F8. `roles_on_flip_docs_test.exs` has three checks that an A12 collides with. (1) The rule at line ~744, `String.contains?(record, "**A12.")` -> `:record_has_an_unexpected_a12`, turns ANY A12 red. (2) The test "decision 0051 holds A11 once, after A10, as Amendment 3, and it is the last paragraph" (lines ~850-860, `refute tail =~ "\n## "`) fails once an Amendment follows A11. (3) The A11 sentence "the last-admin guard (GH #2869 part (a)) stays open and is still required before any customer `on`" is pinned, so A11 cannot be rewritten. Therefore: A12 is APPENDED and A11 is NOT edited (A12 says how that sentence is read once #2869 (a) is implemented); check (1) is REMOVED and replaced, and check (2) becomes "A12 is the last paragraph, A11 precedes it" (section 6), in the SAME PR as the amendment. The amendment text is delivered in section 13 and applied by the builder; it is not written into `docs/migration/` now, because a half-applied edit would turn the existing docs test red.
* F9. Nothing in Letflow can see an IdP-side loss of login for an admin who still exists in the database (gate fact 4 has the same blind spot, break-glass design F9). The guard
  prevents every removal that goes through Letflow; the IdP case remains the job of the #2883 break-glass. The design says so in the runbook and the record; it adds no eighth `LIMIT-*` item (AC 23 pins seven).
* F10. No web change: `web/src` has no handler for `last_tenant_wide_admin` (grep). The new 409 code reaches the SPA as a generic conflict like the old one.

## 1. PR split and boundary

ONE PR. Size: one shared helper pair in `TenantAdminGuard`, one new counter clause, six call sites (five existing guarded paths plus the service-principal writer), seven router mappings, one new
data-only inventory module and its scan, docs, tests. No migration. No new lock. No new route. In scope: part (a) the guard and part (c) the record text. Out of scope: part (b) (delivered by #2883), any change
to `flip/4`, `flip_out_of_band/3`, the gate, `ShadowWindow`, the break-glass runbook procedure, the token break-glass of A7, the existing N1 guard's behaviour for the old counters, the IdP.

Gate: after this PR (a) and (c) AND #2883 are on `main`, the "no `on` flip in any customer tenant" gate of REQ-519 AC 24 may be lifted by the supervisor. This PR alone is the second half. The PR body repeats: "NO production tenant is set to on until the supervisor says so".

## 2. Decision summary

| Id | Decision | Default built | Needs |
|---|---|---|---|
| D-1 | Predicate | the guard counts with `Identity.count_interactive_explicit_tenant_wide_admins/1`, reached through the guard's existing `counter` seam as a third value `:interactive_explicit`. NO copy of the query; `tenant_wide_admins_query/3` keeps ONE `:interactive_explicit` clause used by the gate (fact 4) and the guard | SEC S-LA1 |
| D-2 | Rule | TRANSITION rule: refuse when the interactive count is above 0 before the write and 0 after it, AND the tenant is stored `on`. A tenant already at 0 is not refused (adds and unrelated writes stay possible; this is also the recovery shape) | OQ-4 |
| D-3 | Order with the old guard | the existing N1 guard runs first and keeps its error `last_tenant_wide_admin`; the new guard runs second and answers `last_interactive_tenant_wide_admin`. Both hit zero at once: the old code wins | none |
| D-4 | Mode read | `ScopeEnforcement.mode_under_lock!/1`, AFTER lock A, only in the one case that would refuse (before > 0, after == 0). A raise rolls the whole call back (fail closed, INV-8). Stored `shadow` or `off`: allowed | SEC S-LA2 |
| D-5 | Error shape | function `{:error, :last_interactive_tenant_wide_admin}`; HTTP 409 code `last_interactive_tenant_wide_admin`; event `tenant_admin.guard_refused` with `reason_code` `"last_interactive_tenant_wide_admin"` (the six keys unchanged), written in its own transaction after the rollback by the existing `refuse/3,4` | OQ-1, SEC S-LA3 |
| D-6 | Where it applies | six guarded sites: deactivation, group-member removal, TENANT_ADMIN unbind (kind change), TENANT_ADMIN rebind, revoke of a tenant-wide TENANT_ADMIN grant row, service-principal flagging. All other lock-A sites are classified and tested (3.6) | SEC S-LA4 |
| D-7 | Lock order | unchanged: A first, then R where the path has it, then the path's own rows, then the plain counts and the plain mode read, then C. No new lock, no lock above A, the `tenants` row is READ never locked by a guarded writer | none |
| D-8 | Break-glass and flip | untouched. Neither is special-cased; both change no admin row. After a break-glass the mode is `shadow` or `off` and the guard no longer applies | none |
| D-9 | Completeness | a data-only inventory `Letflow.Identity.LastAdminPaths` of every call site of `lock_tenant_admins!/1` in `lib/`, with a scan that fails on an unclassified site | SEC S-LA5 |
| D-10 | Record | Amendment 4 of 0051, A12, appended; A11 untouched (F8) | SEC S-LA6 |

## 3. Design

### 3.1 Module map

| Module / file | New or changed | Role |
|---|---|---|
| `lib/letflow/identity/tenant_admin_guard.ex` | CHANGED | `counter()` gains `:interactive_explicit`; new `ensure_interactive_admin_remains!/4`; `action()` gains `:flag_service_principal`; `refusal` gains optional `reason_code`; `refuse/3,4` writes the refusal's own `reason_code` and returns the matching error atom |
| `lib/letflow/identity.ex` | CHANGED | `update_locked_user`: before-count and a second guard step; `do_remove_group_member`: second guard call; specs gain the new error. `tenant_wide_admins_query/3` and the three public counters UNCHANGED |
| `lib/letflow/identity/role_registry.ex` | CHANGED | `converge_existing_role` (unbind) and `move_role` (rebind): before-count and second guard call; specs |
| `lib/letflow/identity/scoped_grants.ex` | CHANGED | `delete/3`: before-count and second guard call; `write_error` gains the new atom |
| `lib/letflow/identity/service_principal.ex` | CHANGED | `do_set_flag/5`: guard on `flagged == true`; `set_result` gains the new error; the refusal is recorded after the rollback |
| `lib/letflow/identity/last_admin_paths.ex` (`Letflow.Identity.LastAdminPaths`) | NEW, data only | the inventory of 3.6 (the shape of `BindingWriters`) |
| `lib/letflow/routers/identity.ex`, `tenant_role_scope_grants.ex` | CHANGED | map the new atom to 409 (3.8) |
| `lib/letflow/scope_enforcement.ex`, `flip/4`, `flip_out_of_band/3`, `OnGate`, `ShadowWindow`, `Release.ScopeBreakGlass` | UNCHANGED | |
| docs | CHANGED | section 10 |

### 3.2 The shared predicate (S-LA1)

The definition of an interactive explicit tenant-wide admin lives in ONE place: the `:interactive_explicit` clause of the private `tenant_wide_admins_query/3` in `identity.ex` (active user, member of the group the
`TENANT_ADMIN` `:platform_role` binding points to, a `tenant_wide = true` TENANT_ADMIN row for the user or the bound group, `admin_flagged_service_principal` false, no token half). Gate fact 4 reaches it through
`count_interactive_explicit_tenant_wide_admins/1`; the guard reaches it through the SAME public function, via the guard's private `count/2` seam (new clause for `:interactive_explicit`). The guard never builds its
own query and never reads `users`, `group_members` or grants itself. A divergence test (T-LA-17) and two scans (T-LA-18) pin that the gate and the guard cannot disagree.

```
Letflow.Identity.TenantAdminGuard
  @type counter :: :counted | :explicit | :interactive_explicit        # one new member
  @type action :: ... | :flag_service_principal                         # one new member
  @type refusal :: %{action: action(), target_id: String.t(), counted_admins: non_neg_integer(),
                     optional(:reason_code) => String.t()}              # absent means "last_tenant_wide_admin"
  @spec ensure_interactive_admin_remains!(prefix :: String.t(), action(), target_id :: String.t(),
                                          before_count :: non_neg_integer()) :: :ok
    # inside a transaction holding lock A (raises ArgumentError outside one, like its siblings).
    # before_count == 0: :ok (the write removed nobody). Otherwise count_interactive after the write; above 0: :ok.
    # Zero: read ScopeEnforcement.mode_under_lock!(prefix); :on -> Repo.rollback({:tenant_admin_guard, refusal}) with
    # counted_admins 0 and reason_code "last_interactive_tenant_wide_admin"; :shadow or :off -> :ok.
    # A raise from the mode read propagates (rollback, fail closed).
  # before count: the EXISTING count_before!(prefix, :interactive_explicit), taken at the same point as the path's other before-count.
  # refuse/3,4 return type becomes
  #   @spec refuse(prefix, refusal(), AuditContext.t()[, [refuse_opt()]]) ::
  #           {:error, :last_tenant_wide_admin | :last_interactive_tenant_wide_admin}
  # the second atom exactly when the refusal carries reason_code "last_interactive_tenant_wide_admin", else the first.
```

### 3.3 The rule and why

* Refuse only in a tenant stored `on`. In `shadow` and `off` nothing is denied by grants, so no one can be locked out of the flip route by losing the last human admin who has an explicit row (a human with only
  a zero-row membership is denied only under `on`). Gate fact 4 protects the entry into `on`; this guard protects the life in `on`. A `shadow` tenant that loses its last interactive admin is refused at the next `shadow -> on` flip by fact 4. (OQ-3.)
* Transition rule, not state rule (D-2): a write that does not take the count from above 0 to 0 is never refused by this guard. So an `on` tenant that is ALREADY at zero (fact 4 prevents entering `on` at zero, but a tenant flipped before this
  guard shipped may have been emptied since) can still add admins, fix the binding and deactivate unrelated users. That keeps the recovery moves open.
* Counted after the write, in the same transaction, under lock A: concurrent writers serialise on A, so two removals of the last two admins cannot both pass (T-LA-24).
* "Last" means the last INTERACTIVE explicit admin. A live TENANT_ADMIN token owner, a flagged service principal and a zero-row member do not save the removal (they cannot flip). This is the point of the guard.

### 3.4 Error shape (typed 409 in the style of `last_admin_binding_row`)

| Layer | Value |
|---|---|
| function | `{:error, :last_interactive_tenant_wide_admin}` from `update_user_status/3`, `update_user_profile/3` (status write), `remove_group_member/3`, `RoleRegistry.upsert_role/4` and `upsert_role_report/4`, `rebind_role/4` and `rebind_role_report/4`, `ScopedGrants.delete/3`, `ServicePrincipal.set_flag/5` |
| HTTP | 409 `{"error": ... "last_interactive_tenant_wide_admin"}` through `Response.conflict/2`, same envelope as `last_tenant_wide_admin` |
| event | `tenant_admin.guard_refused`: `after_state` keys EXACTLY `"action"`, `"actor"`, `"target_id"`, `"reason_code"`, `"counted_admins"`, `"trace_id"`; `reason_code` is now one of two values; `action` gains `flag_service_principal`; `resource_type` for it is `"user"`; `counted_admins` is 0 |
| recording | the existing `refuse/3,4` writes it in its OWN transaction after the guarded rollback (the refused change and its audit entry stay rolled back), best-effort, one constant log line on failure (existing behaviour, INV-4: no ids beyond the entry) |

`update_locked_user` records through `record_guard_refused/2` directly today; the new step passes `reason_code` and `resource_type` "user" there (the two optional keys exist). The pinned-contract docs and the three
moduledocs that say "the only value" are updated (section 10). The old paths' refusals are byte-identical (the default `reason_code`).

### 3.5 Lock order (D-7)

Global ranks (REQ-519 design 3.7): **A** < R < G < N < B < T < S < C. Guarded writers keep their order: A, then R (the TENANT_ADMIN binding row) where the path takes it, then their own rows (user, group `KEY SHARE`/`FOR UPDATE`,
role row, grant row), then the before-count (plain read), the write, the existing guard, the new guard (plain count, plain `tenants` PK read), then C (the path's audit entry). The `tenants` row is READ, never locked, by a guarded
writer, so there is no new edge and nothing above A. `flip/4` (A, T, S, C) and the break-glass (A, T, C) take A first, so a guarded writer and a flip serialise on A: whichever commits first is seen by the other
(the mode read is final after A, `mode_under_lock!/1` doc). The mode is read AFTER A (the break-glass 3.13 assumption): a guarded writer that wins A first is judged against `on`; one that wins A after a break-glass commit sees `shadow`/`off` and is allowed.
`lock_timeout` is not touched: the guard adds no wait.

### 3.6 Inventory: every write path that takes lock A (S-LA4, S-LA5)

23 call sites of `Identity.lock_tenant_admins!/1` in `lib/` (the definition excluded). Classification: G = guarded by this design; N = takes A, cannot lower the interactive count, positive control test; X = not a writer of the
admin set. The inventory module `Letflow.Identity.LastAdminPaths` carries one row per site `{file, function, arity, class, action | reason}`; the scan (T-LA-30) compares the multiset of `{file, function}` call sites to it.

| Id | Site (file : function) | What it writes | Class and how the guard applies | Test |
|---|---|---|---|---|
| P1 | `identity.ex` : `update_locked_user` (via `update_user_status/3` and `update_user_profile/3` with a `status` key) | user status; revokes the user's tokens | G, action `deactivate_user`. Before-count (`:interactive_explicit`) next to `admins_before`; new Multi step after `:admin_guard` | T-LA-P1 (+ P1b entry point profile+status) |
| P2 | `identity.ex` : `do_remove_group_member` | deletes a membership | G, action `remove_tenant_admin_member`. Only when the group is the group the TENANT_ADMIN platform binding points to (the existing `admin_group_id` check). Before-count next to the existing one; guard after the existing `ensure_admins_remain!` | T-LA-P2 |
| P3 | `role_registry.ex` : `do_upsert_role` / `converge_existing_role` (kind change of the TENANT_ADMIN platform binding away from platform) | binding kind, grant rows | G, action `unbind_tenant_admin`. Same trigger as `unbind_before_count/3`; second guard after `guard_unbind_tenant_admin/3` | T-LA-P3 |
| P4 | `role_registry.ex` : `rebind_transaction` / `move_role` (TENANT_ADMIN platform binding moved to another group) | binding group, grant rows (skipped in `on`, F3) | G, action `rebind_tenant_admin`. The case the old guard cannot see: members of the new group with no row | T-LA-P4 |
| P5 | `scoped_grants.ex` : `delete/3` (a tenant-wide TENANT_ADMIN row; the delete of a group's sole tenant-wide row is already `last_admin_binding_row`, A7, checked first) | one grant row | G, action `revoke_tenant_admin_grant`, same `guarded?` condition as the existing `:explicit` guard; second guard after it | T-LA-P5 |
| P6 | `service_principal.ex` : `do_set_flag` with `flagged == true` and a changed value | user flag | G, NEW action `flag_service_principal`. Order inside the transaction: A, the user row `FOR UPDATE`, before-count, update, guard, audit. Unflag and no-op writes are not guarded (they add or change nothing) | T-LA-P6 |
| P7 | `identity.ex` : `do_add_group_member` | inserts a membership | N (adds; the recovery move). Positive control: in an `on` tenant at zero interactive admins, adding a member to the admin group is allowed and restores the count; an add never reduces it | T-LA-P7 |
| P8 | `identity.ex` : `delete_group/2` | deletes a MEMBERLESS group and its group-principal grant rows | N: a group with a member is refused (`not_found_or_has_members`), the bound admin group cannot be deleted (FK, `bound_to_role`); the count cannot change | T-LA-P8 |
| P9 | `identity.ex` : `sync_role_claims_report/3` (also `sync_role_claims_from_token/3`) | inserts memberships, never removes | N: adds only; in `on` a widening membership is suppressed. A claim that disappears from a later token removes nothing | T-LA-P9 |
| P10 | `identity.ex` : `insert_token` (`create_token/3`, `mint_token/4`) | token rows | N: tokens are never in the interactive count; minting leaves it unchanged (one test through `mint_token/4`, one through `create_token/3`) | T-LA-P10a, P10b |
| P11 | `scoped_grants.ex` : `lock_writers!` (`create/3` = scoping, `make_tenant_wide/3`) | inserts/replaces grant rows | N: `create` cannot lower the count (F4): a scoped row is refused for any principal that holds a tenant-wide row, and a principal without one was not explicit; `make_tenant_wide` only adds. Existing `:explicit` guard on `create` stays | T-LA-P11a (create), P11b (make_tenant_wide) |
| P12 | `identity.ex` : `revoke_locked_token` (`revoke_token/2`) | revokes one token | N for this guard (tokens never counted); the existing state-rule guard (`revoke_token`) is unchanged | T-LA-P12 |
| P13 | `pending_admin_grants.ex` : `revoke/3` | revokes a PENDING grant (not a member) | N: a pending grant is not an interactive admin; the existing `last_grant_guard` is unchanged | T-LA-P13 |
| P14 | `pending_admin_grants.ex` : `transact_bind` (`bind_on_login/5`) | adds the TENANT_ADMIN membership | N (adds; a recovery move: a pending grant bound at first login restores an interactive admin) | T-LA-P14 |
| P15 | `role_registry.ex` : `ensure_platform_role_binding` (seeding) | creates/repairs a binding, never removes | N: no admin removed; in `on` creates no row | T-LA-P15 |
| P16 | `tenant_admin_migration.ex` : `real_tenant` | copies members, removes the legacy PLATFORM_ADMIN binding | N: the whole plan is skipped in `on` (`mode_under_lock!/1`, 2e-a) | T-LA-P16 |
| P17 | `role_scope_grants/backfill.ex` : `repair_tenant` | inserts missing group rows | N: skipped in `on`; adds only otherwise | T-LA-P17 |
| P18 | `scope_enforcement.ex` : `lock_tenant_row!` (`flip/4`, `flip_out_of_band/3`) | the flag and its audit entry | X: writes no admin row (break-glass design 3.13, T-BG-7). NOT special-cased | T-LA-26 |
| P19 | `scripts/policy.ex` : `solo_gate`, `set_sod`, `set_platform_solo_audited`; `scripts.ex` : `publish_transaction`, `confirm` (5 sites) | policy rows and script publication; they READ the counted-admin count | X: no write to users, groups, memberships, bindings, grants or tokens. Classified from their moduledoc and lock calls; OQ-7 | scan T-LA-30 |

Writers that do NOT take lock A and cannot reduce the count: `create_user`, `provision_oidc_user`, `update_user_profile` without a `status` key, group creation and rename, `PendingAdminGrants.create`. There is no user delete and no
hard delete of memberships outside P2 and P8 (`delete_all`/`Repo.delete` survey of `lib/`: only `role_scope_grants.ex` delete-by-id, the TAM legacy binding delete in P16, and the P2/P8 deletes).

Any future writer that takes lock A must be added to the inventory (scan T-LA-30), which forces a class and, for G, a guard call.

### 3.7 How the guard applies in each guarded path (sequences, prose)

Common frame for P2 to P5: the path's existing transaction; the new before-count is the existing `count_before!/2` with `:interactive_explicit`, taken right next to the path's existing before-count (under A and the
row locks, before the write); after the existing guard call, `ensure_interactive_admin_remains!/4`; a refusal is `Repo.rollback({:tenant_admin_guard, refusal})`, the public function calls `TenantAdminGuard.refuse/3,4`
after the rollback and returns `{:error, :last_interactive_tenant_wide_admin}`. The before-count is skipped where the path already skips its own (non-admin group in P2, other roles in P3/P4/P5).

* P1. `update_locked_user` is a Multi. A new step `:interactive_before` runs next to `:admins_before` (status writes only: the request carries `status`). After `:admin_guard`, a new step
  `:interactive_guard` runs only when the updated user is `:inactive` (reactivation and non-status writes cannot lower the count). On refusal the Multi error `{:error, :interactive_guard, {:last_interactive_tenant_wide_admin, 0}, _}` is mapped to
  `record_guard_refused(prefix, %{action: "deactivate_user", reason_code: "last_interactive_tenant_wide_admin", ...})` and `{:error, :last_interactive_tenant_wide_admin}`. The token revocation of the same transaction rolls back with it.
* P3 and P4 follow the existing `unbind_before_count/3` and `move_role` triggers (only the TENANT_ADMIN `:platform_role` binding). P4 is the F3 case and needs a dedicated test shape (members of the new group, no row).
* P5: the new guard applies when `row.role == TENANT_ADMIN and row.tenant_wide`, the existing `guarded?`. For a user-principal row the count drops only when the user relies on that row (zero-row group); for a group
  row the delete is already `last_admin_binding_row`.
* P6: `ServicePrincipal.set_flag/5` returns `{:error, :last_interactive_tenant_wide_admin}`; the transaction wrapper there gains the post-rollback `refuse` call with `ctx = %{actor_id: actor.user_id, trace_id: actor.trace_id}`; `reason` is validated first
  (unchanged order), so a refused flag does not leak whether the user exists beyond today's behaviour.
* What the guard does NOT do: it never blocks the add of an admin, never reads the tokens, never consults the break-glass, never writes anything on its own except the post-rollback refusal event.

### 3.8 HTTP mapping (S-LA3)

Every router branch that maps `{:error, :last_tenant_wide_admin}` gains a sibling for the new atom with the SAME status and a fixed code (no ids in the body):

| Route | File / function | New mapping |
|---|---|---|
| `PATCH /users/:id` (status key) | `routers/identity.ex` (~480) | 409 `last_interactive_tenant_wide_admin` |
| `POST /users/:id/status` | `routers/identity.ex` (~529) | same |
| `DELETE /groups/:id/members/:user_id` | `routers/identity.ex` (~861) | same |
| `POST /roles` (kind change) | `routers/identity.ex` (~1112) | same |
| `POST /roles/:id/rebind` | `routers/identity.ex` (~1159) | same |
| `DELETE` grant row | `routers/tenant_role_scope_grants.ex` (`@conflicts` list) | add the atom to the list |
| `PUT /users/:id/service-principal` | `routers/identity.ex` (~767) | NEW clause `{:error, :last_interactive_tenant_wide_admin}` placed BEFORE the catch-all `{:error, _server_fault}` at `routers/identity.ex` (~786), or the refusal would surface as a 500. Specs: `ServicePrincipal.set_flag(user_id, flagged :: boolean(), reason :: term(), actor(), prefix :: String.t()) :: {:ok, %{user_id: Ecto.UUID.t(), flagged: boolean(), changed: boolean()}} \| {:error, :not_found \| :reason_required \| :invalid_reason \| :last_interactive_tenant_wide_admin \| {:audit_failed, term()} \| {:transaction_failed, Exception.t()}}` (the `set_result` type gains the one atom) |

Not mapped (no new guard): `DELETE /tokens/:id` (P12), pending-grant revoke in `routers/onboarding.ex` (P13), token mint. A router test per mapped route (T-LA-H1..H7) asserts the status and the code and that the body names no id.

### 3.9 Interplay with the break-glass (#2883), the flip, the gate and A7

* Break-glass: unaffected and not special-cased. It changes only the flag (T-BG-7) and takes A first. It is the recovery for the one thing the guard cannot see (F9): an admin who exists in the database but cannot log in. After an `on -> shadow` break-glass
  the guard no longer applies; after the IdP is repaired the normal route flips again (gate fact 4, new window). A guarded writer racing a break-glass serialises on A (T-LA-26).
* Flip: `shadow -> on` and a removal serialise on A. Flip first: the removal sees `on` and is refused if it empties the count. Removal first: fact 4 sees the lower count and refuses the flip (T-LA-25).
* Gate fact 4 and the guard use the same predicate (D-1): a tenant that passed the gate with N interactive admins cannot reach zero through Letflow without a refusal.
* A7 (tokens as the break-glass for GRANT writes, 0051): it covers this case only PARTLY. A token with TENANT_ADMIN can still write grants and memberships, so in a token-only tenant it can ADD an interactive admin again (P7 positive control).
  It can NOT flip the flag (A8: the flip route is interactive-only), so a token cannot turn enforcement off. With the guard, a token-only `on` tenant is unreachable through Letflow; through an IdP loss it is reachable and only #2883 recovers the flag. A12 records exactly this (13).
* Pending admin grants (0048) stay a recovery move: P14.

### 3.10 Failure behaviour (INV-8)

| Condition | Result |
|---|---|
| guarded write would take the interactive count 1+ to 0, tenant stored `on` | rollback, `{:error, :last_interactive_tenant_wide_admin}`, refusal event in its own transaction (best effort), HTTP 409 |
| same, tenant stored `shadow` or `off` | allowed |
| same, but the mode cannot be read (`ModeUnavailableError`) | the whole call rolls back and returns the path's existing server-fault shape (`{:transaction_failed, e}` / 500, detail-free); never allowed, never a refusal |
| before-count is 0 | the guard is a no-op |
| the count query raises | the existing rescue of the path: rollback, `{:transaction_failed, e}` |
| refusal event cannot be written | one constant log line, the refusal stands (existing `refuse/4` behaviour) |
| both guards would fire | `last_tenant_wide_admin` (D-3) |

### 3.11 Multi-node, performance

The guard is a pure database check under a Postgres advisory transaction lock (global across nodes); no node-local state. Cost: one extra count query before and one after a guarded write (the before-count is skipped where the path's own precondition is false),
one `tenants` PK read only in the refusing case. Guarded writes are rare admin acts.

## 4. Data model

No migration, no table, column, index or constraint. `tenant_admin.guard_refused` entries gain a second `reason_code` value in an existing JSON `after_state` key.

## 5. Tests (TEST-DESIGNER writes them; ids are the contract)

Files: `test/letflow/identity/last_interactive_admin_guard_test.exs` (DB, `async: false`: committed writes, advisory locks, a stored `on` tenant by test-only SQL in the fixture, an audit fault trigger),
`test/letflow/identity/last_admin_paths_test.exs` (scan), `test/letflow/routers/last_interactive_admin_routes_test.exs` (HTTP), the docs test of section 6. Fixture "last interactive": a real tenant schema stored `on` (`OnGateFixture`/`EnforcedWritersFixture`
style) with EXACTLY one interactive explicit admin A1, plus a live TENANT_ADMIN token owned by a second active user T1 (so the OLD guard would pass), and one flagged service principal S1 and one zero-row member Z1 where a test needs them.
Tests that read the mode run on a real `tenants` row (the lenient test key answers `:off` for a synthetic prefix, so a synthetic-prefix test would hide the guard; the fixture asserts the stored mode is `on`).

Fixture property (SEC): the per-path tests for P3, P5 and P6 (and P1, P2) rely on a live TENANT_ADMIN token owner existing in the fixture, so the OLD counted guard would pass and only the new guard can refuse; a fixture without it would make the test vacuous.

Per-path tests (ONE per path of 3.6; each asserts the refusal type, that NOTHING changed (rows, flag, tokens), that one `tenant_admin.guard_refused` entry exists with the six keys and the new `reason_code`, and, for the G rows, that the same call with a SECOND interactive admin present succeeds):

| Id | Path | Test |
|---|---|---|
| T-LA-P1 | P1 | `update_user_status(A1, :inactive)` in the last-interactive fixture: `{:error, :last_interactive_tenant_wide_admin}`; A1 still active; A1's tokens not revoked; entry action `deactivate_user`. P1b: the same through `update_user_profile` with `status` |
| T-LA-P2 | P2 | `remove_group_member(admin group, A1)`: refused; membership present; entry action `remove_tenant_admin_member`; removing T1's non-admin-group membership is allowed |
| T-LA-P3 | P3 | `upsert_role("TENANT_ADMIN", :process_routing_role, bound group)`: refused; binding kind unchanged; entry `unbind_tenant_admin` |
| T-LA-P4 | P4 | `rebind_role` of the TENANT_ADMIN binding to a group G2 with members but NO tenant-wide row (the F3 shape). The test FIRST proves the premise in the same fixture: after the move `count_tenant_wide_admins/1` (what the old guard measures) is above 0 for G2's members, so the old guard passes, while `count_interactive_explicit_tenant_wide_admins/1` is 0; then the call is refused by the new guard; binding unchanged; entry `rebind_tenant_admin`. Plus the same rebind in a `shadow` tenant is allowed |
| T-LA-P5 | P5 | zero-row admin group where A1's only explicit basis is his tenant-wide USER row: `ScopedGrants.delete` of that row: refused; row present; entry `revoke_tenant_admin_grant`. The delete of a group's sole tenant-wide row still answers `last_admin_binding_row` (the older rule wins, order check) |
| T-LA-P6 | P6 | `ServicePrincipal.set_flag(A1, true, reason, actor)`: refused; flag still false; NO `service_principal.flagged` entry; guard entry action `flag_service_principal`; unflagging S1 and re-flagging a non-admin user are allowed. Reason case (MU-LA-20): with A1 (the last interactive admin) as target, a missing reason, a blank reason and an invalid reason (control characters) each answer `:reason_required` / `:invalid_reason` and NOT the guard error, write no guard entry, and a valid reason then gets the guard refusal |
| T-LA-P7 | P7 | on a fixtured `on` tenant at ZERO interactive admins: `add_group_member(admin group, U)` succeeds and the interactive count becomes 1; with admins present an add never changes another member |
| T-LA-P8 | P8 | `delete_group` of a memberless group leaves the interactive count unchanged; the bound admin group is refused (`bound_to_role`) |
| T-LA-P9 | P9 | role-claim sync for A1 with a token whose claims no longer include the admin role: A1 still a member, count unchanged; a sync that would add a member in `on` is suppressed (existing) |
| T-LA-P10a / P10b | P10 | `mint_token` for T1 and `create_token` for A1: interactive count unchanged before and after |
| T-LA-P11a | P11 | `ScopedGrants.create` of a scoped TENANT_ADMIN row for A1 (has a tenant-wide row, refused `tenant_wide_row_exists`), for a user without rows, and for a group with no rows: in all three shapes the interactive count is equal before and after. Fourth case (SEC OQ-2): a user who is a member of the admin group is SCOPED (a scoped TENANT_ADMIN row for that user) while the admin group holds the tenant-wide row: the user stays an interactive explicit admin (group row suffices), count unchanged |
| T-LA-P11b | P11 | `make_tenant_wide` never lowers the count |
| T-LA-P12 | P12 | `revoke_token` of T1's token: allowed, interactive count unchanged; existing token guard unchanged |
| T-LA-P13 | P13 | revoking the last PENDING grant while A1 exists: allowed, count unchanged |
| T-LA-P14 | P14 | `bind_on_login` for a pending grant in an `on` tenant at zero interactive admins restores one |
| T-LA-P15 | P15 | platform-role seeding in `on`: no admin removed, count unchanged |
| T-LA-P16 | P16 | `TenantAdminMigration` on the `on` tenant: `skipped_enforced`, count unchanged |
| T-LA-P17 | P17 | `Backfill.run` on the `on` tenant: skipped, count unchanged |

Cross-cutting:

| Id | Test |
|---|---|
| T-LA-17 | divergence: for a matrix of shapes (explicit member, zero-row member, token owner only, flagged principal, inactive user, scoped-only holder, two admins) `OnGate` fact 4 input and the guard's before-count are equal for every shape (same function) |
| T-LA-18 | two scans: (i) the guard module contains no query of `users`, `group_members`, `tenant_role`, `role_scope_grants` or `api_tokens`; its interactive count goes through `count_before!`/`count/2` to `count_interactive_explicit_tenant_wide_admins`; (ii) ONE query definition: `identity.ex` defines the interactive-explicit predicate in exactly one query builder (`tenant_wide_admins_query/3`); the atom `:interactive_explicit` may occur there at its mode branches (the `case mode` branch and the holder filter, today two occurrences) and in the public counter and its @spec (ignored by the pin), but no second function builds a `users`/`group_members`/`tenant_role` query for it. The pin is on the number of query builders, not on atom occurrences, so it passes on unmodified code. Each proven live on a seeded offender |
| T-LA-19 | token and flag do not save: the fixture variants (only a live TA token owner left besides A1; only a flagged principal left; only a zero-row member left) all refuse the removal of A1 on P1 and P2 (the rest follows from the per-path tests) |
| T-LA-20 | mode matrix, table-driven over P1..P6: stored `shadow` and stored `off` allow the same write; `on` refuses |
| T-LA-21 | second admin matrix, table-driven over P1..P6: with two interactive admins, removing one succeeds in `on`; removing the second is then refused |
| T-LA-22 | precedence: with no token and no other counted admin both rules hit zero; the error is `last_tenant_wide_admin` and the event `reason_code` the old value (one entry, not two) |
| T-LA-23 | fail closed, TABLE-DRIVEN over ALL six guarded paths P1..P6 (SEC F-1): renaming the public `tenants` table inside the transaction makes the mode read raise; each path, called so that it would empty the count, returns its detail-free server-fault shape (`{:error, {:transaction_failed, e}}` and HTTP 500, no id, no message) and changes nothing. The builder VERIFIES that each path has an existing rescue around its transaction (read on main: `update_locked_user`, `remove_group_member`, `do_upsert_role`, `rebind_role_report`, `ScopedGrants.run` (covers delete), `ServicePrincipal.set_flag` all rescue to `{:transaction_failed, e}`; no new rescue is needed) and this test pins it; a removal that leaves a second admin never reads the mode and succeeds (the bounded T-L8) |
| T-LA-24 | concurrency: two admins A1, A2, both removed concurrently (committed state, real held lock A): exactly one commits, the other is refused |
| T-LA-25 | flip race: removal of the last admin versus `shadow -> on` and `on -> shadow` flips, queue order detected through `pg_locks`: no interleaving leaves `on` with zero interactive admins |
| T-LA-26 | break-glass: after `flip_out_of_band(on -> shadow)` the same removal succeeds; the break-glass on the last-interactive fixture still succeeds and writes no admin row (T-BG-7 shape) |
| T-LA-27 | event shape: the new entry has exactly the six keys, `reason_code` new value, `counted_admins` 0 (SEC F-2: no id of any other principal), actor and trace from the context; old paths' entries keep `last_tenant_wide_admin` |
| T-LA-28 | audit fault: with the refusal-event write failing the refusal still stands and one constant log line is written; the guarded change is rolled back |
| T-LA-29 | recovery: in an `on` tenant at zero interactive admins (fixtured), a token TENANT_ADMIN can add a member (restores), cannot flip (403), and the break-glass flips it down |
| T-LA-30 | completeness scan: the multiset of `{file, function}` call sites of `lock_tenant_admins!` in `lib/` equals `LastAdminPaths` (23 sites); a seeded unclassified call site fails; every G row names a function that exists and calls `ensure_interactive_admin_remains!`; no N or X row does |
| T-LA-H1..H7 | HTTP: each mapped route of 3.8 returns 409 `last_interactive_tenant_wide_admin` in the fixture, and the old code in the old-guard case; the body names no id and carries no count (SEC F-2) |
| T-LA-31 | docs: the runbook and `roles.md` paragraphs of section 10; the `:record_has_an_unexpected_a12` rule is gone and replaced (section 6 row (0)): A12 exactly once, after A11, last in 0051, A11 byte-unchanged, A10 unedited, A12 states it NARROWS A1's wording to the implemented gate counter; seeded bad documents (A12 twice, A12 before A11, A11 edited) each fail |

## 6. Existing tests that change, and scans

| File | Change |
|---|---|
| `test/letflow/identity/enforced_writers_lock_test.exs` T-L8 | the unreadable-tenant removal case is split: a removal that leaves a second interactive admin still never reads the mode and passes; a removal that would empty the count raises and rolls back (T-LA-23). The test must not be weakened otherwise |
| `test/letflow/identity/tenant_admin_guard_test.exs`, `tenant_admin_guard_scoped_test.exs`, `gh2564_deactivation_revokes_tokens_test.exs`, `tenant_role_scope_grants_test.exs` | re-run unchanged; where one asserts "the only reason_code value" the assertion is narrowed to "the default for the old paths". Fixtures in these files use synthetic prefixes (lenient mode `:off`) so the new guard is inert there |
| `test/letflow/docs/roles_on_flip_docs_test.exs` | (0) BLOCKING: the rule `{String.contains?(record, "**A12."), :record_has_an_unexpected_a12}` (line ~744) is REMOVED (it is the only occurrence; there is no seeded-bad-document counterpart) and replaced by: `**A12.` occurs exactly once; A12 comes after A11; A11 (`**A11. Operator break-glass for the flag.**` once, with its pinned sentences) is unedited; A10 is unedited: the literal `**A10. Known gap, tracked.**` occurs once, followed by the needle `an `on` tenant can lose the last interactive TENANT_ADMIN and have no way to turn enforcement off`; A12 only says A10 stays open until the implementation is on `main`; no `**A13.`. (1) "decision 0051 holds A11 once, after A10, as Amendment 3, and it is the last paragraph" (lines ~850-860, `refute tail =~ "\n## "`) becomes "A11 once as Amendment 3, then A12 once as Amendment 4, A12 is the last paragraph"; (2) the A11 pinned sentence stays (A11 is not edited); (3) the Gate-paragraph pins at :736 and :738 and the seeded mutation at :984 are UNCHANGED (the rewritten paragraph keeps `is delivered by GH #2883`); ADDED claims: the paragraph contains `last_interactive_tenant_wide_admin` and `the guard cannot see an administrator who exists in Letflow` and no longer contains `(still open)`, in both documents, plus the A12 claims of section 13. The item count (eight) and the seven `LIMIT-*` items are untouched |
| `test/letflow/identity/binding_writers_*` | no change expected (the inventory is a new module) |
| `mix letflow.check_boundaries`, `mix letflow.permission_matrix --check`, route snapshots | must stay green: no route or permission is added |

## 7. Mutants (the suite must kill each)

| Id | Mutation | Killed by |
|---|---|---|
| MU-LA-1 | the guard counts with `:counted` or `:explicit` instead of `:interactive_explicit` | T-LA-19, T-LA-P4 |
| MU-LA-2 | a private copy of the interactive query in the guard | T-LA-17, T-LA-18 |
| MU-LA-3 | the guard skipped in one path (each of P1 to P6, one mutant per path) | T-LA-P1..P6 |
| MU-LA-4 | the guard runs before the write (predicted, not measured) or the before-count is taken after the write | T-LA-P1..P6, T-LA-21 |
| MU-LA-5 | state rule instead of transition rule (refuses at before == 0) | T-LA-P7, T-LA-29 |
| MU-LA-6 | refuses in `shadow` or `off` | T-LA-20 |
| MU-LA-7 | mode read BEFORE lock A or with a row lock on `tenants` | T-LA-25, lock-order assertion in T-LA-24 |
| MU-LA-8 | a failed mode read treated as `:off` (fail open) | T-LA-23 |
| MU-LA-9 | the mode read on every removal (breaks the bounded T-L8; T-L8 stays asserted: a removal that leaves a second interactive admin NEVER reads the mode, even for an unreadable tenant) | T-LA-23, T-L8 |
| MU-LA-10 | new guard before the old one (error precedence swapped) | T-LA-22 |
| MU-LA-11 | refusal event with the old `reason_code`, extra keys, or an id of the target's tokens | T-LA-27 |
| MU-LA-12 | refusal event written inside the rolled-back transaction | T-LA-P1, T-LA-28 |
| MU-LA-13 | refusal recorded as success (change persists) or the token revocation of P1 survives the rollback | T-LA-P1 |
| MU-LA-14 | HTTP branch missing for one route (service principal answers 500) | T-LA-H1..H7 |
| MU-LA-15 | unflag guarded (blocks the recovery) | T-LA-P6 |
| MU-LA-16 | the guard blocks add paths (P7, P14) | T-LA-P7, T-LA-P14, T-LA-29 |
| MU-LA-17 | a new lock-A site added with no inventory row | T-LA-30 |
| MU-LA-18 | guard special-cases or calls the break-glass / flip | T-LA-26 |
| MU-LA-19 | a second concurrent removal passes (guard before lock A or lock A skipped) | T-LA-24 |
| MU-LA-20 | `reason` validation of `set_flag` moved after the guard (existence oracle) | T-LA-P6 |
| MU-LA-21 | P5 guard dropped while `last_admin_binding_row` order changes | T-LA-P5 |
| MU-LA-22 | P4 guard only covers a rebind that moves rows (misses the skipped-in-`on` shape) | T-LA-P4 |

## 8. Acceptance-criteria map

| Source | Requirement text | Design element | Tests |
|---|---|---|---|
| #2869 (a) | in an `on` tenant refuse removing the last interactive explicit tenant-wide TENANT_ADMIN | 3.3, D-2, D-4 | T-LA-P1..P6, T-LA-20 |
| #2869 (a) | removing | P2 (membership), P5 (grant row), P1 | T-LA-P2, P5 |
| #2869 (a) | demoting | P3, P4 | T-LA-P3, P4 |
| #2869 (a) | deactivating | P1 | T-LA-P1 |
| #2869 (a) | scoping | F4, P5, P11 (cannot lower; invariance proven; existing `:explicit` guard) | T-LA-P11a |
| #2869 (a) | flagging as a service principal | P6, D-6 | T-LA-P6 |
| #2869 (a) | typed 409 in the style of `last_admin_binding_row` | 3.4, 3.8 | T-LA-H1..H7, T-LA-27 |
| #2869 (a) | cover EVERY write path that takes lock A, including group-membership removal | 3.6 (23 sites), D-9 | T-LA-30, one test per path (except P18/P19) |
| #2869 (a) | one test per path | section 5 | T-LA-P1..P17 for P1 to P17; P18 by T-LA-26; P19 (class X, 5 sites) has NO behavioural test and is covered by the T-LA-30 inventory scan only (OQ-7 closed) |
| issue body | same interactive-explicit definition as gate fact 4 (one shared predicate, not a copy) | D-1, 3.2 | T-LA-17, T-LA-18 |
| issue body | lock order | D-7, 3.5 | T-LA-24, T-LA-25 |
| issue body | token paths, role-claim sync | P9, P10, P12 | T-LA-P9, P10, P12 |
| issue body | interplay with break-glass | 3.9 | T-LA-26, T-LA-29 |
| #2869 (c) | a decision record says whether A7 covers this | 13 (A12) | T-LA-31 |
| #2869 acceptance 1 | decision recorded then implemented with a test that removing the last interactive admin is refused | D-2, D-10 | T-LA-P1, P2 |
| #2869 acceptance 2 | before any production or pilot `on` (REQ-519 AC 24) | 1 (gate), PR body | PR checklist |
| REQ-519 AC 23 | seven `LIMIT-*` items unchanged | F9, 10 | T-LA-31 |
| REQ-519 AC 24 | process gate sentences | 1, 9 | PR checklist |

## 9. Gates and commands

`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix letflow.check`, `mix letflow.check_boundaries`, `mix letflow.permission_matrix --check`, `mix letflow.check_requirements_registration`,
`mix letflow.check_role_scope_grants_writers`, and the scoped `mix test` over the new files, `test/letflow/identity`, `test/letflow/scope_enforcement*`, `test/letflow/docs/roles_on_flip_docs_test.exs`, `test/letflow/routers` for the seven routes
(real output quoted; committed-write and advisory-lock files one at a time per the machine limits). HIGH tier: SEC design gate on this document, SEC code gate, REVIEWER. The PR body states: "NO production tenant is set to on until the supervisor says so",
"no on flip in any customer tenant, pilot included, until GH #2869 and GH #2883 are implemented" and that no migration, seed or config sets a tenant to `on`.

## 10. Docs text

* `docs/runbooks/scope-enforcement-on.md` and `docs/roles.md` (identical, `roles_on_flip_docs_test` compares them): the paragraph **Gate #2869 (last admin)** is rewritten: "In a tenant stored `on`, Letflow refuses (409 `last_interactive_tenant_wide_admin`) the removal, demotion, deactivation, rebinding or service-flagging of the last interactive explicit tenant-wide TENANT_ADMIN, counted exactly as gate fact `zero_tenant_wide_admins` counts. Token owners, flagged service principals and zero-row members do not count, because they cannot flip. The guard cannot see an administrator who exists in Letflow but can no longer log in at the identity provider; for that case use the operator break-glass below (GH #2883). The other half, a platform-operator break-glass with no HTTP route, a mandatory reason and an audit entry, is delivered by GH #2883, and 0051 A11 and A12 record that the 0051 A7 token break-glass covers grant writes only." The phrase `is delivered by GH #2883` is KEPT verbatim (pinned at `roles_on_flip_docs_test.exs` :736 and :738 for roles.md and the runbook, and by the seeded mutation at :984 that replaces it in roles.md); those three places do not change. The words "(still open)" go; the sentence "No `on` flip in any customer tenant, pilot included, until GH #2869 and GH #2883 are implemented" stays (pinned) until the supervisor lifts the gate. The intro sentence that lists the open items drops "the guard that prevents the gap is still open" and keeps "#2869" (pinned needle) as a closed reference.
* Item 7 of the production list is unchanged. No `LIMIT-*` item is added (F9).
* Module docs: `TenantAdminGuard` (the "only value" sentences, the new function, the new action), the moduledocs of `ServicePrincipal` and `ScopedGrants`, and the `@doc` of each guarded public function name the new error.

## 11. Security: INV analysis and residual risks

| INV | Where | Statement |
|---|---|---|
| INV-1 | all guarded paths | the prefix comes from the authenticated tenant (unchanged); the guard counts only in that schema |
| INV-2 / INV-4 | refusal event, 409 body | fixed code, `counted_admins` is 0, target id already in the request; no token, no count of others, no email |
| INV-7 | queries | the guard adds no SQL of its own; the counter is the existing parameterised query |
| INV-8 | mode read, count | an unreadable mode never allows; a failed count rolls back; the guard is no-op only when nothing was removed |
| INV-10 | scope of the check | the guard is per tenant; a PLATFORM_ADMIN role confers nothing and is not counted; the platform tenant stored `on` is protected the same way |
| 0051 D11/M1 | "refuse any change that leaves zero tenant-wide TENANT_ADMINs (scoping, unbinding, deactivating the last one)" | completed for `on` by this guard, with the interactive definition |

Residual risks (for SECURITY-REVIEWER):

* R-LA-1 (accepted, documented): IdP-side login loss is invisible (F9); the break-glass is the answer; the runbook says so.
* R-LA-2 (accepted): the guard does not apply in `shadow`/`off` (OQ-3); fact 4 protects the next entry into `on`.
* R-LA-3 (accepted): a refused deactivation of the last interactive admin also blocks deactivating a compromised last admin account through Letflow. The operator adds another admin first (P7/P14) or uses the IdP; the break-glass is not needed for this.
* R-LA-4 (accepted): an `on` tenant that was already at zero before the guard shipped is not blocked by it (transition rule, D-2); gate fact 4 prevented entering `on` at zero.
* R-LA-5 (accepted): one extra count query per guarded write; negligible.
* R-LA-6 (accepted): the inventory is data; a new lock-A writer is caught by the scan at test time, not at runtime.
* R-LA-7 (accepted, SEC F-2): the distinct 409 code tells an already-authorised caller that the tenant is stored `on` and has exactly one interactive admin left. The caller already holds the authority to read the mode and the admin list; the body names no id and `counted_admins` is 0 (T-LA-H*, T-LA-27).

## 12. SECURITY-REVIEWER rulings requested at the design gate

| Id | Question | Default built |
|---|---|---|
| S-LA1 | The guard reuses the gate's `:interactive_explicit` counter through the existing seam (no copy) | accepted if ruled |
| S-LA2 | Transition rule, `on` only, mode read after A and only in the refusing case, fail closed; bounded change of T-L8 | as stated |
| S-LA3 | A distinct typed code `last_interactive_tenant_wide_admin` and a second `reason_code` value in the pinned event contract | distinct; OQ-1 |
| S-LA4 | The per-path classification of 3.6, in particular P11 (scoping cannot lower the count, no defensive call) and P19 (not admin-set writers) | as stated; OQ-2, OQ-7 |
| S-LA5 | The inventory module plus completeness scan as the standing control for "every path" | as stated |
| S-LA6 | A12 text (13), A11 left unedited, the docs-test change | as stated |

## 13. Decision-record amendment (part (c)): text for `docs/migration/decisions/0051-org-scoped-role-grants-and-enforcement.md`

Applied by the builder in the same PR as the docs-test change (F8), appended after A11 as the last paragraph.

> ## Amendment 4 (2026-10-19): last-interactive-admin guard for an `on` tenant (additive, completes A10's removal half)
>
> Status: Accepted, relayed. Source: the SECURITY-REVIEWER design gate of GH #2869 part (a). Design `lib/letflow/design/gh2869-last-interactive-admin-guard.md`. Not verified by the recorder against code beyond the implementing PR.
>
> **A12. Last interactive tenant-wide administrator.** In a tenant whose stored `scope_enforcement` is `on`, a write that takes the number of interactive explicit tenant-wide TENANT_ADMINs from at least one to zero is refused with 409 `last_interactive_tenant_wide_admin`, audited as `tenant_admin.guard_refused`. "Interactive explicit" is the counter the gate actually implements for fact `zero_tenant_wide_admins` (SEC C-4, `count_interactive_explicit_tenant_wide_admins/1`): an active user, a member of the group the TENANT_ADMIN platform binding points to, with a tenant-wide TENANT_ADMIN row, not an admin-flagged service principal; token owners and zero-row members do not count. This NARROWS the wording of A1, which counts "a live TENANT_ADMIN token owner" for that fact: A1 is not restated or edited, and for this guard and for the implemented gate the narrower counter governs, because the flip route is interactive-only (A8). It covers deactivation, removal from the admin group, unbinding or rebinding the TENANT_ADMIN binding, revoking a tenant-wide TENANT_ADMIN grant row, and flagging the user as a service principal, under lock A, and it does not apply in `shadow` or `off`. It runs after the N1 guard, which keeps its own code. It is implemented by GH #2869 (a); A10 stays open until that implementation is on `main`, and A11's sentence that the guard "stays open" is read accordingly.
>
> **Does A7 cover this case? Partly.** A7 makes tokens the break-glass for GRANT writes under `on`: a TENANT_ADMIN token can add an interactive administrator again by writing a membership or a grant. A7 does NOT cover the flag, because the flip route is interactive-only (A4, A8): a tenant whose remaining administrators are tokens cannot turn enforcement off. The recovery for the flag is the operator break-glass of A11 (GH #2883), which has no HTTP route. The guard prevents the lock-out for every change made through Letflow; it cannot see an administrator who exists in Letflow but can no longer log in at the identity provider, and for that case A11 is the only recovery. Neither the guard nor A11 is special-cased by the other.

## 14. Open questions and DECISIONS recorded at r2 (OQ-1 distinct code; OQ-2 no defensive call on `ScopedGrants.create`; OQ-3 `on` only; OQ-4 transition rule; OQ-5 refuse; OQ-6 fixed code, no capability hint; OQ-7 closed; OQ-8 builder re-greps status writers). The gate sentence "no `on` in any customer tenant until #2869 and #2883 ship" is kept (section 10).

| # | Question | Default built | Needs |
|---|---|---|---|
| OQ-1 | A distinct code `last_interactive_tenant_wide_admin`, or reuse `last_tenant_wide_admin` (no router change, one `reason_code`)? | distinct (the issue asks a typed 409; operators need to tell the two apart) | DECIDED (r2) |
| OQ-2 | Add a defensive guard call to `ScopedGrants.create` although scoping cannot lower the count (F4)? | no (it would be an equivalent mutant); the invariance test T-LA-P11a guards the claim | DECIDED (r2) |
| OQ-3 | Apply the guard to `shadow` tenants too (so a shadow tenant cannot drift to zero before the flip)? | no: only stored `on`, as the issue says; fact 4 covers the flip | DECIDED (r2) |
| OQ-4 | Transition rule (before > 0, after == 0) or state rule (after == 0) for an `on` tenant already at zero? | transition: keeps recovery writes possible | DECIDED (r2) |
| OQ-5 | Refuse deactivating the last interactive admin even when that account is the compromised one (R-LA-3)? | yes; add another admin first | DECIDED (r2) |
| OQ-6 | Should the 409 body name the missing capability ("a person who can log in") for operators? | no, fixed code only (INV-4) | DECIDED (r2) |
| OQ-7 | CLOSED (CDV): P19 (`Scripts`, `Scripts.Policy`) is class X (they read the counted-admin count and write policy rows and script publication only). The builder's re-confirmation while filling the inventory is a BUILD STEP, not an open question | X | none |
| OQ-8 | A user whose status is changed through a path I did not find (a tenant-level bulk deactivation) would bypass the guard; the lock-A inventory scan would not see it if it does not take A | none found (`delete_all`/`status_changeset` survey); `update_locked_user` is the only status writer | DECIDED (r2) |

## 15. Self-review against the brief

* Every write path that takes lock A enumerated (23 sites) with a class and a per-path test: 3.6, T-LA-P1..P17, scan T-LA-30.
* Shared interactive-explicit predicate, not a copy: D-1, 3.2, T-LA-17/18.
* Lock order (A first, flag read after A, no new lock above A): D-7, 3.5.
* Break-glass interplay and the A7 answer: 3.9, 13. Typed 409 and event: 3.4, 3.8.
* Tests, mutants, acceptance map, open questions: sections 5, 7, 8, 14. No implementation code: signatures and prose only.
* Not verified by running anything (no `mix`), as instructed; claims about the code were read directly on `main` 2dfb1233f.
