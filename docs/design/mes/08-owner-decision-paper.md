# MES on Letflow: owner decision paper

**DRAFT for the owner**, 2026-11-12 (T-1825, MES-8). Options only: no code, no client contact, nothing on production, money, DNS, secrets, demo or public repository. Details: parts 1 to 7 of this folder.

| Label | Meaning |
|---|---|
| **[F]** | Checked in part 1 or 5 of this folder on 2026-11-12 (Letflow code and docs). Not re-checked in this paper. |
| **[P]** | Public source, seen 2026-11-12, search snippets only, vendor marketing (part 6). Unverified. |
| **[G]** | Guess. Nothing measured. All weeks and sizes, and all of electronics, are [G]. |

## 1. What a Letflow MES would be

A MES (manufacturing execution system) records what happens on the plant floor: recipe, raw material lots, tank or line, test result, who released the product. A Letflow MES would be a set of **modules on the Letflow platform** [G]. It reuses lots, stock, locations, labels, the process engine, audit and roles [F]. It adds recipes, batch records, quality hold and release, and trace forward and backward [F: missing today]. It does not control machines.

## 2. Options side by side

| Option | Effort [G] | Main risk | Reuse / missing [F] |
|---|---|---|---|
| **A: modules in Letflow** | 4 to 5 months to first batch | Ledger change breaks upgrades; small team | Reuse lots, ledger, audit, tenants. Missing: two ledger causes, lot status |
| B: separate MES service | 7 to 11 months | Copy of the platform; two sources of truth | Reuse little. Same ledger gap, plus a service credential |
| C: integrate a bought MES | 1 to 3 months per client | Fit, licence, selling another product | Documents, audit only |
| **Liquid streams** (3 steps: manual and files, historian files, live PLC) | Medium to large, then +medium | A stream has no natural batch; a wrong lot cut weakens trace | Reuse tanks as locations, ledger, forms. Missing: lot cut rule, readings, mass balance |
| **Granular batch + bagging** (paper and forms; recipe, batch, QC, hold; machine feed) | 1 to 3, 8 to 14, 20 to 35 weeks | Step 2 changes the shared ledger | Reuse items, lots, labels. Missing: recipe, batch record, enforced hold, pallets |
| **Electronics** (lot level; serial and tests; station feed) | 16 to 24 weeks for serial level | We do not know the client | Reuse serial tracking, codes. Missing: unit record, routing, test results |

**Public market [P]:** for fertilizer plants the public offer is thin (general process MES). For electronics it is deep and mature. Prices are rarely public; one vendor source says about USD 0.4 to 1.2 million for a full project (USD 375,000 to 1.2 million in part 6); sources disagree.

## 3. Our recommendation (proposal, not decision) [G]

1. **Option A, in phases.** One database, one audit chain, one tenant model. B and C do not remove the ledger change.
2. **Phase 0 (4 to 6 weeks):** demo on existing modules with a *fictional* plant, plus three internal proofs. The first proof is the ledger change on a test tenant. Then the owner decides: go on, change, or stop.
3. **Then:** granular batch (12 to 16 weeks), bagging and pallets (6 to 10 weeks), streams with manual and file input (8 to 12 weeks).
4. **Wait:** machine connectors until a client pays and gives network access; electronics until a real client answers the questionnaire.
5. **Not promised:** blocking a held lot from shipping, legal e-signature, live machine data.

Reason: the biggest gaps for a batch plant are the same in every option [F: part 1, rows 2, 3, 4, 8, 13]. Part 5 says 6 to 8 months for phases 0 to 3, part 7 says 7 to 10; the difference is how bagging is counted.

## 4. Decisions only the owner can take

| # | Decision | Our default [G] |
|---|---|---|
| 1 | Go for phase 0; who plays the client | Go; internal team; no real client |
| 2 | MES open (MIT) or closed? | Closed modules over the open core |
| 3 | Grow the ledger cause list; lot quality status | Yes, after the first proof succeeds |
| 4 | Decide the posting-kernel record before `mes_core` books | Yes, before phase 1 |
| 5 | Stream lot cut and unit | Tank fill; kg with a density rule |
| 6 | Machine or service credential type | No, not before live data |
| 7 | Legal e-signature (21 CFR Part 11, Annex 11) | No; GMP-like records |
| 8 | Is the electronics prospect real? | No, until questionnaire answered |
| 9 | Contact the chemical plant | The owner sends it; we do not |
| 10 | Price, support, dates | Owner decides; not set here |
| 11 | Cloud or on-premise | Cloud |

## 5. Questionnaire for the chemical plant (one page)

Plain words, about 45 minutes. We will not quote a price or date.

1. Which products: liquid, granular, or both? How many grades? How much per month?
2. How many sites and production lines?
3. How many tanks (raw, middle, product)? Is a product tank filled and emptied at the same time?
4. How do you cut a flow into a unit you can sell and trace: by tank fill, shift or day? Do you sell by mass or volume?
5. How do you measure each input (meter, scale, level)?
6. What is one granular batch: one mixer load, shift or day? How big?
7. Which bag sizes? Several sizes from one batch? Big bags or bulk?
8. How do you build and label a pallet? Do customers ask for a barcode or SSCC (pallet code)?
9. What happens to off-size product, dust and returns?
10. Which tests, how often, own lab or outside? Who releases a batch or tank: one person or two?
11. Do you show records to an authority, certifier or customer? Which rules?
12. How do you handle a recall today? How fast must you name all affected pallets?
13. Which weights and counts come from machines (scales, PLC, SCADA) and which are written by hand?
14. Which ERP or accounting system holds orders and stock? Who uses the system on the floor (phone, tablet, PC), in which languages?
15. How do you record production today? What hurts most: recall, audit, lost time, wrong shipment? What is success after 6 months?

Electronics questions: part 4, Part A.

## 6. What was not verified

[F] rests on parts 1 and 5; code was not re-opened here. [P] rests on part 6 snippets; no new research. [G] covers all weeks, sizes and defaults; nothing was discussed with a client.

**Length (measured):** `wc -w` = 1,168 words (was 1,716). At about 400 words per printed page for table-heavy text, this is about 3 pages. Not rendered to PDF (no renderer used).
