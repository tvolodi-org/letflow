# REQ-519 slice 2e-b test spec: IdP sync no-widening, scope_delta, membership registry (GH #2535, decision 0051 D1/D8/N3, SEC C-3)

Design: `lib/letflow/design/req519-enforced-writers-and-flag-on.md` r2a (sections 1 2e-b row, 3.8, 3.9, 3.9a, 7, 8.2, 9).
Scope: REQ-519 acceptance criteria 2, 3, 4, the 2e-b half of 7 (`grant.sync_suppressed`, `binding.pending_scope`, `group_member.*`), and the AC 1 (f) membership rows. AC 21 is the PR gate (commands, not tests). 2e-a (ACs 1, 5, 6 and `binding.refused`) is `test/specs/REQ-519-2e-a.md`; 8 to 20 and 22 are 2f.
Also covered: the SECURITY-REVIEWER code gate (step-11) MERGE CONDITIONS and the REVIEWER (step-12) notes F-3b and TS-1.
Nothing under `lib/` or `priv/` was changed by this step. Nothing is committed. Real results (including mutants) are in `handoffs/WF02-REQ519-ENFORCED-WRITERS-20261018/step-13-test-designer-2e-b.json`.
Resource rule followed: no `mix letflow.check.test`, no full-suite or multi-partition run; per-file `mix test`, one mix at a time under the shared mixlock.

## Files

| File | Tests | Ids |
|---|---|---|
| `test/support/sync_scope_fixture.ex` | helpers | raw platform / routing groups with tenant-wide or scoped rows (an `on` tenant has no writer for a tenant-wide binding), claims context, one sync call, audit-fault trigger, unreadable-mode helpers |
| `test/letflow/identity/sync_scope_guard_test.exs` | 40 | T-S1..T-S17 (+ T-S15c, the mode read after lock A) |
| `test/letflow/identity/membership_scope_delta_test.exs` | 19 | T-D1..T-D5, the `MembershipScope` pure and read functions |
| `test/letflow/identity/binding_writers_membership_rows_test.exs` | 20, async | AC 1 (f) / SEC merge condition: `membership_rows/0` existence, reachability, completeness |
| `test/letflow/identity/enforced_audit_actions_test.exs` (2e-b part appended) | +2 (4 in the file) | T-A3, T-A4 |

Forced edit to an existing test (by ELIXIR-DEV, reviewed in step-12 item 11, not weakened): `test/letflow/routers/identity_gh2547_audit_test.exs` gained `scope_delta` in the two exact `after_state` maps. The design's "GH 2547 tests pass unedited" (3.8) could not hold once the key is added on purpose; the exact-equality form is kept, nothing is relaxed. This step made no edit to an existing test other than appending to `enforced_audit_actions_test.exs`.

## AC -> test

| AC | Tests | Why it exists (what it would catch) |
|---|---|---|
| 2 suppression, case (3) | T-S1 (user with a scoped row, synced into a tenant-wide group in `on`: no membership, login succeeds with the marker stamped, ONE `grant.sync_suppressed` whose `after_state` is EXACTLY `{user, group, role, trace_id}`, before_state nil, resource `user_role` / `<user>:<role>`, effective scope and rows unchanged), T-S1b (a failure of a LATER step of the same sync leaves no suppression entry: same transaction), T-S1c (the existing export still returns the user) | the three things an implementation can get wrong silently: admitting the user, losing the audit, writing the audit outside the sync transaction |
| 2 shadow / off | T-S2 per mode (`off`, `shadow`: legacy membership added, `{:ok, user}`, no suppression entry, `group_member.added` still has `source`, `roles_gained` and the new `scope_delta`), T-S2flip (the stored mode is read per call) | the guard must be an `on` behaviour only |
| 2 typed result | T-S13 (`sync_role_claims_from_token/3` returns a `User` in every mode and every outcome, and its `@spec` still renders `User.t()`), T-S14 (the report is `{:suppressed, ...}` exactly for suppressed cases, `{:ok, _}` for scoped group / unresolvable claim / already a member, also when other memberships were written; key sets of summary and items; no claim value) | the pipeline callers depend on `User.t()`; the typed result must be exact |
| 2 delta rule | T-S3 (a group binding a scoped claimed role AND a tenant-wide unclaimed role is withheld WHOLE; only the widening role is audited), T-S3b (every widening role listed, sorted, each with its own kind), T-S4 (a scoped group, a user already holding a scoped row, a group with no row are all joined and not recorded), T-S5 (already a member of the tenant-wide group: no suppression, no entry, no second insert; already tenant-wide through another group is unaffected) | the delta rule must neither over- nor under-suppress |
| 2 TENANT_ADMIN | T-S6c (seeded `on` tenant: a claimed `TENANT_ADMIN` gives no membership and one `binding.pending_scope`; `list_effective_role_names` empty), T-S6d (control in `shadow`: membership added) | the privilege-escalation case the guard exists for (INV-10) |
| 3 pending_scope | T-S6 (user with no rows: no membership, exact key set, no claim value / e-mail / group name in the payload), T-S6b (REVIEWER F-3b: a user whose ONLY row is a tenant-wide USER-principal row for a role the user does not hold is `:no_scoped_rows` = `binding.pending_scope` and STILL suppressed), T-S6e (captured log of a suppressed sync holds no claim value and no new `sync_role_claims` line, INV-4 / A-6) | the key set and the F-3b classification are contract; the log rule is INV-4 |
| 3 not held | T-S7 (`list_effective_role_names` omits the role, the coarse permission check is false, `Scope.allowed?/3` is `{:deny, :role_not_held}` and NOT `:no_grant_rows`; control: after an admin adds the user the same checks allow) | the withheld role must really be absent, with the existing deny reason |
| 3 dedup | T-S8 (three syncs yield one entry and `deduped` is counted; a second role yields a second entry; another user its own entry), T-S9 (state is the table: an entry written before, by "an earlier process", suppresses the write for a brand-new process; dedup never admits the membership; the guard source holds no Agent / ETS / persistent_term / process dictionary), T-S9b (dedup is per action: the user who later gains a scoped row gets the other action once), T-S9c (tenant scoped) | the dedup must survive a restart and must not leak across user, action or tenant |
| 3 remedy | T-S10 (the group's rows become scoped, an admin adds the user: the user holds exactly that scope and `group_member.added` carries the `scope_delta`; the next sync is a no-op) | the documented remedy actually works |
| marker (F5) | T-S11 (stamped when every candidate was suppressed; stamped when one membership was written alongside a suppressed one; nil with no candidate at all and nothing written) | the sync must not rerun at every login, and a no-candidate sync must still retry (ISS-0773) |
| rollback | T-S12 (a raising audit write on the suppression entry rolls back the memberships of the same call and every entry; the original user comes back; marker nil; log has no exception text; the retry works), T-S12b (a mode read that RAISES leaves no membership, entry or marker and never proceeds as `off`, SEC C-2), T-S12c (no candidate: no lock, no mode read, not even the failure fallback) | the sync must fail closed |
| C-3 ordering | T-S15 (rebind queued FIRST under a REAL held lock A commits before the sync takes A; the sync's decision uses the binding read AFTER A and withholds the group; the scenario is proven real by the moved row), T-S15 control (sync queued first: it joins G, "fully before"), T-S15c (the MODE is read after A too: a flip to `on` queued first is seen by the sync behind it) | the roles each group binds, and the mode, must be read after lock A, not carried from the pre-lock resolve |
| routing roles | T-S16 (a group with a scoped platform role and a tenant-wide ROUTING role is joined; claiming only a routing-role name resolves no group), `bound_platform_roles/2` lists platform bindings only, per group, inside the tenant | a routing binding never widens |
| docs | T-S17 (A-7: `docs/roles.md` states the whole group is withheld, the two actions, the key set, the remedy and the routing-role rule) | the documentation is a contract |
| 4 scope_delta | T-D1 / T-D2 / T-D3 (add to a tenant-wide group, add to a scoped group, remove) each in `off`, `shadow` and `on` (T-D4), the delta lists only changed roles, a no-row group gives `[]`, a re-add writes no entry | the delta is in every mode and only for changed roles |
| 4 payload | T-D5 (legacy keys `group_id user_id group_roles member roles_gained|roles_lost source user_platform_roles` all present, plus exactly `scope_delta`; `roles_gained` / `roles_lost` values intact), the entry is in the membership's transaction (a raising audit rolls the membership back), cap: 55 nodes give 50 sorted ids and `count` 55 on add AND remove, exactly 50 are not truncated, another tenant's ids never appear | MU-18 / MU-19 and the 50-id cap |
| 4 pure functions | `would_widen?/2` truth table, `render/1` cap and sort, `delta/2` (changed only, sorted, absent = deny), `snapshot/2` (held roles only), `row_scopes/2` (every row regardless of held-ness), `snapshot_if_added/4` (in memory, writes nothing), tenant isolation of the reads | the guard's decision is built from these |
| 7 (2e-b actions) | T-A3 (`binding.pending_scope`, `grant.sync_suppressed`, `group_member.added`, `group_member.removed` listed through `Audit.list_entries` resource filters, the chain verifies), T-A4 (exact key sets of the four, and no realm, e-mail, preferred name, display name, user e-mail, user name, group name, password text or token prefix in any payload) | the audit must be readable and secret-free |
| 1 (f) membership rows | registry test: exactly M-a..M-f in order with the AC's / design's states; each row's file and function exist (incl. private `copy_members/3`); each row still REACHES its classification (audit writer, membership primitive, guard calls, `Repo.delete_all`, `Repo.insert_all`); the guard calls are NOT reachable from the pre-lock resolve; the walk is proven live on a seeded source; COMPLETENESS: every function under `lib/` that references `GroupMember` and calls a `Repo` write is a row's function or reachable from one, with the scanner proven live on a seeded unregistered writer | a new membership writer cannot be added unclassified; a rename or a dropped call cannot orphan a row |

## Hard facts that shape the tests (found by running, not assumed)

| Fact | Effect |
|---|---|
| `tenant_roles.name` is globally unique and a role is bound to exactly one group, so a non-member's held-aware "before" scope for a role bound to G is always `:deny` | "already tenant-wide for the role" is only reachable as "already a member" (T-S5); the dedicated pure test of `would_widen?/2` covers the other half of MU-14 |
| the claim resolver only resolves `kind = platform_role` names | a routing-only group can never be a candidate; T-S16 therefore uses a group with a platform role AND a routing binding, and a claim of a routing-role name |
| `group_member.*` `after_state` also carries `user_id` and `group_roles` is a list of `{kind, name}` maps | the key-set and value assertions use the real shapes |
| `add_group_member/3` answers `created: false` for an existing member | the re-add test asserts that |
| `with_log` captures Ecto debug QUERY lines | log assertions are made on the constant sync lines and on claim values (which never reach SQL), never on ids |
| `Audit.insert_entry/3` fixes the trace id from the context; a call without `audit_context` stores `nil` | the fixture always passes a trace id when the value is asserted |
| the sync worker waits on lock A under `lock_timeout = 2s` | T-S15 holds the lock only for the two `wait_for_blocked` polls (about 1.5 s worst case) |

## Mutants

Applied in memory only (the edited source of each file compiled into the test VM through `mix do run --no-start -r mut.exs + test <the 4 files>`; every anchor must occur exactly once; nothing on disk changed). Counts are failed tests of the 83 in the 4 files (40 + 19 + 20 + 4).

## Not covered here (by design)

* A non-raising failure of the suppression audit write (`{:error, {:audit_failed, _}}` out of `Audit.insert_entry/3`): with a valid schema name and a normalised trace id no input makes the insert return an error tuple instead of raising, so only the raising variant (T-S12) is reachable from a test. A mutant that turns that branch into success is not killable (reported).
* TS-1 (REVIEWER, GH 2858): the typed report has a failure variant. A swallowed failure is `{:failed, original_user, step}` (step `:raised` or the Multi step name), never `{:ok, _}`; T-S12, T-S1 and T-S18 pin it.
* 2f: the flag value `on`, the gate, the flip route; `Audit.latest_matching/4` (the dedup uses a private `Repo.exists?` until 2f-a).

### Measured mutants (32 applied, 32 killed; failed tests of 83; every anchor occurred exactly once; nothing on disk changed, so there is nothing to revert, verified with git status)

| Mutant | Edit | Failed | Killed by |
|---|---|---|---|
| MU-12 | sync evaluates only the claimed role | 3 | T-S3, T-S3b, T-S15 |
| MU-13 | suppress also when the group has scoped rows | 13 | T-S3, T-S4, T-S5b, T-S11, T-S12, T-S14, T-S15, T-S16, T-A3, T-A4, pure `would_widen?` test |
| MU-14a | `would_widen?/2` ignores the start scope | 1 | pure `would_widen?` test |
| MU-14b | MU-14a AND the member shortcut removed (the only way a re-sync of a tenant-wide member could be suppressed) | 4 | T-S5, T-S5b, pure test |
| MU-15 | `pending_scope` payload gains a key | 3 | T-S1, T-S6, T-A4 |
| MU-16 | dedup kept in memory (`:persistent_term`) | 3 | T-S9 (pre-seeded entry), T-S1b, T-S12 |
| MU-17 | marker not stamped when every candidate was suppressed | 5 | T-S1, T-S6, T-S11 |
| MU-18 | `scope_delta` only in `on` | 6 | T-D1..T-D4 in off/shadow, T-S2 |
| MU-19 | `roles_gained` / `roles_lost` dropped | 4 | T-D5, T-S2, T-A4 |
| MU-45 | the export returns `{:ok, user}` | 1 | T-S13 |
| MU-46a | the written pair is dropped from the summary | 22 | T-S1.., T-S14 |
| MU-46b | an extra key on a summary item | 8 | T-S14, summary equality in T-S1/T-S6 |
| MU-46c | the deduped pair is dropped from the summary | 3 | T-S8, T-S9 |
| MU-49 | the group-role read happens BEFORE lock A | 1 | T-S15 (held-lock rebind) |
| MU-50 | `bound_platform_roles` counts routing bindings | 2 | T-S16 (both) |
| MU-W1 | the mode read failure is swallowed as `off` | 1 | T-S12b |
| MU-W2 | the MODE is read before lock A | 3 | T-S15c (and the two unreadable-mode tests) |
| MU-W4 | shadow runs the guard | 4 | T-S2 (off and shadow), T-S2flip, T-S6d |
| MU-W5 | action names swapped for `:has_scoped_rows` | 6 | T-S1, T-S3b, T-S9b, T-A3/T-A4 |
| MU-W6 | classification: any non-nil row scope is "scoped" (F-3b) | 1 | T-S6b |
| MU-W22 | classification uses the held-aware snapshot instead of row scopes | 6 | T-S1, T-S3b, T-S9b |
| MU-W7 | the group is joined anyway after the entry (split membership) | 20 | T-S1, T-S3, T-S6, ... |
| MU-W8 | dedup ignores the action | 1 | T-S9b |
| MU-W13 | `scope_delta` key renamed / not written | 16 | T-D1..T-D5, T-S2, T-A4 |
| MU-W14a | cap 51 instead of 50 | 2 | T-D5 cap, `render/1` |
| MU-W14b | `count` is the capped length | 2 | T-D5 cap, `render/1` |
| MU-W15 | removal takes the before snapshot as empty | 7 | T-D3, T-D1..T-D4 remove |
| MU-W16 | `snapshot_if_added` ignores the group's rows | 24 | T-S1, T-S3, T-S6, ... |
| MU-W19 | the no-candidate sync reads the mode | 1 | T-S12c |
| MU-R3 | registry row M-f names `copy_memberz/3` | 4 | existence tests (M-f, reach, completeness) |
| MU-R4 | registry row M-e dropped | 5 | row list, existence, completeness |
| MU-R5 | registry row M-c state changed to `:unchanged` | 1 | states test |

Not killable (reported, no test written): a mutant that turns the non-raising `{:error, _}` branch of the suppression audit write (`write_once/6`) into success, because `Audit.insert_entry/3` cannot return an error tuple for a valid schema name and a normalised trace id, only raise (T-S12 covers the raise). The on-disk scanners (reachability, completeness, `docs/roles.md`) are not reachable by an in-memory mutant; their liveness is the seeded-source tests and the registry mutants above.
