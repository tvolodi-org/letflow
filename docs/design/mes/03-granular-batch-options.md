# MES on Letflow, part 3: granular fertilizer in batches, bagging, three options

Status: **DRAFT** (owner request 2026-11-12, task T-1820, MES-3). Design options only. No code, no client contact, nothing on production, money, DNS, secrets, demo or a public repository.

Written for a reader whose English is a second language: short sentences, tables, a glossary. Part 1 (`docs/design/mes/01-domain-and-fit-gap.md`) has the general glossary and the fit/gap table; this part uses its terms and its row numbers ("row 4" = row 4 of its fit/gap table).

## 1. The question

How do we model on Letflow the **batch production of several granular fertilizer types, packed in bags of different sizes**? Parts: recipe with versions, batch order, raw material consumption by lot, yield and losses, bagging output by bag size and pallet, finished goods lots, QC sample and release (hold/release), and recall/traceability in both directions.

## 2. The process in plain steps (assumption: typical granular plant; the real plant is not known)

| Step | What happens | What must be recorded |
|---|---|---|
| 1 Plan | A batch order: "make 20 t of grade X". | Order number, grade, planned quantity, recipe version. |
| 2 Prepare | Raw materials are taken from the warehouse. | Which raw lots, how much of each. |
| 3 Mix / granulate / dry / screen | Equipment runs the recipe. | Weights, times, readings, equipment used, deviations. |
| 4 Bulk product | Finished product goes to a bulk bin or hopper. | Bulk output quantity; losses (dust, off-size returned). |
| 5 QC sample | A sample is taken and tested (for example nutrient content, moisture, granule size). | Sample id, results against limits. |
| 6 Release or hold | QA says release, hold or reject. | Decision, who, when, why. |
| 7 Bagging | Product is packed in bags of different sizes (for example 25 kg, 50 kg, 500 kg big bags). | Bag size, number of bags, weight, bagging line, finished goods lot. |
| 8 Pallets | Bags go on pallets, each with a label code. | Pallet code, bag size, bag count, lot. |
| 9 Ship | Pallets leave to a customer. | Which pallet went to whom (trace forward). |

Bag sizes and test names above are **examples, not facts about a client** (assumption).

## 3. What we reuse and what we must add

Letflow facts were read on this branch on 2026-11-12 (files named). See also part 1 section 4.

| Need | Reuse on Letflow | File opened | Missing |
|---|---|---|---|
| Raw material, finished goods, bag-size items | Item master with `tracking_policy` (lot), units | `lib/letflow/modules/catalog_items/catalog_items.ex` | Nothing for A. A "pack size" attribute is an open question (part 1, question 6). |
| Lots (raw and finished) | Lot master: code, producer, mark, expiry, retire (never deleted), audited | `lib/letflow/modules/catalog_items/lots.ex` | No quality status on a lot (hold/release); no certificate of analysis. |
| Stock by lot, locations | Append-only ledger, key `[sku, location, org_unit, responsible, lot]`, refuses stock below zero | `lib/letflow/modules/stock/ledger_policy/declare.ex` | The ledger has a **closed list of causes** (moduledoc table: receipt, opening, issue, write_off, kind_change_out, transfer, hand_over, return, count_difference; reversal is a separate command). The moduledoc calls the list an assumption the owner may change. There is no cause "consume into batch" or "produce from batch". |
| Equipment (mixer, dryer, bagging line) | Asset register; location tree | `lib/letflow/modules/assets/assets.ex`, `locations/locations.ex` | No equipment state (running, idle, down, cleaning). |
| Batch steps and four-eyes | Process designer: HUMAN_TASK with form, role and `distinct_from`; a task may call a module write handler | `docs/design/process-designer.md`, `lib/letflow/definitions/graph.ex`, `lib/letflow/engine.ex` | No batch concept; no e-signature object. |
| Pallet and bag labels, scan | Codes: barcode/QR tag assigned to a lot, item or location; Code128; labels | `lib/letflow/modules/codes/codes.ex`, `labels.ex` | No pallet record; no SSCC-style number generator. |
| Documents and print | Versioned documents, numbering, print ru/kk/en, PDF/XLSX | `lib/letflow/documents/` | New layouts (batch report, certificate of quality). |
| Audit | Hash-chained, tamper-evident | `lib/letflow/audit.ex` | Nothing. |
| Module pack | Entity types, handlers, routes, permissions, ledgers per tenant | `lib/letflow/modules/catalog.ex`, `module.ex` | A new module for options B and C. |

## 4. Three options

Sizes S/M/L follow part 1 (assumption: rough, by comparison with the stock and assets modules; nothing was measured). "Effort" gives a range in weeks for one small team: **assumption**, to be replaced after a client talk and a design round.

### Option A: existing stock, lots and documents only (no new module)

Idea: use only what exists. Configure items, lots, stock documents and one process definition. Everything about the batch is done by **convention** (naming, forms), not by new rules.

| Topic | How it is done in option A |
|---|---|
| Recipe and versions | A versioned document (PDF/form) per grade; version number in its name. The system does not check amounts. |
| Batch order | One process instance per batch, started from a form (grade, quantity, recipe version typed in). Batch number = the instance number or the finished lot code. |
| Raw material consumption by lot | An **issue** document per batch, lines with raw lot codes; the ledger refuses stock below zero. The link "this issue belongs to batch B" is only the document reference text. |
| Yield and losses | Issue total minus bulk receipt, calculated by a person (or an XLSX export). |
| Bulk and finished goods | A **receipt** document for the finished lot (one lot per batch per bag size, code such as `B-0412-25`). Bag size = a separate item per size. |
| Bagging by size and pallet | A transfer/receipt per bag size. Pallet = a location (a pallet code as a location) or a code tag on the lot. No pallet record. |
| QC and release | A HUMAN_TASK with a form (results) and a second person (`distinct_from`). **Nothing blocks** moving a lot that is "on hold": the hold is a rule on paper. Workaround: keep held stock in a "quarantine" location and move it by transfer on release. |
| Traceability | By lot code and document references: search documents by lot. Both directions only if people always write the batch number on every document. No tree view. |

| | Option A |
|---|---|
| Effort (assumption) | 1 to 3 weeks: configuration, forms, print layouts, training. No build. |
| Risks | Hold is not enforced (a held lot can be shipped by mistake). Trace backward and forward is manual and breaks when a person forgets a reference. Yield is not computed. Quarantine location is a workaround that people can bypass. Not suitable if the client needs audit-ready batch records. |
| Good for | A first pilot to learn the real process and the real questions. |

### Option B: a batch-record module on top of stock and lots

Idea: a new module "production-batch" with its own record types, **using** items, lots, the stock ledger, codes, documents, process engine and audit. It does **not** model equipment states.

New pieces (each is a gap row of part 1):

| New piece | Content | Part 1 row |
|---|---|---|
| Recipe and recipe version | Grade, version number, status (draft, approved, retired), ingredient lines (item, amount per tonne, tolerance), output item(s), expected yield %, process steps with limits. An approved version is **never edited**; a change makes a new version with a second-person approval. | 2 |
| Batch order | Number, recipe version (frozen copy at release), planned quantity, status flow: planned, released, running, finished, closed. | 3 |
| Batch record | One record per batch that gathers: consumed lots, step readings, equipment used (a link to an asset), deviations, QC results, release decision, output lots, losses. | 12 |
| Consume and produce booking | Two new ledger causes (or two documents on existing causes) tied to the batch id: consume raw lots, produce bulk and finished lots. A consume line is a ledger leg with the raw lot; a produce line has the finished lot. This **changes the closed list of ledger causes** (a decision for the owner, part 1 row 4). | 4, 5 |
| Lot quality status | Status on the lot: quarantine, released, rejected. The ledger posting policy refuses a transfer/issue to a customer of a lot that is not released. | 1, 8 |
| QC sample and result | Sample plan per recipe, sample record, result lines with limits, pass/fail. | 8 |
| Release decision | Hold, release or reject by a QA role; a different person from the sample taker (four-eyes). Reason is required for hold or reject. | 8, 13 |
| Packaging order and pallet | A packaging run takes released bulk, makes finished lots per bag size, and pallet records (pallet code, bag size, bag count, lot). Pallet label uses the codes module. | 9 |
| Genealogy read | Trace backward (finished lot or pallet to raw lots, suppliers) and forward (raw lot to batches, pallets, customers) from the batch rows. A screen and an export. | 5 |
| Roles | Operator, shift lead, QC analyst, QA releaser, as module permissions. | 16 |

How the requested topics work in option B:

* **Yield and losses:** Yield = good output / consumed input. Losses are lines with a reason code (dust, off-size returned to process, spill, sample, bagging rework). The batch record shows the **mass balance**: input = bulk + losses (+ rework). A difference above a tolerance is a deviation.
* **Bag sizes:** One finished item per bag size (25 kg, 50 kg, 500 kg) **or** one item with a pack-size attribute: open owner question (part 1, question 6). A finished lot is made per batch and bag size; the pallet holds a bag count, so the weight check is count x size.
* **Hold/release:** Enforced by the ledger policy, not by convention. A lot in quarantine can be moved only inside the plant (to the bagging line, to a hold area), not shipped. Release is one audited action.
* **Recall:** From a raw lot: list of batches that consumed it, their finished lots, pallets, and shipped quantities (forward). From a customer complaint with a pallet code: the batch and its raw lots and supplier lots (backward). The trace is a query over rows that exist because consume and produce are tied to a batch.

| | Option B |
|---|---|
| Effort (assumption) | About 8 to 14 weeks: recipe, batch, consume/produce on the ledger, lot status and hold rule, QC, packaging and pallets, trace, print, roles, web and mobile screens, tests, security review. Ledger-cause change and lot-status rule are the riskiest parts. |
| Risks | The ledger policy is shared by the stock module: a new cause or a hold rule touches a tenant-data path and needs a security review and care with existing tenants. Scope growth: clients will ask for equipment states and OEE (that is option C). E-signature stays GMP-like unless a legal need appears (part 1, question 4). Bagging line weights typed by hand until a scale or PLC feed exists (part 1, question 2). |
| Good for | A client who needs batch records, hold/release and recall in 2 to 3 months, and runs few machines per batch. |

### Option C: full MES module with equipment states

Idea: option B **plus** equipment as a first-class object with a state machine, and optionally machine data.

Additional pieces on top of B:

| New piece | Content | Part 1 row |
|---|---|---|
| Equipment and states | Equipment type (mixer, granulator, dryer, screen, bagging line, scale), states (running, idle, down, cleaning, changeover), state history with time and reason, link to asset card and location. | 6 |
| Equipment rules in the batch | A step may run only on equipment of the right type, in state idle and clean, within calibration date. A changeover between grades needs a cleaning record. | 6, 12 |
| Downtime and OEE | Downtime reasons (planned/unplanned), OEE = availability x performance x quality per line and shift. | 11 |
| Shift logs | Shift calendar, log, handover. | 7 |
| Machine data | Weights and counts from scales, bagging counters or PLC/SCADA (for example OPC UA), through a gateway. Needs an inbound device feed design and a security decision. | 10 |
| Scheduling | Plan batches and bagging runs on lines with capacity. | 3 |
| Stronger signatures | Re-authentication at signing, signature bound to the record hash. Legal validation only if the client needs it. | 13 |

| | Option C |
|---|---|
| Effort (assumption) | About 20 to 35 weeks, or more if machine data and legal e-signature are in scope. |
| Risks | Largest build before first value. Needs real client data about machines and lines (we have none). Machine feed needs infrastructure and security design (INV-3, INV-4 style review). Risk of building features no client pays for. |
| Good for | A client who already has stable batch records and asks for OEE, line control and machine links. Best reached as a **second phase after option B**, not first. |

### Comparison

| Criterion | A | B | C |
|---|---|---|---|
| Recipe versions with approval | Paper-like (document) | Yes | Yes |
| Batch order and record | Process instance + documents | Yes | Yes |
| Consumption by lot tied to batch | By document reference only | Yes (ledger) | Yes |
| Yield and mass balance | Manual | Computed | Computed, with machine weights if fed |
| Finished lots per bag size and pallets | Items per size, pallet as location | Yes, pallet record | Yes |
| QC sample and results | Form | Yes | Yes |
| Hold/release enforced | **No** (quarantine location by habit) | **Yes** (ledger rule) | Yes |
| Trace both ways | Manual search | Query/screen | Query/screen |
| Equipment states, downtime, OEE | No | No (link to asset only) | Yes |
| Effort (assumption) | 1 to 3 weeks | 8 to 14 weeks | 20 to 35 weeks |
| Main risk | Wrong shipment, manual trace | Touches shared ledger policy | Size, unknowns |

## 5. Recommendation (a proposal for the owner, not a decision)

1. Start with **option A** as a paper-and-forms pilot only if a client wants to learn fast; it needs no build.
2. Plan the build as **option B**. It closes the biggest risk (shipping a held lot) and gives recall.
3. Treat option C as **phase 2**, driven by what the client asks after using B.

Reason: the biggest gaps for batch plants are rows 2, 3, 4, 8 and 13 of part 1; option B closes exactly those. Equipment and machine data (rows 6, 10, 11) depend on facts we do not have.

## 6. Traceability design details (for options B and C)

* **Batch record** is the center. Every consume line and every produce line carries the batch id.
* **Finished lot code** = batch number + bag-size suffix (example only: `B-0412-25`). One lot per batch and bag size, so recall by lot is exact.
* **Backward trace:** pallet code -> finished lot -> batch -> consume lines -> raw lots -> supplier and receipt document.
* **Forward trace:** raw lot -> batches that consumed it -> finished lots -> pallets -> shipping documents -> customer.
* **Mixed pallets** (two lots on one pallet) are allowed only if the pallet record lists each lot with its bag count.
* **Rework** (off-size product returned to the process) is a consume line with the earlier bulk lot, so the tree stays whole.
* **Pallet identifier:** an SSCC is an 18-digit logistic-unit code used on pallet labels (GS1 member pages, see section 8). Whether a client needs SSCC is an open question; the pallet code can be a plain internal number first.

## 7. Client questions (to ask later; no client was contacted)

1. How many grades (types) are made, and how many recipes change per year? Who approves a new recipe version?
2. Is the process fixed (mix, granulate, dry, screen) or does it change per grade? How many machines are in one batch?
3. What is a batch for you: one mixer load, one shift, one day? How big (tonnes)?
4. Which raw materials come in as lots from suppliers? Do you keep supplier certificates and quality results?
5. Which bag sizes exist? Do you pack one batch into several sizes? Is there a big-bag or bulk shipping?
6. How is a pallet built and labelled today (bags per pallet, label, code)? Do customers or retail chains ask for SSCC or a barcode standard?
7. Which tests do you run, how often, and who may release a batch? Is release by one person or two?
8. What happens to off-size, dust and returned product? Is it reused in the next batch?
9. Which weights are measured by machines (scales, bagging counters) and which are typed by hand? Is there a PLC/SCADA system?
10. Do you need to show records to an authority, a certification body or a customer audit (which rules, which country)?
11. How do you handle a complaint or recall today? How fast must you name all affected pallets (hours)?
12. Which ERP or accounting system holds orders and stock? What must flow in and out?
13. Who uses it on the floor: operators with a phone or tablet, or a fixed PC? Which languages (ru, kk, en)?
14. How many batches and bags per day? Is there internet on the floor?

## 8. Sources and what was not verified

* **Letflow facts:** the files named in section 3, opened on this branch on 2026-11-12. One caution: the moduledoc says "the seven causes" but its table lists nine; I did not reconcile the count. The point that matters here, that there is no consume/produce cause, holds for either list.
* **ISA-88 recipe types** (general, site, master, control): a web search on 2026-11-12 returned secondary pages only (Wikipedia [ISA-88](https://en.wikipedia.org/wiki/ISA-88), the IEC PAS 61512-3 catalogue page at [iteh.ai](https://standards.iteh.ai/catalog/standards/iec/689d7d55-6c84-4371-b6be-b4d243fa6403/iec-pas-61512-3-2004), vendor blog). The standard text was **not opened**. Master recipe = approved template; control recipe = one batch: consistent with part 1.
* **SSCC:** 18-digit GS1 identifier of a logistic unit, printed in a GS1-128 barcode on pallet labels: from GS1 member pages ([GS1 Sweden](https://gs1.se/en/standards-and-services/serial-shipping-container-code-sscc/), [GS1 UK](https://www.gs1uk.org/support-training/help-to-use-and-implement-gs1-standards/logistics-labels-and-ssccs)). GS1's own specification was **not opened**.
* **EU fertilising products rule:** the search snippet says Article 6 of Regulation (EU) 2019/1009 requires packaging to carry a type number, batch number or similar element ([legislation.gov.uk copy](https://www.legislation.gov.uk/eur/2019/1009/chapter/II)). I did **not** read the article. Whether a client falls under it (country, export) is unknown: assumption, ask in client question 10. No source was found on how batches must be assigned or tracked.
* **Everything else** (process steps, bag sizes, test names, effort ranges, sizes) is an **assumption** from general knowledge of the domain, not verified with any plant.
* Nothing here was discussed with a client.
