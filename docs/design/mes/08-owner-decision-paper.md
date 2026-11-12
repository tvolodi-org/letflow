# MES on Letflow: owner decision paper

Status: **DRAFT for the owner.** Written 2026-11-12 (task T-1825, MES-8). Options only. No code, no client contact, nothing on production, money, DNS, secrets, demo or public repository. Details are in parts 1 to 7 of this folder.

**How to read the labels**

| Label | Meaning |
|---|---|
| **[F] Fact checked** | We opened the Letflow code or docs on this branch on 2026-11-12 (part 1, section 4; part 5, section 3). |
| **[P] Public source** | Seen on a web page on 2026-11-12. Search snippets only, pages not read in full. Vendor marketing. Treat as unverified (part 6). |
| **[G] Guess** | Our own reading or estimate. Nothing was measured. All weeks and sizes are [G]. Everything about electronics is [G]. |

## 1. What a Letflow MES would be

A MES (manufacturing execution system) records what happens on the plant floor: which recipe, which raw material lots, which tank or line, which test result, who released the product. A Letflow MES would be a set of **modules on the Letflow platform** [G: our proposal]. It would reuse lots, stock, locations, labels, the process engine, documents, audit and roles that already exist [F]. It would add recipes, batch records, quality hold and release, and trace forward and backward [F: these are missing today]. It would not control machines. Machine data stays outside the core at first.

## 2. Options side by side

All weeks are [G]. Size: S = days, M = a few weeks, L = more than a few weeks.

| Option | What it is | Effort [G] | Main risk | We can reuse [F] | Missing [F] |
|---|---|---|---|---|---|
| **Platform A: modules in Letflow** (part 5) | `mes_core`, `mes_batch`, `mes_stream` on the module system | 4 to 5 months to first batch, including a prototype | Stock ledger change breaks upgrades; small team | Lots, ledger, audit, tenants, modules | Two new ledger causes, a lot status |
| Platform B: separate MES service | New service next to Letflow | 7 to 11 months | Copy of the platform; two sources of truth | Little | Same ledger change, plus a service credential |
| Platform C: integrate a bought MES | Letflow keeps documents only | 1 to 3 months per client | Fit, licence, selling someone else's product | Documents, audit | Everything else is the vendor's |
| **Liquid streams** (part 2) | A: manual entry and files, then B: historian files, then C: live PLC link | A: M to L; B: +M; C: L or more | A stream has no natural batch; a wrong lot cut weakens trace | Locations (tanks), ledger, forms, process engine | Lot cut rule, readings record, mass balance, samples, shift log |
| **Granular batch plus bagging** (part 3) | A: paper and forms; B: recipe, batch, QC, hold, trace; C: equipment, OEE, machine feed | A: 1 to 3 weeks; B: 8 to 14 weeks; C: 20 to 35 weeks | B changes the shared ledger | Items, lots, documents, codes and labels | Recipe, batch record, consume/produce, enforced hold, pallets |
| **Electronics** (part 4) | 1: lot level; 2: serial genealogy and tests; 3: station feed | 16 to 24 weeks for serial level (phase 5) | We do not know the client | Item `serial` tracking, codes, locations, process engine | Serial unit record, station routing, test results, rework |

**Public market view [P, 2026-11-12]:** for fertilizer and agro-chemical batch plants the public offer is thin; vendors sell a general process MES (recipes, batch record, lot genealogy, weighing, labels). For electronics the offer is deep and mature (SMT line links, serial and component trace). Price is rarely public; estimates run from about USD 50 per user per month to USD 0.4 to 1.2 million for a full project; sources disagree (part 6, sections 2 to 4).

## 3. Our recommendation (a proposal, not a decision) [G]

1. **Platform option A**, in phases. It keeps one database, one audit chain and one tenant model. B and C do not remove the ledger change that A needs.
2. **Phase 0 first (4 to 6 weeks):** a demo on existing modules with a *fictional* plant, plus three internal proofs. The first proof is the ledger change on a test tenant. The owner reads the result and decides to go on, change the plan, or stop (part 7, section 4).
3. **Then chemical batch:** granular batch record (option B, 12 to 16 weeks), then bagging and pallets (6 to 10 weeks), then streams and tanks (8 to 12 weeks, manual and file input).
4. **Machine connectors and electronics wait.** Machine data only when a client pays and gives network access. Electronics only when a real client answers the part 4 questionnaire.
5. **Always say what is not promised:** a held lot cannot yet be blocked from shipping; no legal e-signature; no live machine data.

Reason: the biggest gaps for a batch plant (recipe, batch, consume/produce, quality release) are the same in every option. Machine data only improves them [F: part 1 rows 2, 3, 4, 8, 13].

## 4. Decisions only the owner can take

| # | Decision | Our default [G] |
|---|---|---|
| 1 | Go or no go for phase 0, and who plays the client | Go; internal team plays the client; no real client contacted |
| 2 | Is MES community (MIT) or corporate (closed)? | Corporate (closed modules over the open core is an allowed direction [F, part 5]) |
| 3 | May the stock ledger's closed cause list grow, and may a lot get a quality status? | Yes, but only after proof P1 succeeds on a test tenant |
| 4 | Decide the posting-kernel record before `mes_core` books into the ledger | Yes, decide before phase 1 |
| 5 | Lot cut for a stream: tank fill, shift or time window; kg or litres | Tank fill; kg with a density rule |
| 6 | May a machine or service credential type exist (needed for live data)? | No, not before phase 4 |
| 7 | Do we need legal e-signature (21 CFR Part 11, EU Annex 11)? | No; GMP-like records only |
| 8 | Is the electronics prospect real? | Treat as not real until the questionnaire is answered |
| 9 | May we contact the chemical plant with the questionnaire (section 6)? | The owner sends it; we do not |
| 10 | Price, support terms, delivery dates | Not set here; the owner decides |
| 11 | Cloud or on-premise for a plant client | Cloud; on-premise only if a client needs long offline work |

## 5. Questions for the prospects (short list)

Chemical plant: lot cut for a stream, bag sizes, who releases a batch, which machine data exists, which ERP. Electronics: what they make, serials per day, test stations, regulated customers. Full lists: part 2 section 7, part 3 section 7, part 4 Part A.

## 6. Questionnaire for the chemical plant (one page)

Plain words. Write your answers next to each question. About 45 minutes. We will not quote a price or a date on this call.

**Your plant**

1. Which products do you make? Liquid, granular, or both? How many grades?
2. How much do you make per day or per month (tonnes or cubic metres)?
3. How many sites and production lines do you have?

**Liquid fertilizer (flowing process)**

4. How many tanks do you have (raw, middle, product)? Is a product tank filled and emptied at the same time?
5. How do you cut the flow into something you can sell and trace: by tank fill, by shift, by day?
6. Do you sell by mass or by volume? Do you use a density table?
7. How do you add each input (meters, weigh cells, change of level)?

**Granular fertilizer (batches and bagging)**

8. What is one batch for you: one mixer load, one shift, one day? How big?
9. Which bag sizes do you fill? Do you fill several sizes from one batch? Do you use big bags or bulk?
10. How do you build and label a pallet? Do customers ask for a barcode or SSCC (pallet label code)?
11. What happens to off-size product, dust and returns? Is it used again?

**Quality and release**

12. Which tests do you do, how often, and where (own lab or outside)?
13. Who may release a batch or tank? One person or two?
14. Do you keep supplier certificates for raw materials?

**Records, audit and recall**

15. Do you show records to an authority, a certification body or a customer? Which rules?
16. How do you handle a complaint or recall today? How fast must you name all affected pallets?

**Machines and other systems**

17. Which weights and counts come from machines (scales, bagging counters, PLC, SCADA)? Which are written by hand?
18. Which ERP or accounting system holds orders and stock? What must go in and out?
19. Who will use the system on the floor: operators with a phone, tablet or fixed PC? Which languages (ru, kk, en)?

**Today and tomorrow**

20. How do you record production today (paper, Excel, a system)? What is your biggest pain: recall, audit, lost time, wrong shipment?
21. What would "success after 6 months" look like for you?

## 7. Sources and what was not verified

* **[F]** Letflow facts come from parts 1 and 5 of this folder, which opened the module, stock, ledger and security files on this branch on 2026-11-12. I did not re-open the code for this paper; I re-read parts 1 to 7 only (fit/gap table, comparison tables, recommendations, roadmap).
* **[P]** Public facts come from part 6 (search snippets, 2026-11-12; ISA-95 and ISA-88 texts were not read). No new web research was done for this paper.
* **[G]** All weeks, sizes and defaults in sections 3 and 4 are assumptions. Part 5 gives 6 to 8 months for phases 0 to 3 and part 7 gives 7 to 10 months; the difference is how bagging is counted. Nothing was discussed with a client.
