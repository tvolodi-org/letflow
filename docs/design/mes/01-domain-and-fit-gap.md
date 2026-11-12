# MES on Letflow, part 1: domain note, glossary, fit/gap

Status: **DRAFT** (owner request 2026-11-12, task T-1818). Design options only. No code, no client contact, nothing on production, money, DNS, secrets, demo or a public repository.

Written for a reader whose English is a second language: short sentences, tables, a glossary.

## 1. What is a MES, in plain words

A MES (Manufacturing Execution System) is the software that runs on the plant floor between the business system (ERP: orders, money, purchasing) and the machines (PLC / SCADA: valves, motors, sensors). It answers four questions all day:

1. **What do we make now, and how?** (work order, recipe)
2. **What went into it, and who did what?** (materials, lots, people, equipment, records)
3. **Is it good?** (quality samples, release or reject)
4. **Where is it now?** (stock, pallets, genealogy)

Standards, in one line each (assumption: summarised from general knowledge; the standards texts are paid or long and were **not opened** for this note, see section 8):

| Standard | What it gives us |
|---|---|
| ISA-95 (IEC 62264) | Levels of a plant: 0 process, 1 sensors, 2 control (PLC/SCADA), **3 MES (this note)**, 4 ERP. It also names MES activities: production, quality, inventory, maintenance operations. |
| ISA-88 (IEC 61512) | Words for batch production: recipe (general, site, master, control), unit, phase, equipment. Master recipe = the approved "how to make it". Control recipe = one copy for one batch. |
| GMP-like record keeping | Good Manufacturing Practice style: every step is recorded, records are not changed silently, changes show who/when/why, release needs a second person. Here only "GMP-like": no claim of legal validation (21 CFR Part 11 / EU Annex 11 are **not** claimed). |

## 2. The three production styles

| Style | Example prospect | How material flows | What matters most |
|---|---|---|---|
| **Process (continuous liquid)** | Liquid fertilizer as a stream | Raw material tanks, a stream, product tanks. No natural "piece". | Tank levels and tank state, flow/dosing totals, product grade per tank, sampling every N hours, shift log, downtime. A "lot" is a time window or a tank fill. |
| **Batch (granular + bagging)** | Granular fertilizer, several grades, bags of different sizes | A recipe makes a defined batch; then product is packed into bags and put on pallets. | Recipe per grade, batch record, sample and release per batch, bag size/pallet, lot genealogy from raw material to pallet. |
| **Discrete (electronics)** | Electronic device maker (**needs clarification**, see section 7) | Individual units (serial number), a BOM, routing through stations. | Work order, BOM, serial numbers, station results (test pass/fail), rework, component lots, traceability per serial. |

## 3. Glossary

| Term | One-line meaning |
|---|---|
| MES | Software that runs and records production on the floor. |
| ERP | Business system: orders, purchases, money. Outside this design. |
| PLC / SCADA | Machine controllers and their screens. Outside this design; we may read from them later. |
| Recipe / formula | The approved list of materials, amounts, steps and limits for one product. |
| Master recipe | The approved recipe. Changing it needs a new version and an approval. |
| BOM (bill of materials) | The list of parts for one unit of a discrete product. |
| Routing | The ordered list of stations a discrete unit passes. |
| Work order | An order to make a quantity of a product by a date. |
| Batch | One run of a recipe that gives one uniform quantity of product. |
| Lot | A traceable quantity of material that was made or received together. A batch usually gives one lot. |
| Serial number | A unique number of one single unit (discrete). |
| Genealogy | "What went into what": the tree from a finished lot or serial back to raw lots, and forward to customers. |
| Trace forward / backward | Forward: where did this raw lot go? Backward: what is inside this product? |
| Equipment / unit | A machine, tank, line or station, with a state (running, idle, down, cleaning). |
| Shift log | Notes and numbers of one work shift: who, what happened, handover. |
| QC sample | A small amount taken to test quality. |
| Release / hold / reject | The quality decision that lets a lot be shipped, stops it, or scraps it. |
| Packaging / pallet | Packing product into bags or boxes, and bags onto pallets with a code (SSCC-like pallet label). |
| OEE | Overall Equipment Effectiveness = availability x performance x quality. |
| Downtime | Time a machine could run but does not, with a reason. |
| EBR / eBR | Electronic batch record: the full record of one batch (materials, steps, readings, deviations, signatures). |
| E-signature | A recorded approval by a named user, with time and meaning ("approved", "checked"). |
| Deviation | A step that did not go as the recipe says. It must be recorded and judged. |
| Four-eyes | Two different people must act (maker and checker). |

## 4. What Letflow has today (checked in the code on this branch, 2026-11-12)

Every row names a file I opened. "Moduledoc" means the first lines of the file.

| Platform piece | What it does | Where |
|---|---|---|
| Item, unit, supplier masters | Items with `kind` (material/service) and `tracking_policy` (none, lot, serial, expiry); units of measure; suppliers. | `lib/letflow/modules/catalog_items/catalog_items.ex` |
| **Lot master** | Lot per item: unique code, producer, mark, expiry date, retire (never delete), audited writes, import. | `lib/letflow/modules/catalog_items/lots.ex` |
| `validate_capture/3` | Checks lot/serial/expiry against an item's tracking policy. Its moduledoc says "nothing calls it yet". | `lib/letflow/modules/catalog_items/catalog_items.ex` |
| **Stock ledger** | Append-only ledger with legs; key is sku, location, org unit, responsible, **lot**; seven causes; refuses stock below zero (`insufficient_stock`); reversal; reconcile. Documents: receipt, transfer, hand over, return, issue, write-off, count. Numbering, print in ru/kk/en. | `lib/letflow/modules/stock/stock.ex`, `stock/ledger_policy/declare.ex`, `lib/letflow/ledger/` |
| Stock counts | Count orders, sheets, differences, posting of differences. | `lib/letflow/modules/stock/counts.ex`, `count_posting.ex` |
| Location tree | Free-depth tree of locations (site, area, tank, bin), scannable address, org-unit links. | `lib/letflow/modules/locations/locations.ex` |
| Codes | Barcode/QR/EPC tags, assignment to a location, item or lot, history, scan resolve. Code128 and labels. | `lib/letflow/modules/codes/codes.ex`, `code128.ex`, `labels.ex` |
| Assets | Asset register with ledger, commission, change of responsible, hand over, write-off, reminders (expiry). Usable as a base for **equipment** records. | `lib/letflow/modules/assets/assets.ex` |
| Org | Org units, people. | `lib/letflow/modules/org/org.ex` |
| **Process designer / engine** | Definitions as a graph: START, END, HUMAN_TASK (role, form, validation script, `distinct_from` four-eyes rule), SERVICE_TASK, gateways, TIMER, SUB_PROCESS; a task can call a module write handler (`module_writes`). Instances and tasks. Visual diagram and editor. | `docs/design/process-designer.md`, `lib/letflow/definitions/graph.ex`, `lib/letflow/engine.ex` |
| Documents | Versioned documents with numbering, print layouts, PDF/XLSX, retention and holds. | `lib/letflow/documents/` |
| **Audit** | Immutable, hash-chained audit entries per tenant (tamper-evident). | `lib/letflow/audit.ex` |
| Event store / records | Generic entity records with history, field policy, idempotency. | `lib/letflow/entities/`, `lib/letflow/event_store.ex` |
| Module system | A module = pack of entity types + handlers + routes + permissions + ledgers; install per tenant. | `lib/letflow/modules/catalog.ex`, `module.ex`, `installs.ex` |
| Scheduling, notifications, webhooks, scripts | Scheduled jobs, e-mail/notification templates, outbound webhooks, sandboxed scripts. | `lib/letflow/scheduled_jobs/`, `lib/letflow/notification_templates.ex`, `lib/letflow/webhooks.ex`, `lib/letflow/sandbox_pool.ex` |
| Web / mobile | React SPA with module screens (assets, stock, catalog, codes, locations, org, exam); Flutter mobile tier with an offline queue. | `web/src/modules/`, `apps/mobile/` |

Searches that found **nothing** (so "not on Letflow"): `grep -rli "oee\|downtime\|recipe\|formula\|bill of material\|work order" lib` hit only unrelated design notes and docs (no module); `ls priv/modules` lists assets, catalog_items, codes, exam, locations, org, stock only (no production module). Electronic signature: the only "signatory" feature is a printed name block on exam certificates (`lib/letflow/modules/exam/certificate_document.ex`), not an approval signature. The four-eyes rule `distinct_from` and the audit chain are the nearest existing pieces.

## 5. Fit/gap table

Size: S = days, M = a few weeks, L = more than a few weeks (assumption: rough, by comparison with the stock and assets modules; no estimate was measured). Needed by: **L** = liquid/process, **B** = batch/granular, **D** = discrete.

| # | Function | Needed by | Exists on Letflow (where) | Gap | Size |
|---|---|---|---|---|---|
| 1 | Material master and lot traceability: receive a lot, keep lot code, expiry, supplier | L, B, D | Items, lots, suppliers (`catalog_items`); stock receipt with lot in the ledger key | Lot is optional on lines; `validate_capture/3` is not yet called by the posting; no certificate-of-analysis of the supplier lot; no "quarantine" status of a lot | S |
| 2 | Recipes / formulas (versioned, approved) and BOM | L, B (recipe), D (BOM + routing) | Nothing. Versioned documents and the process definition format are close in spirit | New record types: recipe, recipe version, ingredient lines with amount and tolerance, BOM with revision, approval of a version. Reuse the document versioning idea | M |
| 3 | Work orders and batches | L (run/campaign), B (batch), D (work order) | Process engine can run steps; no production order concept | Work-order record, batch record with number scheme, status flow (planned, released, running, done, closed), link to recipe version. Uses engine definitions per type | M |
| 4 | Material consumption and production output (booking into/out of the ledger) | L, B, D | Stock ledger with issue and receipt causes, lot in the key | Two new causes or documents: consume (raw lots by batch) and produce (output lot). The ledger policy is closed to seven causes, so this changes the ledger policy | M |
| 5 | Genealogy (what went into what) | L (weak: tank mixing), B, D | Lot in every leg; audit chain; documents. No link "batch consumed lot A, produced lot B" | Consumption and output rows tied to one batch give the tree; read routes for trace forward/backward; screen | M |
| 6 | Equipment and its state | L, B, D | Asset register (cards, ledger, responsible); location tree (can hold tanks, lines, stations) | Equipment type with state (running, idle, down, cleaning), state history with time and reason, link to location. Calibration/maintenance dates can reuse asset reminders | M |
| 7 | Shift logs and handover | L, B, D | Generic records and HUMAN_TASK forms can hold it; no shift concept | Shift calendar, shift log record (entries, readings, handover note, signature of the shift lead), mobile entry | S |
| 8 | Quality control: samples, results, release / hold / reject | L, B, D | Forms and validation scripts; four-eyes rule; stock has no quality status | Sample plan (every N hours / per batch), sample record, result lines with limits, pass/fail, **lot release decision** that blocks stock movement of a held lot | M |
| 9 | Packaging and pallets (bag sizes, pallet label) | B (D: boxes) | Codes module (labels, assignment to a lot, scan); stock transfer | Packaging order per bag size (finished-goods item per size), pallet record with SSCC-style code and its lots, pack-out booking; label print for pallets | M |
| 10 | Process data from machines (tank levels, flow totals, weights) | L (strong), B | None. Webhooks and scripts exist for outbound; no inbound device feed | Decide first: manual entry only (S) or a gateway reading PLC/SCADA/OPC UA data (L, infra and security design needed) | S manual, L automatic |
| 11 | OEE and downtime | L, B, D | Timer nodes, scheduled jobs, reports in assets; nothing on downtime | Downtime record with reason codes (from equipment state history), planned/unplanned, OEE calculation (needs counts of good/bad output), reports | M |
| 12 | Electronic batch record (EBR) | B, L, D (device history record) | Audit chain, documents with PDF print, retention and hold, process engine with step history | A batch record view that gathers recipe version, materials, steps, readings, deviations and signatures; one printable document | M |
| 13 | E-signatures (meaning, name, time) and deviations | B, L, D | `distinct_from` four-eyes; audited user actions; no signature object | Signature record bound to a step and the record hash, with meaning text; re-authentication at signing; deviation record with review. GMP-like only, not legally validated | M |
| 14 | Serial numbers and station results (test, rework) | D only | `tracking_policy` has `serial`; codes can hold a tag per serial | Serial unit record, station routing, test results per unit, rework loop, serial genealogy to component lots | L |
| 15 | Inventory by location and counts | L, B, D | Stock ledger, count documents, location tree | Tank/bin as location with unit of measure kg/L and density; liquid stock by volume vs mass (needs a decision) | S |
| 16 | Roles, tenant isolation, audit | all | Role charter, schema per tenant, audit chain (`docs/roles.md`) | New roles (operator, shift lead, QC analyst, QA releaser) as module permissions | S |
| 17 | Reports and print (batch report, certificate of quality, stock cards) | all | Document printing in ru/kk/en; XLSX export | New layouts; certificate of quality per lot | S |
| 18 | ERP link (orders in, results out) | all | Import by external reference; webhooks | Mapping to the prospect's ERP: unknown | M, unknown |

## 6. Summary of the fit

* **Good fit (reuse):** lots and items, the stock ledger with lot in its key, locations, codes and labels, assets as equipment base, documents and print, audit chain, process engine with four-eyes, modules, roles, mobile offline.
* **Biggest gaps:** recipes and BOM (2), work orders and batches (3), consume/produce booking (4), quality release (8), e-signature (13). Together they are the core of a first usable MES for the **batch** style.
* **Liquid streams** are the weak spot for lots: a stream has no natural batch. The usual answer is "lot = a tank fill or a time window". This is a design choice, listed in section 7.
* **Discrete** needs serial-level tracking (14), the largest single gap, and the prospect is not yet understood.

## 7. Open questions for the owner (not decided here)

1. Liquid: what is the lot for a stream: a tank fill, a shift, or a fixed time window? Is stock kept in kg, litres or both (density)?
2. Machine data: manual entry first, or a PLC/SCADA/OPC UA feed from day one? (Security and infrastructure decision.)
3. Electronics prospect: what is made (boards, finished devices), how many serials per day, which station tests, is there a regulated customer (medical, automotive)? Only then size row 14.
4. Does any prospect need legal e-signature (21 CFR Part 11 / EU Annex 11) or only GMP-like records? This changes row 13 from M to L.
5. Which ERP, if any, sits above?
6. Bag sizes: one item per bag size, or one item with a pack-size attribute?

## 8. Sources and what was not verified

* Letflow facts: the files in section 4, opened on this branch on 2026-11-12.
* ISA-95 / IEC 62264 and ISA-88 / IEC 61512: public overview pages of ISA (isa.org) and IEC (iec.ch) describe them; I did **not** open them in this task (no web access was used). The one-line summaries in section 1 are **assumptions from general knowledge**, to be checked against the public pages before the note leaves the team.
* GMP / 21 CFR Part 11 / EU Annex 11: named only; not summarised in detail. Assumption: "GMP-like" means the list in section 1.
* Sizes S/M/L: assumption, not measured.
* Nothing here was discussed with a client.
