# MES proof P2: a thin batch slice on the P1 copy

Task T-1830, 2026-11-13. Owner go after P1 (PM D-123). Plan: `07-roadmap-and-pilot.md` section 4.3 (P2), options in
`02-liquid-streams-options.md`, `03-granular-batch-options.md`, and the P1 result `09-ledger-proof-P1.md`. Simple English on purpose.
Every statement is marked **verified** (a test ID that ran green) or **guess**.

## 1. Result in one line

**PASS, with stated limits.** On the P1 copy, in tests only, a recipe version, one batch, two raw lots consumed, one finished lot
produced, quality hold and release, and a trace in both directions all gave the right answer. Litres and kg lived side by side
with no unit mixing on one key. The limits and the core changes this needs are in sections 5 and 6.

Rule used: PASS = every test row green, trace answers equal the fixed expectations in both directions, unit per item holds.
PARTIAL = a step needed a workaround that changes the plan. FAIL = a trace answer is wrong or an invariant breaks.
None of PARTIAL or FAIL happened. The STOP RULE (any change in `lib/`, `priv/`, `config/`) was not triggered.

## 2. What was done

- Test code only: `test/support/mes_p2/` (`BatchStore`, `Trace`, `Scenario`) and `test/letflow/proof/mes_p2/` (3 files, 21 tests).
  P1 files are reused as they are (`StockCopy.post/3`, `LotStatus`, `HoldGuard`), not edited.
- Three TEST tables are created inside a throwaway committed test tenant (`proof_recipe_version`, `proof_recipe_line`, `proof_batch`).
  A trigger freezes the lines of a version that is not a draft. This is test DDL, not a migration. The tenant drop removes it.
- The trace is plain SQL over the real `ledger_entry` and `ledger_leg` rows: batch id in `related_document_id`, item in `k1`,
  lot in `k5`, units in `unit_ref`. No new ledger table or column was needed. An entry that has a later reversal is left out.
- Nothing real changed: no real stock policy or manifest, no catalog, no migration, no flag, nothing on QA, production, demo.
- Remove it all with: `git rm -r test/support/mes_p2 test/letflow/proof/mes_p2 docs/design/mes/10-batch-slice-P2.md`.

## 3. Numbers (final run: `mix test test/letflow/proof/mes_p2 test/letflow/proof/mes_p1`: "49 passed", 67.5 s; P2 alone is 21 tests)

| What | Value | Backed by |
|---|---|---|
| Tests | 21 in P2 (recipe and batch 8, hold and trace 10, liquid 3); P1's 28 still green | final run |
| Scenario | recipe R v1: A 60 kg + B 40 kg -> F 100 kg. Lots LA1 = 100, LA2 = 100, LB1 = 100. Batch 1: LA1 50 + LB1 30 -> LF1 80. Batch 2: LA2 20 + LB1 20 -> LF2 40 | `Scenario.scenario/1` |
| Backward LF1 | batch B-1; consumed LA1 50 kg, LB1 30 kg; receipts RA1 (for LA1), RB1 (for LB1) | T1, verified |
| Backward LF2 | batch B-2; consumed LA2 20 kg, LB1 20 kg | T1, verified |
| Forward LA1 | batch B-1 -> LF1 made 80, shipped 25 kg (after release and an issue of 25) | T2, verified |
| Forward LB1 | B-1 -> LF1 (80, shipped 25) and B-2 -> LF2 (40, shipped 0); on hand of LB1 = 50 | T3, verified |
| Shipped by a customer transfer | issue 5 + customer transfer 10 = 15 counted; a plant-internal transfer of 3 not counted | T4, verified |
| Reversed consume | drops out of backward LF2 (consumed empty) and forward LB1 (only B-1); unknown lot gives an empty answer, not an error | T5, verified |
| Tenant isolation | same lot and item in an empty second tenant: empty trace; a bad schema name (`public`, `tenant_x`, an injection string) is refused before any SQL | T6, verified |
| Recipe | units kg and litres stored per line; quantity 40.5 read back exactly; an approved version refuses INSERT, UPDATE, DELETE of a line; a change is version 2; a batch needs an approved version | R1 R2 R3, verified |
| Batch | row holds version id and status; after `finish` consume and produce are refused `batch_finished`, nothing posted | B0 B3, verified |
| Consume | two lots in one call and in two calls: balances 50 / 70 / 80, `related_document_id` = batch id; item or unit not in the recipe refused `not_in_recipe`, nothing posted | B1 B2, verified |
| Produce | LF1 80 on hand, cause `produce`, batch id set, status `quarantine` set BEFORE the posting; an input item as output refused | B4, verified |
| Hold and release | quarantined LF1: issue refused `lot-quarantine`, nothing written; after `released` the issue posts; consume of a quarantined raw lot refused; `rejected` cannot be released and cannot be shipped | H1 H2 H3 H4, verified |
| Liquid | tank = location; item L in litres (1000.5) and item K in kg (20) at one tank, both right; kg on a litre key refused `unit_mismatch`; a blend batch (L litres + K kg in, litres out) gives `%{"l" => in 800 / out 845, "kg" => in 50 / out 0}`, never summed | U1 U2 U3, verified |

## 4. What this shows (and does not)

- The existing ledger already carries what the trace needs: batch id, item, lot, unit, sign, reversal link. **Verified** (T1..T5).
- Recipe line units give "kg or litres per item" and the ledger pins the unit per key, so one key cannot switch unit. **Verified** (R1, U2, U3).
- The finished lot is quarantined before the produce posting, so there is no moment when it counts as released. **Verified**
  (B4 reads the status after produce; the order is in `BatchStore.produce/3`). A forced failure between the two steps was not tested; if
  the posting failed the status row would stay (harmless, **guess**, not run).
- Mass balance is shown per unit. Kg and litres are never added; a density rule is an open owner question (doc 02). **Verified** that nothing sums them (U3).
- Quantity tolerance against the recipe is not enforced (item and unit only). **Verified** by design, not a gap in the proof.

## 5. Limits (what the proof did not do)

- The proof post helper mirrors `HandlerPost` (as in P1); the copy did not go through the real engine, task or HTTP path.
- Lot and batch are test tables and uuids in the ledger key, not real entities: no supplier, no expiry, no label, no lot-to-lot
  attributes. The trace of a lot with no batch is an empty answer, not a "lot exists" check.
- One level only: a finished lot used again as rework is not followed (**guess** that a recursive query would work).
- Shipped = ledger legs only (issue, hand_over, customer transfer using the P1 marker table), not shipping documents.
- The hold rule is P1's guess, used unchanged. Not done: pallets, packaging, QC samples and results, four-eyes release, e-signature,
  density conversion, tolerance, 21 CFR style audit of the release step.
- Speed was not measured. The trace SQL is a plain scan by item and lot over the partition; it has no index made for it. **Guess**
  for large volume.
- Race between release and a posting: covered by P1 (L10); not repeated.
- Shared test cluster: the tests ran on the team's own database on a test tenant; no other data used.

## 6. Core changes needed (design notes only: NOT built, per the stop rule)

1. **Customer-transfer marker** (P1 finding 3): "shipped" and the hold rule on a transfer need a real way to say that a location is a
   customer location. Today the proof uses a test table. A core change (location attribute or a `ship` cause).
2. **Lot as a real stored object with a status** (P1 finding 4): a lot with no status row counts as released. For a real MES the
   produce path must create the lot with `quarantine` in the same transaction as the posting (the proof does it in two steps), and a
   backfill is needed for existing lots. This needs a lot table and a posting-guard change in `lib/` and a migration.
3. **Batch and recipe as real records**: the proof tables are test DDL. Real versions need a module or entity definition, a
   freeze on approval (done here by a trigger, a real build would use the platform's record rules), and the permissions for
   approve and release (who may release is an open owner question).
4. **Trace index and a stored link**: the trace joins on `related_document_id` (text) and `k5`. A real build should decide whether
   to index these (partition-local index on `related_document_id` for `consume` and `produce`) or to read a stored batch table. Not measured.
5. **Consume and produce causes in the real policy** (P1): the real stock policy still lacks them; changing it is a catalog/upgrade
   change with the plan/apply/rollback path P1 checked.

## 7. Open owner questions (unchanged by this proof)

Who may release a lot and with what proof; whether a recipe quantity tolerance is a block or a warning; whether litres and kg
of one product may ever be converted (density); whether rework (a finished lot consumed again) is in the pilot.
