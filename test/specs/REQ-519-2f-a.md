# REQ-519 slice 2f-a test spec: the `on` gate machinery, still dormant (GH #2535, decision 0051 D12/D8, SEC C-4/C-5/S-4/S-5/S-6)

Design: `lib/letflow/design/req519-enforced-writers-and-flag-on.md` r2a (section 1 2f-a row, 4.3 to 4.6, 7, 8.3, 9).
Scope: REQ-519 acceptance criteria 7 (2f-a part), 9, 10, 11, 12 (constant and source of the sentence), 14 (writer), 15 (refused action listing), 18 (gate half). AC 21 is the PR gate (commands, not tests). 8, 13, 16, 17, 19, 20, 22 and the flip-level halves of 14 and 18 are 2f-b.
Also covered: the SECURITY-REVIEWER code gate (step-16) MERGE CONDITIONS and the REVIEWER (step-17) notes (module-attribute defaults pinned, stored threshold names, C-1 `ArgumentError` of `integrity/1`, single owner of the flip vocabulary).
Nothing under `lib/` or `priv/` was changed by this step. Nothing is committed. Real results (including mutants) are in `handoffs/WF02-REQ519-ENFORCED-WRITERS-20261018/step-18-test-designer-2f-a.json`.
Resource rule followed: no `mix letflow.check.test`, no full-suite or multi-partition run; per-file `mix test`, one mix at a time under the shared mixlock (taken with `mkdir`, released by the creating script only).

## Files

| File | Tests | Ids |
|---|---|---|
| `test/support/on_gate_fixture.ex` | helpers | tenant with one interactive explicit admin; real `off -> shadow` flip giving a genuine shadow start `t0` and `now = t0 + 7 days`; persisted counters; RAW audit rows; tokens; orphan scope node; committed table rename / schema rename helpers; `opaque/1` (see "Hard facts") |
| `test/letflow/scope_enforcement/on_gate_test.exs` | 35 | T-G0..T-G10, `audit_state/1`, the `ScopeEnforcement.integrity/1` `on_gate` block |
| `test/letflow/identity/scoped_approvers_test.exs` | 18 | T-P1..T-P7 and the literal AC 10 edge cases |
| `test/letflow/scope_enforcement/shadow_window_test.exs` | 33 | T-E1..T-E14, T-E16, T-E9b, `counts_by_day/3` |
| `test/letflow/scope_enforcement/refused_audit_test.exs` | 13 | T-F1..T-F10, T-A5 |
| `test/letflow/audit/latest_matching_test.exs` | 9 | `Audit.latest_matching/4` |
| `test/letflow/routers/tenant_scope_enforcement_integrity_test.exs` | 9 | integrity `on_gate` body (exact key sets, no ids, read-only) |
| `test/letflow/scope_enforcement/dormant_on_test.exs` | 16 | `on` stays unsettable, the source scans, the stage-1 entries after the `flip_entry/6` dispatch change, SEC C-5 log line |

Existing tests edited by ELIXIR-DEV on purpose (reviewed in step-17 item 10, not weakened): `test/letflow/scope_enforcement_test.exs` T-I1 clean tenant and `test/letflow/routers/tenant_scope_enforcement_test.exs` T-I1 clean body, which peel `on_gate` off and assert the stage-1 keys by exact equality. This step edited NO existing test. `test/letflow/identity/sync_scope_guard_test.exs` (the dedup swapped to `Audit.latest_matching/4`) is unedited and green.

## What 2f-a cannot show (deferred to 2f-b, stated rather than faked)

`parse_mode/1`, `@modes` and `check_target/1` still reject `on`, so the `shadow -> on` path inside `flip/4` is dormant. Therefore NOT testable in this PR, and listed for 2f-b:

| Deferred | Design id / mutant | Why not here |
|---|---|---|
| refusal audit written by `flip/4` after the rollback, `shadow_required` for `off -> on` | T-X5, T-F via the route, MU-23, MU-38 (flip half) | `flip(:on)` is `:invalid_mode`; `RefusedAudit.record/6` is tested directly (committed state, own transaction, inside-transaction guard, best effort) |
| a raise inside `OnGate.evaluate/3` INSIDE the flip transaction is a `{:transaction_failed, _}` 500, not a refusal, no flag change | T-G9 (flip half), T-H9, MU-39 | the gate is reachable only directly and through `integrity/1`; the C-5 log line is tested through the live path that shares the same `rescue` and `flip_response/2` (an audit fault trigger on the `off -> shadow` flip) |
| flush before the transaction (a request just before the flip counts for `date(now)`) | T-E16 flip half, MU-42 | tested: `ShadowWindow.flush_evidence/0` makes a just-recorded request visible; NOT tested: that `flip/4` calls it |
| the S lock before the six facts INSIDE `on_checks!/3` | T-G10 flip half, MU-22 | tested instead: the gate itself takes no lock (completes while A and S are held elsewhere) and the live `off -> shadow` flip reads its facts after A and S (a gap committed by the lock holder is seen) |
| `attrs[:now]` ignored unless it is a `DateTime` | SEC S-5 | `now` is read only on the `on` path; tested: no junk value crashes a shadow flip, the router builds a literal three-key attrs map (AST scan), the body can never carry a clock |
| the AC 12 sentence in `docs/roles.md` | T-E15 | the docs are written by 2f-b; the sentence is pinned verbatim at its source (`ShadowWindow.scope_sentence/0`) |

## AC -> test

| AC | Tests | Why it exists (what it would catch) |
|---|---|---|
| 9 six facts, each alone | T-G1 (binding without a row), T-G2 (inconsistent tree), T-G3 (exceeding token; a FLAGGED service-principal owner STILL refuses), T-G4 a..h (fact 4), T-G5 (scoped approver; a scoped worker who is not an approver never blocks), T-G6 (no evidence), T-G0 (the green baseline, report fields, read-only, mode independent) | each fact must refuse with exactly its stable code on top of an otherwise satisfied tenant, so a fact that is dropped, inverted or merged shows up as a wrong `failed` list |
| 9 EVERY failing fact, stable codes, fixed order, no ids | T-G8 (all six at once equal to the design list in read order; no UUID, tenant id or schema name in the report; `audit_state/1` of the same report; pure `audit_state/1` key sets) | a gate that returns on the first failure (MU-27), reorders, or leaks an id |
| 9 explicit INTERACTIVE admin count (SEC C-4) | T-G4a zero admins refused and after an admin is bound the same call passes; T-G4b only member sits in a zero-row binding (stage-1 count still 1, interactive 0); T-G4c (i) only a flagged service principal; T-G4d (ii) only a live token owner (also `tokens_exceed_owner`, both named in read order); T-G4e (iii) human + flagged principal passes; T-G4f (iv) inactive human; T-G4g a scoped-only group counts only through a tenant-wide USER row; T-G4h distinct per user | the gate must not use the stage-1 count (MU-25) and must not count token owners, flagged principals, inactive users or zero-row members (MU-51) |
| 9 a raise is never "no failure" (INV-8) | T-G9 (each table a fact reads, renamed with COMMITTED DDL so a swallowed raise cannot hide behind an aborted transaction; a schema that is not `tenant_<32 hex>` raises `ArgumentError` at the evidence read; only a `DateTime` clock is accepted, no 4-arity) | MU-28 (a `rescue` around a fact) |
| 9 lock order, facts read after the locks | T-G10a `evaluate/3` completes while another connection holds lock A and the scope-tree lock S (no lock of its own), T-G10b the integrity snapshot is lock-free too, T-G10c the live shadow flip queued on A reads its facts after A and S: a binding gap committed by the lock holder refuses it | a fact read before the locks (stale), a gate that takes a lock |
| 9 integrity `on_gate` | on_gate_test `integrity/1` block (keys, values, agrees with the gate, old admin count vs explicit count, read-only, `ArgumentError` for a non-tenant prefix name, a failing read raises out of `integrity/1`), integrity router test (exact key set of EVERY level, values for a clean tenant, ISO-8601 `shadow_since`, no id in the subtree with every fact seeded, read order of `blocking`, `information` count, the two spellings, no audit entry, a fully satisfied tenant reports `blocking: []` with a midnight-safe retry) | a field added to the body, an id leaking, the endpoint writing, `blocking` disagreeing with the gate |
| 10 scoped approvers | T-P1 (+ user-row-only, two routing groups counted once, routed and unrouted counted separately, the gate code), T-P2 (tenant-wide user row / group row clears), T-P3 (row removed clears), T-P4 (routing membership removed -> informational), T-P5 (not routed: never blocks, counted informationally), T-P6 (inactive; reactivated), T-P7 (zero-row holder not counted, fact 1 counts the binding), edge cases: not a member, routing-KIND `TASK_WORKER` binding makes nobody a holder, a scoped row / tenant-wide row of ANOTHER role, another tenant, read-only | the literal AC 10 text and S-4 (active only), each leg of the definition separately (MU-29) |
| 11 evidence | T-E1 (a) alone, exact boundary `>=` at whole seconds (-1 s fails, 0 passes), an hour short, 30 days, a clock before the start, no entry at all; T-E2 (b) total alone with 99 vs 100; T-E3 (b) every date needs requests (100 on one date: total passes, rule fails; a stored 0 is a day without requests); T-E4 (c) each of the six reasons, the two blocking ones block, the other four never; T-E5 all satisfied and the report; T-E6 start = LATEST entry (shadow -> off -> shadow restarts it, a latest transition that left `shadow` fails closed, other tenant / other action / other resource type / `on` / no `mode` key never start it); T-E7 window dates inclusive on both ends and counted in full, dates outside never counted, a quiet date not replaced by outside traffic; T-E10 `configuration`; T-E11 the injected clock | MU-30..MU-33, MU-36 |
| 11 thresholds from the env only | T-E8 (no 4-arity, no `thresholds/1`, unknown flip attrs change nothing), T-E9 (defaults 7 / 100 / 90 pinned with the keys unset; 0, -1, 2.5, "7", nil, atoms, lists, maps fall back to the DEFAULT, never the floor; valid values used; a lowered `min_requests` changes the verdict), T-E9b (the production configuration sets none of the three keys, no `config/*.exs` names a key or an `SCOPE_SHADOW_(MIN|RETENTION)` environment variable, `lib/` names the keys only in `ShadowWindow` plus the pruner, no `System.get_env` in `ShadowWindow`) | MU-34, the REVIEWER note on the module-attribute defaults, SEC S-5 |
| 11 one grouped read | T-E13 `counts_by_day/3` equals the per-day sums of `counts_between/3`, absent days absent, bounds inclusive, ONE statement; `ShadowWindow.evaluate/3` is TWO statements; prefix validation | MU-35 (N+1) |
| 12 statement of scope | T-E14 (constant in the report, the integrity body, the audit state, the refusal entry), the sentence pinned verbatim at its source | MU-40; T-E15 itself is 2f-b |
| 14 refusal audit (writer) | T-F1..T-F6 one test body iterating the six codes (exactly ONE `scope.enforcement_refused` entry, actor, trace, `resource_type "tenant"`, `before_state`, the closed `after_state` key set, equal to `target` + `failed` + `OnGate.audit_state/1`, the probe count, no flag change), T-F7 `shadow_required` (no counts, previous `off`; nil actor and trace tolerated), multi-failure order, no id/name/token data in the stored entry, T-F8 own transaction (the entry written after a rolled-back transaction persists; nothing is written and ONE constant line is logged inside an open transaction; each refused request has its own entry), T-F9 / T-F10 a raising audit write returns `:ok`, leaves no entry and logs ONE constant line without any id or fault text | MU-38, MU-9 |
| 15 listing | T-A5 the refused entry is returned by `Audit.list_entries/1` with the tenant filters, the chain verifies; the stage-1 entry shapes (`enabled` three-fact payload, `disabled` mode + reason) and the single-owner vocabulary | the action must be readable without error |
| 18 INV-1/2/4/8 (gate half) | no id in the report / audit state / integrity subtree / refusal entry; captured-log assertions on the constant lines only (Ecto debug lines carry bound ids); the gate and the refusal write log nothing else; raises propagate | INV-2, INV-4, INV-8 |
| SEC merge: `on` unsettable | dormant_on_test: `parse_mode/1`, `modes/0`, `flip(:on)` from off and shadow (no change, no entry, no refusal entry), PUT `mode=on` is 422 also with a clock and thresholds in the body, PUT `shadow` ignores them, `GET /` lists two modes, AST scan: the router `attrs` is ONE literal map of exactly `actor_id`, `reason`, `trace_id`, no `now` in the router, only the router calls `ScopeEnforcement.flip/4` (the scan proven live on a seeded source and on comments / strings) | the door must stay shut until 2f-b |
| SEC C-5 | PUT with an audit fault on the flip: detail-free 500, no flag change, no entry, exactly ONE line `scope_enforcement_flip_failed reason=transaction_failed exception=Postgrex.Error` without id, schema or fault text; an ordinary 409 and a 200 log no such line | MU-52 |
| `Audit.latest_matching/4` | nil; latest by timestamp whatever the insertion order; equal timestamps broken by the higher id (inserted in both orders); the action list filter (latest among the listed, an empty list matches nothing); `resource_type` / `resource_id`; the tenant prefix; the full entry; ONE statement; the sync-guard dedup predicate; the function head | MU-36 |

## Hard facts that shape the tests (found by running, not assumed)

| Fact | Effect |
|---|---|
| the tenant fixture leaves the sandbox in `:auto` mode | `Repo.in_transaction?/0` is false in the test process, so `RefusedAudit.record/6` runs on committed state (design A-5) and a rename of a table is real DDL |
| `DateTime.diff(a, b, :second)` floors EACH operand to whole seconds before subtracting | a duration boundary cannot be tested below one second; the tests use `t0 + n s` (the fractional part cancels) at `-1 s`, `0`, and an hour |
| `Audit.insert_entry/3` stamps `DateTime.utc_now()` | the shadow start is a real flip entry and `now` is derived from it (`t0 + 7 days` exactly); RAW rows (synthetic chain hashes) are used only where a chosen timestamp / id is the point, and never together with `Audit.verify_chain/1` |
| a failed statement inside a transaction aborts it, so every LATER read raises too | a table renamed inside a rolled-back transaction cannot tell a gate that propagates the first raise from one that swallows it (MU-28 survived that form); the rename is therefore COMMITTED and restored in an `after` |
| the Elixir 1.20 type checker warns about a deliberately wrong argument, also through a capture | the wrong-argument tests pass the value through `OnGateFixture.opaque/1` (process dictionary) so no compile warning exists (`mix letflow.check.test` greps for warnings) |
| `integrity/1` reads the grant tables before it derives the tenant id | the `ArgumentError "invalid tenant schema prefix"` is reachable only for a COMPLETE schema with a non-tenant NAME; the test renames a fixture schema |
| `ExUnit` `with_log` captures Ecto debug QUERY lines | log assertions are made on the constant lines only (filtered by their marker), never on ids over the whole capture |
| the audit action `scope.enforcement_refused` fault raises `Postgrex.Error` out of `Audit.insert_entry/3` | the `audit_failed` branch of `RefusedAudit.write/6` is unreachable (as for `TenantAdminGuard`); the `exception` branch is what T-F10 pins |
| `tenant_role.name` is globally unique per tenant | `scoped_task_worker!/2` creates the `TASK_WORKER` binding on the first call and joins the same group afterwards |
| `config/*.exs` set none of the three threshold keys (the earlier config copy was reverted) | the defaults live only in the `ShadowWindow` module attributes; T-E9 pins 7 / 100 / 90 and T-E9b scans |

## Mutants

Applied in memory only (the edited source of ONE lib file compiled into the test VM with `Code.compile_string` through `mix do run --no-start -r mut.exs + test <files>`; the anchor must occur exactly once, CRLF normalised; nothing on disk changed, so there is nothing to revert; `git status` checked). Counts are failed tests of the files named. All measured values are in the handoff `step-18-test-designer-2f-a.json`; the table of ids and killers:

| Id | Mutation | Killed by (failed / run) |
|---|---|---|
| MU-25 | gate uses `count_tenant_wide_admins/1` | T-G4 (5 / 35) |
| MU-26 | a flagged service-principal owner exempts its token | T-G3b (1 / 35) |
| MU-27 | gate returns on the first failing fact | T-G8 (4 / 35) |
| MU-28 | a raise in fact 2 is rescued as "no failure" | T-G9 committed rename (1 / 35); SURVIVED the first form, see Hard facts |
| MU-28b | a raise in the evidence read is rescued | T-G9 (3 / 35) |
| MU-F4 | fact 4 never fails | T-G4, T-G8 (8 / 35) |
| MU-29a..d | scoped approvers: inactive counted; zero-row holders counted; role filter of the group rows dropped; routing-KIND binding accepted as holder | T-P6; T-P3 / T-P7; T-P `ph4` group-row variant (SURVIVED until that case was added); T-P `ph2` with a user row (1 to 2 / 18) |
| MU-30 | evidence total-only (no every-day rule) | T-E3 (3 / 33) |
| MU-31 | `>` instead of `>=` at the duration boundary | T-E1 (12 / 33) |
| MU-32 | (c) counts one blocking reason only | T-E4 (1 / 33) |
| MU-33a/b | window excludes the last / the first date | T-E7 (7 / 33 each) |
| MU-35 | N+1 `counts_between` calls | T-E13 statement count (1 / 33) |
| MU-36, 36b, 36c, 36d | oldest instead of latest; id tie-break reversed; action filter dropped; any mode starts the window | latest_matching + T-E6 (5 / 42; 1 / 9; 3 / 42; 2 / 33) |
| MU-40 | `evidence_scope` blank in the report | T-E14, T-G8 (3 / 68) |
| MU-req, MU-cfg, MU-default, MU-floor | `>` on the request total; `configuration` always true; default 6 days; invalid env becomes the floor 1 | T-E2; T-E10; T-E9 (13 / 33); T-E9 (1 / 33 each) |
| MU-42 (flush half) | `flush_evidence/0` does nothing | T-E16 (1 / 33) |
| MU-13a/b | `counts_by_day/3` drops the lower / the upper bound | T-E13 (1 / 33 each) |
| MU-38a..f, MU-9 | refusal written inside a transaction; never written; raise propagates; wrong previous mode; extra id key; id in the log line; actor dropped | T-F8b; T-F1..T-F7; T-F10; T-F7; key-set test; T-F10; T-F1 (1 to 11 / 13) |
| MU-52a/b | 500 path logs nothing / logs the exception text | C-5 test (1 / 16 each) |
| MU-body1/2, MU-snap | integrity body drops `evidence_scope` / zeroes `scoped_approvers`; `blocking` always empty | integrity router test (1 / 9 each); on_gate + router (6 / 44) |
| MU-51a..e | fact 4 counts flagged principals; counts token owners; drops the explicit-row requirement; counts inactive users | T-G4c; T-G4d; T-G4b / T-G4g; T-G4f (1 to 3 / 35) |

NOT measurable in 2f-a (dormant, listed under "What 2f-a cannot show"): MU-22 (S lock order inside `on_checks!/3`), MU-23, MU-39 (a raised precondition recorded as a refusal), MU-42 (flush dropped from `flip/4`), MU-34 through `attrs`.
