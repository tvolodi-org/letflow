# MES proof P1: can the stock ledger grow two causes and a lot status?

Task T-1829, 2026-11-13. Owner go of 2026-11-12 ("continue with the first proof"). Plan: `07-roadmap-and-pilot.md` section 4.3
and `05-platform-options.md` section 8 point 1. Simple English on purpose.

## 1. Result in one line

**PASS, with stated limits.** On a copy, in tests only, the stock ledger policy took two new causes (`consume`, `produce`,
both tied to a batch id) and a lot quality status (`quarantine`, `released`, `rejected`) with a hold rule. All ledger
invariants held, old entries still reconcile, and the real upgrade chain (plan, apply, rollback) handled a tenant whose
stock row carried the copy's manifest hash. The limits are in section 6 (the proof could not run the copy through the real
HTTP and engine path, and the hold rule needs a guard, not a policy change).

Rule used: PASS = policy equal to the real one for old causes, consume/produce tests green, copy accepted by the ledger
registration rules, plan/apply/rollback recorded and working, ledger invariants green, hold matrix exact.
PARTIAL = any of these needed a workaround that changes the plan. FAIL = an invariant breaks or old entries stop reconciling.
None of the FAIL conditions happened. The one PARTIAL-like item (the catalog is compile-time) is a limit of the proof method,
not of the design; it is named below.

## 2. What was done, and scope

- A physical COPY of the stock policy and manifest, in `test/support/mes_p1/` (module names `Letflow.Proof.MesP1.*`).
  Added: causes `consume` and `produce`, a batch id (command key `batch_id`, stored in the existing header field
  `related_document_id`), a lot status table and a guard that refuses non-released lots.
- Tests in `test/letflow/proof/mes_p1/` (3 files, 28 tests, all green in the repo suite).
- Nothing real changed: no edit of `lib/`, `config/`, `priv/`, no migration, no flag, no catalog entry, no change of the real
  stock policy or manifest. The STOP RULE of the task (D-122) was not triggered. Nothing on QA, production or demo.
- The lot status tables (`proof_lot_status`, `proof_customer_location`) are test DDL created inside a throwaway committed test
  tenant. They are not migrations and are removed with the tenant.

## 3. Numbers (all from the final run: `mix test test/letflow/proof/mes_p1`, "28 passed", 24.8 s)

| What | Value | Backed by |
|---|---|---|
| Tests | 28 (policy 8, hash/upgrade 6, ledger 14); run time about 0.07 s, 8 s and 16 s | final run |
| Policy copy vs original | 37 changed lines (`diff -u ... \| grep -c '^[+-][^+-]'`), of which about 10 are moduledoc | diff |
| Copy and original give the same answer for every old cause | 21 commands (11 valid, 10 invalid) | E1 |
| Manifest hash, real stock vs copy | `879793949351...` vs `0d26a0f3f645...` (first 12 hex), different | H1 |
| What moves the hash | version only: yes. policy module name only: yes. causes only: yes. guard only: yes | H2 |
| What does NOT move the hash | policy CODE inside the same module name, with an unchanged registration map and version (by reading `ManifestHash.surface/1`; the test only shows the same manifest hashes the same). So "hash equal" is not proof of equal behaviour | read, not run |
| Copy accepted by ledger registration rules (rule 18) | yes (`:ok`) | H3 |
| U1 plan, hash-only drift (version 0.17.0 = compiled, hash = copy's) | 200, `up_to_date: false`, from 0.17.0 to 0.17.0, `steps: []`, `upgrade_path_available: true`, `path_error: nil`, `missing_ledger_storage: []`, `fits_one_transaction: true`, 44 route policies, 6 permissions | U1a |
| U1 plan, older version (0.16.0 + copy hash) | 200, `up_to_date: false`, 0.16.0 to 0.17.0, `steps: []` | U1b |
| U2 apply | 200, `state: done`, row version and hash become the compiled ones, the copy's hash joins `accepted_manifest_hashes`, one `done` upgrade journal row, one `module.upgrade` audit entry; a second plan says `up_to_date: true` | U2 |
| Rollback (dry run, then real) | both 200; `rollback_possible: true`; row back to 0.16.0 with the copy's hash; one `rollback` journal row, one `module.rollback` audit entry | U4 |
| While drifted: posting task of stock | refused, `{:error, :module_upgrade_required}` (the 409 `upgrade_required`), nothing posted; after U2 the same task completes and posts 1 receipt | U3a |
| While drifted: another installed module (`org`) | its own plan says `up_to_date: true`; after the stock upgrade the version and hash rows of the other modules are unchanged | U3b |
| Module `assets` (depends on stock) | NOT tested: this fixture does not install it. Guess only | none |

## 4. Ledger invariants (L1..L6, L11)

| Check | Outcome | Test |
|---|---|---|
| Consume from a lot into a batch, produce a finished lot from the batch | balances right (10 - 4 = 6 raw, 3 finished); `related_document_id` of both entries is the batch id; the receipt has none | L1 |
| No negative stock | consume of 3 with 2 on hand is refused `insufficient_balance`, entry count unchanged | L2 |
| Append-only | UPDATE and DELETE on `ledger_entry` and `ledger_leg` are refused by the table guards | L3 |
| Reversal | reversal of a consume restores the balance; reversal of a produce works while the lot is there and is refused (`insufficient_balance`) after the lot was used up; nothing written on a refusal | L4, L4b |
| Reconcile | gap, audit and chain checks run and there are zero mismatches after receipts, consume, produce and a reversal | L5 |
| Mixed era | an entry posted under the real registration and one under the copy registration sit in one ledger; reconcile is clean; `registration_hash` differs (`8f74b212...` vs `35a7d4e9...`) | L6 |
| Units | kg and litres on different items post cleanly; a second unit on one key is refused `unit_mismatch`. So the unit is per item, as the owner said, and one key cannot switch unit | L11, C4 |

## 5. Hold rule (L7..L10)

Rule used (a guess, the owner can change it): a lot that is not `released` cannot go out by `issue`, `hand_over`, `consume`,
`kind_change_out`, or by a `transfer` that touches a customer location. Everything else is allowed.

| Check | Outcome | Test |
|---|---|---|
| Matrix: lot status (none, released, quarantine, rejected) against 12 cases (5 held, 7 allowed) | exact: held cases refused with label `lot-quarantine` or `lot-rejected` and no entry written; for none and released all post; the 7 allowed cases post for every status, reversal included | L7 (4 tests) |
| Release workflow | quarantine refuses issue; `quarantine -> released` then the same issue posts; `rejected -> released` is refused; `rejected` is terminal | L8, T1 |
| Tenant isolation | the status of tenant A does not hold the same lot id in tenant B | L9 |
| Fail closed | in a tenant without the status table the guard raises and nothing is posted | L9 |
| Locking | a status change takes the exclusive hold; a posting started meanwhile does not finish until it commits, then it posts | L10 |

## 6. What broke or surprised

Confirmed by running:

1. **The policy cannot hold the rule.** The policy is pure (no read). The lot status needs a read, so the hold rule lives in the
   registration's `posting_guard`, not in the policy. (Design reading, confirmed: the proof guard is the only place that reads status.)
2. **Only one guard per registration.** Stock already has one (`FreezeGuard`, count freeze). The proof guard calls the freeze
   check first and then the lot rule. The real build must do the same in one module.
3. **The guard summary has no direction.** It lists balance keys, not "from" and "to". "Transfer to customer" can only be told by
   looking up a customer-location marker. A cleaner rule would need a direction in the summary: a change of the core.
4. **Legacy lots have no status.** The proof treats "no row" as released. That is unsafe by default (a bad old lot is not held).
   The alternative (no row means held) would block all existing stock, so it needs a data backfill first.
5. **The hash moves** on version, policy module name, causes and guard. It does NOT move on a code-only change inside the same
   policy module (read from `ManifestHash.surface/1`). So a behaviour change in the policy needs a version bump to be seen by U1.
6. **A hash-only difference is already a plan.** With the same version and a different hash, U1 reports `up_to_date: false` and an
   empty step list, and U2 applies it. A step-less ledger change therefore upgrades cleanly.
7. **Old entries keep verifying.** The registration hash is stored per entry; mixed eras reconcile clean (L6).
8. **A missing status table fails closed** (the guard raises, the platform maps it to `ledger_guard_failed`). The status table
   must exist on every tenant before the guard ships: install order matters.

Limits of the proof (honest):

- **The catalog is compile-time**, so the copy cannot be handed to the real U1/U2 code without changing `lib/` or the test config
  (out of scope). U1/U2/rollback were therefore run on the REAL stock module of a test tenant with the installed row aged to the
  copy's hash (the technique of `stock/upgrade_http_test.exs`). This proves how the upgrade chain treats a tenant whose stamped
  hash and version differ from the compiled ones and has no entity change. It does NOT prove the direction "tenant on real
  stock, build on the copy with new compiled content". That needs the real change.
- **The proof post helper mirrors `HandlerPost`**, it does not run the engine or task path (shared hold, guard summary, then
  `Ledger.post/1`). The real seam (guard, `posting_held` mapping, hold locks) is covered by the existing
  `test/letflow/ledger/posting_guard_test.exs`.
- U3b was checked by the plan of `org` and by the unchanged module rows, not by a write route of another module.
- Two tenants in one test (L9) and the throwaway table DDL are proof-only constructs.

## 7. Can real stock grow this way, or is a separate posting path needed?

Author's judgment (not verified by the owner):

**Real stock can grow this way**, in one module version, without a new ledger. The invariants are in the core, not in the policy,
so adding causes does not touch them; old entries keep verifying; upgrade has no data step. Reasons for caution:
the hold rule needs one composed guard (freeze plus lot hold), real storage for the lot status, and a decision about legacy lots.
A separate posting path would only be needed if the owner wants direction-aware rules in the guard (a core change) or wants
production stock kept apart from warehouse stock for audit reasons (open question 2 in `05`, part 5; the owner decides).

## 8. Effort estimate for the real change (assumption, T-shirt)

| Part | Size | Note |
|---|---|---|
| Policy: two causes, batch id, tests | S (2-3 days) | the proof diff is about 37 lines |
| Guard composition (freeze + lot hold), error alias for the new refusal | S (2-3 days) | one guard slot |
| Lot status storage: real tenant table or entity type, permission to set a status, audit, release workflow | M (1.5-2 weeks) | needs a migration or pack change: upgrade class B/C question |
| Module version bump, U1/U2 on every tenant, permission matrix and pin updates | S-M (3-5 days) | QA auto-CD deploys main: every QA tenant gets U1/U2 |
| Legacy lots: backfill or rule | S (2 days) + owner decision | |
| Web screens (status change, lot view) | out of scope here | |

Total about 4-5 weeks for one developer, plus owner decisions. Guess.

## 9. Security review points

- INV-1: the status table is per tenant schema, reached by prefix only; L9 shows tenant B is not held by tenant A's row.
  No `tenant_id` parameter is used.
- INV-6: a new data-access path (the guard reads the status) must prove its scoping: L9 does. In the real build the same test is needed.
- INV-2 / INV-5: the guard label shows the lot status (`lot-quarantine`) to a caller who can post. The scope slot `org_unit` is in
  the key, so the guard only sees keys of the posting itself; check that a caller cannot probe the status of a lot of another
  org unit by posting a line with that lot id (the proof does not test it: open).
- INV-7: no value is interpolated into SQL (typed binds); the table name is validated before the test DDL.
- INV-8: a guard raise fails closed (L9).
- INV-10: not applicable, no route takes a tenant id.
- Not designed here: who may set a status (needs its own permission; release is an audited action), and the race between a status
  change and a posting (exclusive vs shared hold: L10 shows the serialisation).

## 10. Verified vs guesses

Verified by a test in the final run:
E1 (copy equals the original for old causes), E2 (policy boundary scan), C1-C5, T1, H1-H3 (hash differs, what moves it, rule 18),
U1a, U1b, U2, U3a, U3b (org only), U4, L1-L11 (L7 four times).

Verified by reading code, not by a test: the hash does not move on a code-only change in the same module name (`ManifestHash.surface/1`);
the real engine path calls the guard under the shared hold (`HandlerPost`, `posting_guard_test.exs`).

Guesses: the hold rule itself (which causes are held, customer transfer by location marker, legacy lot = released); module `assets`
behaviour; the effort table; section 7 recommendation; behaviour when the build really carries the copy in the catalog.

## 11. How to remove the proof

`git rm -r test/support/mes_p1 test/letflow/proof/mes_p1 docs/design/mes/09-ledger-proof-P1.md`. Nothing else references them.
