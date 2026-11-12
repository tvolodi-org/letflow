# MES on Letflow, part 7: draft roadmap and a small pilot

Status: DRAFT for the owner. Options and a proposal only. Nothing here is decided. No code, no client contact, nothing on production, money, DNS, secrets, demo or public repo.

Written 2026-11-12. This note builds on parts 1 to 6 in this folder. It adds no new facts from outside. Every size and week figure is an **assumption** (rough, by comparison with the stock and assets modules; nothing was measured). Size scale: **S** = days, **M** = a few weeks, **L** = more than a few weeks (same as part 1, section 5).

## 1. Short answer

| Question | Answer |
|---|---|
| Can we show something to a chemical-plant prospect in 4 to 6 weeks? | Yes, a **paper-and-forms pilot** on existing modules, plus a small build proof. It shows the flow and the traceability idea. It does **not** enforce hold/release. |
| What is the main build path? | Platform option A of part 5 (modules on the existing platform), batch option B of part 3, stream option A then B of part 2. |
| What waits for facts? | Electronics (phase 5) and live machine data (phase 4). |
| What is the biggest unknown? | Whether the stock ledger can get two new causes and a lot status without breaking upgrades (part 5, section 8, point 1). |

## 2. Rules for the roadmap

1. Reuse first: items, lots, stock ledger, locations, codes, assets, process engine, documents, audit, roles (part 1, section 4).
2. Each phase ends with something a person can look at. No phase is "infrastructure only".
3. Machine data stays outside the core until phase 4 (part 5, section 10).
4. A phase starts only when the owner says so. This note does not start anything.
5. Platform rules apply in every phase: tenant isolation, a role per person, audit of every write, no secrets in records (part 4, B4).

## 3. Phases at a glance

| Phase | Name | Weeks (assumption) | Needs from the owner or client | Result |
|---|---|---|---|---|
| 0 | Discovery and demo on existing modules | 4 to 6 | Owner go; client calls are optional and not done | Demo script; thin-slice proof; ledger proof |
| 1 | Batch record for granular production | 12 to 16 after phase 0 | Answers to part 3 section 7 | Recipes, batch, consume/produce, QC, hold/release, trace |
| 2 | Bagging and pallet traceability | 6 to 10 | Bag sizes, pallet rules | Finished lots per bag size, pallets, recall query |
| 3 | Stream and tank model | 8 to 12 | Lot cut for a stream, kg or litres | Tank fills as lots, samples, shift log, mass balance (manual and file input) |
| 4 | Plant data connectors | 12 or more | Plant network access, security design | Import of historian files, then a gateway |
| 5 | Discrete / electronics (only if the client is real) | 16 to 24 | Part 4 questionnaire answered | Serial genealogy, station results, rework |

Total for phases 0 to 3: about 7 to 10 months for one small team (part 5, section 4.6 says 6 to 8 months for the same parts; the range here is wider because phase 2 is counted separately). Phases 4 and 5 are open-ended until facts arrive.

## 4. Phase 0: discovery and demo (4 to 6 weeks)

### 4.1 What the first demo shows (existing modules only)

The demo uses a **fictional** plant. No real client data.

| Demo step | Existing piece used | Source in part 1 |
|---|---|---|
| Raw material master with lot tracking on | Items with `tracking_policy` lot, lots | section 4 |
| Receive a raw material lot into a store location | Stock receipt document with lot | section 4 |
| Tanks, bins, lines as a location tree with scan labels | Locations, codes and labels | section 4 |
| A batch run as a guided process: weigh, mix, sample, release | Process definition with human tasks, forms, validation script | section 4 |
| Second person must approve the release | Four-eyes rule `distinct_from` | section 4 |
| Issue raw lots to production, receive the finished lot | Stock issue and receipt documents | section 4 |
| Printable batch sheet and stock card | Documents and print (ru, kk, en) | section 4 |
| Every step is in the audit chain | Audit | section 4 |
| Entry on a phone at the line | Mobile tier with offline queue | section 4 |

Part 3, option A is this same idea (existing stock, lots and documents only, 1 to 3 weeks).

### 4.2 What the demo must say out loud (what is NOT promised)

| Not promised | Why |
|---|---|
| A held lot **cannot** be shipped | Hold is a habit (a quarantine location), not a rule, until phase 1 (part 3, comparison) |
| Recipes with versions and approval | No recipe record exists (part 1, row 2) |
| Automatic consumption by batch, mass balance | Consume/produce are not ledger causes yet (part 1, row 4) |
| Trace forward and backward by query | Manual search only (part 3, comparison) |
| Machine data, OEE, downtime | No inbound feed, no downtime record (part 1, rows 10 and 11) |
| Electronics serial tracking | Facts missing (part 4) |
| Legal e-signature (21 CFR Part 11, EU Annex 11) | Only GMP-like records are possible; not assumed to apply (part 6) |
| Price, delivery date, support terms | Not part of this note; the owner decides |

### 4.3 Build proofs in phase 0 (internal, not for the client)

From part 5, section 8:

| # | Proof | Size | Pass means |
|---|---|---|---|
| P1 | Ledger proof: add two causes and a lot status to a copy of the stock policy on a test tenant; run the upgrade checks; record what is reported and what happens to other installed modules | M | Result written down, either way |
| P2 | Thin batch slice: recipe version, one batch, consume two raw lots, produce one finished lot, hold and release, trace both ways | M | The trace returns the right lots in both directions |
| P3 | Reading with a `source` field and one file import (part 2 recommendation) | S | Raw tag data stays outside the core |

### 4.4 Effort, risks and exit rule

| Item | Content |
|---|---|
| Effort | Demo set-up 2 to 3 weeks (one analyst and one developer, assumption). Proofs P1 to P3 3 to 4 weeks, partly in parallel. |
| Risk 1 | P1 fails: the shared ledger policy cannot grow safely. Then plan batch option B differently (a separate posting path) or fall back to part 5 option B. |
| Risk 2 | The demo looks like "a form tool", not a MES. Keep the story on traceability and release. |
| Risk 3 | Scope growth into a connector. Do not build one in this phase. |
| Exit rule | The owner reads P1 and decides: continue to phase 1, change the plan, or stop. |

## 5. Phase 1: batch record for granular production (12 to 16 weeks)

Source: part 3 option B, part 5 option A (`mes_core` plus `mes_batch`), part 1 rows 2, 3, 4, 5, 8, 12, 13.

| Build task | Size | Part 1 row | Depends on |
|---|---|---|---|
| Ledger policy: consume and produce causes, lot quality status (hold, released, rejected) | M | 4, 8 | Proof P1 and an owner decision (part 5, open question 2) |
| Recipe and recipe version with ingredient lines, tolerances, approval | M | 2 | none |
| Work order and batch record with number scheme and status flow | M | 3 | Recipe |
| Consumption of raw lots by batch, output lot by batch | M | 4, 5 | Ledger task |
| QC sample, result lines with limits, release/hold/reject decision that blocks stock movement of a held lot | M | 8 | Ledger task |
| Trace forward and backward (routes and one screen) | M | 5 | Consumption |
| Batch report as one printable document (recipe version, materials, steps, deviations, signatures) | M | 12 | Batch, QC |
| Deviation record and signature object with meaning text (GMP-like) | M | 13 | Batch |
| Roles: operator, shift lead, QC analyst, QA releaser | S | 16 | Module permissions |
| Certificate of quality layout per lot | S | 17 | QC |

What the demo can show after phase 1: a held lot is refused at issue and at shipment; trace by query; a batch report.

Risks: the shared ledger policy (the largest); a third copy of the posting code (part 5, 4.6); wrong guess about the real plant process (part 3 section 2 is an assumption).

## 6. Phase 2: bagging and pallet traceability (6 to 10 weeks)

Source: part 3 section 3 and row 9 of part 1.

| Build task | Size | Part 1 row |
|---|---|---|
| Packaging order per bag size (one finished item per size, open point 6 of part 1) | M | 9 |
| Pallet record with a code, its lots, and pack-out booking | M | 9 |
| Pallet label print (reuse codes and labels) | S | 9, 17 |
| Recall query: from a raw lot to every pallet and shipment | M | 5 |
| Bagging-line count and rejects entered by the operator (manual) | S | 7 |

Open fact: whether bagging is batch or continuous (part 6, open questions). If continuous, only the batch steps fit ISA-88 (part 6 assumption).

## 7. Phase 3: stream and tank model (8 to 12 weeks)

Source: part 2, options A and B.

| Build task | Size | Part 1 row |
|---|---|---|
| Tank as location with unit and density rule; stock by mass or volume | S | 15 |
| Lot for a stream (tank fill or time window; owner decides) | M | 1, 5 |
| Reading record with `source` field (manual, file, import, live) | S | 10 |
| Sample plan by time or per fill; results; second-person release | M | 8 |
| Shift calendar, shift log, handover note | S | 7 |
| Mass balance view: in, out, tank change, difference | M | 4, 15 |
| File import of historian exports (second step, only after the client shows a real file) | M | 10 |

Risk: a stream has no natural batch; a wrong lot cut weakens traceability (part 1, section 6).

## 8. Phase 4: plant data connectors (12 weeks or more)

Source: part 2 option C, part 5 sections 4.4 and 10.

| Build task | Size |
|---|---|
| Security design: machine credential, network path, certificates | M |
| Inbound route with rate limit and tenant binding | M |
| Edge gateway for OPC UA or MQTT (runs at the plant) | L |
| Time-series storage decision | M |
| Alarm and limit rules | M |
| Runbook and support model | S |

Needs from the owner: a decision that a service or machine credential type may exist (part 5, open question 4). Only start if the client pays for it and confirms network access. Not designed in detail; part 2 point 5 says time-series storage is open.

## 9. Phase 5: discrete / electronics (16 to 24 weeks, only if the client is real)

Source: part 4 (all of it is a guess until the questionnaire is answered).

| Build task | Size |
|---|---|
| BOM with revision and routing | M |
| Work order with serial range | M |
| Serial unit record, station routing, scan at station | L |
| Test results per unit (entered or scanned), rework loop with limit | L |
| Serial genealogy to component lots | L |
| Machine test-station feed (later, with phase 4) | L |

Do not size or start before questions Q7, Q8 and Q9 of part 4 are answered. Fallback: part 4 option 1 (summary counts, no serials) if the client has no serial tracking.

## 10. What can run in parallel

| Together | Why |
|---|---|
| Phase 0 demo and proofs | Different people |
| Phase 2 and phase 3 | Different tables; both after phase 1 |
| Phase 4 design (not build) with phase 1 | A paper design costs little |

Do not run two tasks that change the stock ledger policy at once (collision on pins and migrations).

## 11. Risks across the roadmap

| Risk | Phase | Mitigation |
|---|---|---|
| Ledger policy change breaks upgrades | 0, 1 | Proof P1 first; stop rule in 4.4 |
| No real plant data; the process is a guess | all | Fictional demo; a paper check with the client when the owner allows it |
| Small team, long calendar | all | Each phase has a stop point |
| Scope growth into connectors or OEE | 3, 4 | Keep machine data outside the core until phase 4 |
| Selling more than the product does | 0 | The "not promised" list (section 4.2) goes into every demo |
| Electronics asked too early | 5 | Questionnaire first |
| Legal signature asked by a regulated client | 1 | Ask early (part 1, open question 4); it moves row 13 from M to L |

## 12. Open questions for the owner (not decided here)

1. Go or no go for phase 0, and who plays the client (no client was contacted).
2. Is MES community (MIT) or corporate (closed) (part 5, open question 1)?
3. May the ledger's closed cause list grow, and may a lot get a quality status (part 5, open question 2)?
4. Is the posting-kernel decision taken before phase 1 (part 5, open question 3)?
5. Lot cut for a stream, and kg or litres (part 1, question 1).
6. Does any client need legal e-signature or long offline work on site?
7. Which ERP, if any, sits above the plant (part 1, question 5)?
8. Electronics: is the client real, and what do they make (part 4)?

## 13. Sources and what was not verified

* All content comes from parts 1 to 6 of this folder, written on this branch on 2026-11-12. I re-read their fit/gap table (part 1, sections 4 and 5), effort table (part 5, section 4.6), prototype list (part 5, section 8), recommendations (parts 2, 3, 4, 5) and the market note (part 6, section 8).
* The demo steps in section 4.1 rely on the module list of part 1 section 4, checked there by file. I did not run these modules again for this note, and I did not test that a demo can be built in 2 to 3 weeks.
* All week and size figures are assumptions. Part 5 gives 6 to 8 months for phases 0 to 3 and part 3 gives 8 to 14 weeks for phase 1 alone; the ranges here are my sum, not a measurement.
* No public source was added in this part. Standards (ISA-95, ISA-88) and market figures remain as in part 6: search snippets only, standard texts not read.
