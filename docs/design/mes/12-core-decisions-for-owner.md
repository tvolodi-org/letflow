# MES: core decisions for the owner before phase 1

**DRAFT for the owner**, 2026-11-13 (T-1832, PM D-123 follow-up). Phase 1 (real `mes_core` and `mes_batch`, real stock change) is **not authorized**. This page only collects what needs a core change or an owner choice. No code, nothing real changed. Simple English.

Labels: **[V]** verified by a test in the P1, P2 or P3 final run (docs 09, 10, 11), or by reading the named source. **[G]** guess, nothing measured.

## 1. The decisions

| # | Decision | Why it matters | Options | Our recommendation (default) | Cost if wrong |
|---|---|---|---|---|---|
| 1 | What "no status" on an old lot means, and the backfill | Old lots have no status row. The proof treats "no row" as released: unsafe, a bad old lot is not held [V, 09 s6.4]. The other way blocks all existing stock [V, 09 s6.4]. | (a) no row = released, no backfill. (b) no row = held, backfill first. (c) backfill every old lot with `released`, then no row = held. | **(c).** Backfill once as `released` in the same upgrade, then treat a missing row as held. Needs the owner's word that old stock is trusted. Backfill size about 2 days [G, 09 s8]. | (a) wrong: a bad old lot ships. (b) wrong: all stock stops until the backfill runs. (c) wrong: a bad old lot is marked released by us; the owner must accept that. |
| 2 | How to tell "transfer to a customer" | The guard summary lists balance keys only, no direction [V, 09 s6.3]. The proof used a test table of customer locations [V]. "Shipped" in the trace also needs it [V, 10 s6.1]. | (a) a customer-location marker on the location (small change, no core guard change). (b) a direction in the guard summary (core change). (c) a new `ship` cause. | **(a).** Cheapest, and stock keeps the same guard shape. Revisit (b) only if a second rule needs direction [G]. | (a) wrong: a missed marker lets held stock go out by transfer. (b) wrong: a core change we did not need. (c) wrong: a new cause means another hash change. |
| 3 | One posting guard for count freeze and lot rule | A registration has one guard slot. Stock already uses it for the count freeze [V, 09 s6.2]. | (a) one composed guard: freeze first, then lot rule. (b) a second guard slot (core change). | **(a).** The proof did exactly this [V]. | Low: a guard order bug is caught by the L7 matrix [V]. |
| 4 | The shared posting kernel record (next decision number, 0087 free on main today, re-check) | `mes_core` would be the third user of the posting code. A third copy is the risk named in 05 s4.6 and the kernel note section 7. | (a) write the record first and build on the kernel. (b) copy a third time and merge later. | **(a), before any phase 1 booking** [G on effort]. The record must answer the six questions of section 7 of the kernel note. | (b) wrong: three copies to fix, and each fix is a hash change. |
| 5 | The two new causes (`consume`, `produce`) and the hash and upgrade run on all tenants | Causes change the manifest hash, so a version bump is needed. QA deploys main, so every installed tenant answers `upgrade_required` until U1 and U2 run [V, kernel note s3]. A change of policy code with the same version is not seen by the hash [V, 09 s6.5]. | (a) one module version with both causes, all tenants upgraded by U2. (b) a separate posting path for MES. | **(a).** The proof shows old entries still reconcile, a hash-only difference upgrades with no steps, rollback works [V, 09 s6.6, 6.7, U4]. Not tested: the direction "tenant on real stock, build with new compiled content", and the `assets` module [V, 09 s3, s6]. Run U1 and U2 on a QA copy of every tenant first. | Wrong: tenants blocked on module writes until upgraded; rollback exists [V]. |
| 6 | Unit per tank and per item (kg and litres), and the density rule | The ledger pins one unit per key; kg and litres of different items sit side by side, a mix on one key is refused `unit_mismatch` [V, 10 U1..U3]. A litre level cannot give a mass balance without a density [V, 11 M3]. | (a) unit per item, never convert, a blend shows kg and litres apart. (b) per-item density value, convert on request. | **(a) for phase 1.** Add (b) only when a real plant gives densities. It changes 08 default 5 ("kg with a density rule") to "unit per item, density later" [G]. | (a) wrong: users convert by hand. (b) wrong: a wrong density gives a wrong mass balance. |
| 7 | The hold rule list | Rule used in the proofs is a guess: a lot that is not `released` cannot go out by `issue`, `hand_over`, `consume`, `kind_change_out`, or a `transfer` to a customer location [V as tested; the rule itself is G, 09 s5]. Who may release is open [10 s7]. | (a) the list above. (b) add `produce`-then-use blocks, four-eyes release. | **(a)** as the starting list, plus a new permission to set a status and an audit entry (not designed, 09 s9). Four-eyes only if the plant asks. | (a) wrong: a held lot leaves by a path not on the list; the L7 matrix [V] shows how to test each new path. |

## 2. What P2 and P3 change in the owner paper (08)

| 08 item | What changed | Label |
|---|---|---|
| 3: ledger causes and lot status, "yes after first proof" | P1 passed with limits (guard needs a composed guard, status needs real storage). Default stays yes. | [V] |
| 4: posting kernel record before phase 1 | Unchanged. P1 and P2 both reused one posting helper; a third module still needs the record. | [G] |
| 5: stream lot cut and unit, "kg with a density rule" | P2: kg and litres per item work and are never summed. P3: a litre level is refused without density. Default should be "unit per item, no conversion in phase 1". | [V] |
| 7: no e-signature, GMP-like records | Unchanged. P2 did not build four-eyes release or signatures. | [V] |
| Effort, 05 s4.6 phase 1 (3 to 4 months) | P1 estimate for the real stock change is 4 to 5 weeks for one developer, plus owner decisions. No re-estimate for the rest. | [G] |
| New, not in 08: raw plant data stays outside the core | P3: 7 200 one-second samples became 8 aggregates; the import never wrote to the ledger [V]. The cap of 4 readings per hour is a proof constant and the real value is a plant decision [G]. | [V] / [G] |
| New: customer marker and legacy lot are real open items | Rows 1 and 2 above. | [V] |

## 3. What we need from the owner

Answer rows 1, 2, 4 and 6 (they change the build). Rows 3, 5 and 7 we take as recommended unless the owner says otherwise. Phase 1 starts only after the owner's written go.

Sources opened: docs 09, 10, 11, 08, 05 (s4.2, s4.6), `docs/design/core-extraction-design.md` (s3, s7). Not re-run: the proof tests.
