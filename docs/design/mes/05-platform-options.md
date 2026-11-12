# MES on Letflow, part 5: where does MES live on the platform? Three options

Status: **DRAFT** (owner request 2026-11-12, task T-1822, MES-5). Design options only. No code, no client contact, nothing on production, money, DNS, secrets, demo or a public repository.

Written for a reader whose English is a second language: short sentences, tables, a glossary. Other parts: part 1 `01-domain-and-fit-gap.md` (glossary, fit/gap rows 1 to 18), part 2 `02-liquid-streams-options.md` (liquid streams, data-in options), part 3 `03-granular-batch-options.md` (granular batches), part 6 `06-market-and-standards-scan.md` (market, ISA-95/ISA-88). "Row N" = row N of the part 1 fit/gap table.

## 1. The question

Where does a MES live on the platform?

| Option | Short name | In one line |
|---|---|---|
| A | **In-platform modules** | New Letflow modules (`mes_core`, `mes_batch`, `mes_stream`, `mes_discrete`) on the existing module manifest and upgrade chain. |
| B | **Separate service** | A MES service next to Letflow, talking to it through the API and events. |
| C | **Integrate** | Use an existing open MES or historian product; Letflow only adds documents, forms and process steps around it. |

## 2. Extra words used here

| Term | Meaning |
|---|---|
| Module manifest | The description of a Letflow module: id, version, record types, handlers, permissions, ledgers. Hashed by `Letflow.Modules.ManifestHash`. |
| Upgrade chain U1 to U4 | Dry-run plan, apply, 409 `upgrade_required` refusal, boot-time upgrade (off by default). See `docs/design/core-extraction-design.md` section 3. |
| Community / corporate edition | The planned open (MIT, owner decision D-116) and closed parts of Letflow. See `docs/uat/ba-decisions/T-1521.md` section 1. |
| Historian | A store of time-stamped machine values (tank levels, flows). |
| Edge gateway | A small program inside the plant network that reads machine data and sends it out. |
| Time series | Many values of one tag over time (for example a level every 10 seconds). |
| Tenant | One client company in Letflow, with its own database schema. |
| Genealogy | "What went into what", forward and backward (part 1, section 3). |

## 3. What the platform gives today, and what it does not (facts checked on this branch, 2026-11-12)

| Topic | Fact | File opened |
|---|---|---|
| Module contract | A module has `manifest/0` (required), `router/0`, `on_install` (optional). Its routes mount under `/api/v1/modules/<id>`. Permissions are declared in the manifest and routed by the owner module. | `lib/letflow/modules/module.ex` |
| Module dependencies | `stock` depends on `catalog_items, codes, locations, org`; `assets` depends on `catalog_items, locations, org, stock`. A MES module would list the same ones. | `lib/letflow/modules/stock/stock.ex`, `assets/assets.ex` (`depends_on`) |
| Manifest hash | Covers id, version, entity types, scope declarations, reference targets, the whole `ledger` map (policy module and function) and each write handler. A change makes every installed tenant answer 409 on module writes until U1 and U2 run (U4 off by default). | `docs/design/core-extraction-design.md` section 3 (opened; `manifest_hash.ex` is named there) |
| Tenant isolation | Schema per tenant (`:prefix`), `tenant_id` also kept inside each schema (INV-1). | `docs/agents/instructions/security-invariants.md`, decision 0003 as cited there |
| Stock ledger | Lot is in the key. Causes are a **closed list** with no "consume" or "produce". | `lib/letflow/modules/stock/ledger_policy/declare.ex` (as read in part 3) |
| Open/closed split | Core and generic modules (org, locations, catalog_items, codes, stock, assets) are community; exam and procurement are closed. "The community edition never contains a call to closed code; the corporate edition adds, it does not patch." Closed to open is allowed. | `docs/uat/ba-decisions/T-1521.md` section 1 and 4; `core-extraction-design.md` section 4 |
| Shared posting code | The document and posting kernel of stock and assets (about 1000 lines) is HELD for a decision record; a new module that posts to the ledger is a third user of it. | `core-extraction-design.md` section 7 |
| Outbound events | `Letflow.Webhooks` delivers outbound webhooks (create, list, update, delete, deliver). Tenant-controlled URLs are validated. | `lib/letflow/webhooks.ex`, `webhooks/url_validator.ex` |
| Inbound data | `Letflow.IntegrationMappings`: stored, declarative payload mappings, direction inbound or outbound, at most 100 rules; **a mapping only; no connector**. No inbound device-feed route was found (part 2 section 4 says the same). | `lib/letflow/integration_mappings.ex` |
| Event store | Events table with monthly partitions and whole-partition retirement. It is the platform event log, not a time-series store. | `lib/letflow/event_store/partition_maintenance.ex` |
| Time series | None found (part 2 states "the platform has none today"). | part 2 section 5 |
| Offline | The Flutter mobile app has an offline queue (stock document form). Web has no offline mode (assumption: not checked in this task). | `apps/mobile/lib/app.dart`, `features/stock/documents/document_form_screen.dart` (names matched by grep "offline"; not read in full) |
| Multi-site | Location tree of free depth (site, area, tank, bin) and org units, inside one tenant. | `lib/letflow/modules/locations/locations.ex` (part 1) |
| Process engine | Definitions as graphs with HUMAN_TASK, four-eyes `distinct_from`, SERVICE_TASK, module write handlers. | `docs/design/process-designer.md` |
| Audit | Hash-chained entries per tenant. | `lib/letflow/audit.ex` |

Facts I could not verify: how many events per second the platform sustains; whether a machine or service credential type exists for a gateway (none was looked for in depth; a grep of `lib/letflow/identity*` and `lib/letflow/api` for "api_key", "service_account", "machine" found no file name match; this is **not** proof). Both are open questions (section 10).

## 4. Option A: new modules on the existing manifest and upgrade chain

### 4.1 Module set

| Module | Content | Part 1 rows | Depends on |
|---|---|---|---|
| `mes_core` | Equipment (links to asset cards and locations), recipe and BOM with versions, work orders, batch record, consume and produce booking, lot quality status, QC sample and release, genealogy read, shift log, roles | 2, 3, 4, 5, 6, 7, 8, 12, 13, 16, 17 | `catalog_items, codes, locations, org, stock, assets` |
| `mes_batch` | Granular batch specifics: packaging order, bag sizes, pallets (SSCC-like code), recall report (part 3 option B) | 9 | `mes_core` |
| `mes_stream` | Tanks as locations with level and density, readings with `source`, transfer with time span, mass balance, lot = tank fill or window (part 2) | 10, 15 | `mes_core` |
| `mes_discrete` | BOM with revision, routing, serial unit, station result, rework, serial genealogy (row 14); electronics product still unclear | 14 | `mes_core` |

Splitting by production style keeps a client from installing what it does not use. `mes_core` is the one that must be right first.

### 4.2 What changes in the core

| Change | Why | Cost and risk |
|---|---|---|
| New causes "consume into batch" and "produce from batch" in the **stock ledger policy** | Row 4. Without them, consumption is not tied to a batch. | Changes the `ledger` part of the stock manifest, so the manifest **hash changes**: version bump and a U1/U2 run on every installed tenant (`core-extraction-design.md` section 3). On a tenant-data path: security review (INV-1, INV-6). Open owner question already raised in part 1 row 4 and part 3. |
| Lot quality status and a "hold blocks shipment" rule | Row 8. | Same hash and review. Alternative to avoid touching stock: MES module keeps its own hold list and a transfer guard; weaker, because stock itself would not refuse. Needs a design round. |
| No new core feature for the others | Equipment, recipe, batch, QC, pallets are new record types **inside** the new modules. | New modules install fresh: no upgrade run for existing tenants. |
| Posting code | A third user of the shared posting kernel. | Do not copy a third time. Wait for, or take part in, the kernel decision record (`core-extraction-design.md` section 7, "next free number 0087, re-check"). Real dependency on the stream CORE-2. |
| Optional: a `mes_core` callback or "document kind" | Possible later. | Not needed for a first slice. |

### 4.3 Data model sketch

Entities (record types): `equipment` (type, state, link to asset, location), `equipment_state_change`, `recipe`, `recipe_version` (status: draft, approved, retired), `recipe_line`, `work_order`, `batch`, `batch_consume_line` (raw lot, quantity), `batch_output_line` (finished lot, quantity, bag size), `qc_sample`, `qc_result_line`, `release_decision` (hold, release, reject, reason, two people), `pallet`, `pallet_line`, `shift_log`, `shift_log_entry`, `reading` (tag, value, time, `source`, quality flag), `downtime`, `serial_unit`, `station_result`.

Events the modules would emit (**no producer exists yet; each needs the module built first**): `batch.released`, `batch.completed`, `lot.status_changed`, `qc.result_recorded`, `release.decided`, `pallet.closed`, `equipment.state_changed`, `downtime.started`. They go to the audit chain and, where a client wants them, to outbound webhooks (existing). Which of them are worth a webhook is an open question; none is promised here.

### 4.4 How plant data arrives

| Connector option | Where it sits | Note |
|---|---|---|
| Manual forms (web, mobile) | In Letflow | Phase 1. Part 2 option A. |
| File import (CSV/XLSX) with an inbound mapping | In Letflow (`IntegrationMappings` plus an import route) | Phase 2. Part 2 option B. Duplicate-safe import is required. |
| Edge gateway pushes to a Letflow route | Gateway in the plant, a new **inbound route** with a machine token in Letflow | Phase 4. Needs the route, a credential type, buffering, rate limits. Letflow never connects into the plant (part 2 section 4 rule, an assumption). |

### 4.5 Real time, offline, tenant, security

| Topic | Option A |
|---|---|
| Performance and real time | One Postgres per platform, transactional writes, Elixir. Good for records (a batch has hundreds of lines, not millions). **Not** for raw sensor streams: no time series store. Keep raw tags in the client historian and bring in only aggregates or shift readings (part 2 option B). Capacity numbers were not measured; do not promise any. |
| Offline and edge | Phase 1: mobile offline queue for operator entry (the pattern exists for stock forms; extending it to MES forms is work, size unknown). Plant-side edge: a gateway is a separate small program anyway. |
| Multi-site | One tenant, many sites through the location tree and org units. One company with several plants = one tenant (assumption; a group view across tenants is not supported and not designed here). |
| Tenant isolation | Inherited: schema per tenant, INV-1; every new route needs the INV-10 cross-tenant negative test. Machine feed: one token per tenant and site. |
| Security and audit | Inherited audit chain, field authorisation, roles (operator, shift lead, QC analyst, QA releaser as module permissions). Signatures are GMP-like only (part 1 row 13). A new inbound route is the new attack surface. |
| Edition | MES modules can be closed (corporate edition) and depend on community modules: allowed direction. Whether MES is community or closed is the owner's decision (section 10). |

### 4.6 Effort (assumption, rough, not measured), one small team

| Phase | Content | Months |
|---|---|---|
| 0 | Prototype (section 8) | 1 |
| 1 | `mes_core` plus `mes_batch` (part 3 option B: 8 to 14 weeks) | 3 to 4 |
| 2 | `mes_stream` with manual entry and file import (part 2 option A and B) | 2 to 3 |
| 3 | `mes_discrete` (needs the electronics facts first) | 4 to 6 |
| 4 | Machine feed: inbound route, credential, gateway, runbook | 3 or more |
| 5 | Equipment states, downtime, OEE (part 3 option C parts) | 3 to 5 |

Risks: touching the shared ledger policy; third copy of the posting code; scope growth; no real plant data yet.

## 5. Option B: a separate MES service next to Letflow

### 5.1 Shape

A new service (own repository, own database, own release) holds recipes, batches, equipment, QC, pallets, genealogy. Letflow stays the platform for users, tenants, documents, process engine and stock. They talk through the Letflow API (service calls) and events (outbound webhooks one way; the MES calls the API the other way).

### 5.2 What changes in the core

| Change | Why |
|---|---|
| A **service credential** and a narrow permission set for the MES service | The MES must read items, lots, locations and post stock documents. Whether such a credential type exists is not verified (section 3). Probably a new core feature, with a security review. |
| A way for the MES to tell Letflow a tenant, a user and a role | Identity is per tenant realm (decision 0072 per `T-1521.md`). The MES would trust Letflow tokens or run its own sign-in: either is new work. |
| Ledger causes for consume and produce | **Still needed**: the booking into stock still happens in Letflow. Option B does not avoid row 4; it only moves the caller. |
| Hold rule | The MES knows the status; Letflow stock must refuse the shipment. A cross-service rule: either Letflow stores a lot status (same core change as A) or the MES must be in every shipping path. |
| Events | Letflow webhooks exist for outbound; the reverse (MES to Letflow) is plain API calls. Delivery guarantees across two systems (retry, ordering, duplicates) are new design. |

### 5.3 Data model sketch

The same entities as in section 4.3, in the MES database, with a `tenant` key on every table (or a schema per tenant, as Letflow does). Lots and items are **references** to Letflow ids, so two sources of truth for identity and quantities must be kept in step.

### 5.4 Data arrival, real time, offline

| Topic | Option B |
|---|---|
| Plant data | Easiest of the three for a machine feed: the service may have its own time-series store and connectors (OPC UA, MQTT; part 2 section 4) without touching the Letflow core. |
| Real time | Can be designed for it (its own stack and store). It is the only option where the real-time choice is free. |
| Offline and edge | The service may run **at the plant** (on-premise) and sync to Letflow later. This is the main reason to pick B. Sync conflict rules are new design. |
| Multi-site | Free to design; a service per site or one central. |

### 5.5 Tenant isolation, security, audit

| Topic | Option B |
|---|---|
| Tenant isolation | Must be rebuilt in the service (schema or row level), with its own cross-tenant negative tests. The platform invariants (INV-1, INV-6, INV-10) apply by the project rules to any tenant-data path; a second implementation doubles the review. |
| Security | A service-to-service credential held by reference only (INV-4); outbound calls validated (INV-9). Two attack surfaces and two deploy pipelines. |
| Audit | Two audit trails. Genealogy proof needs both. A batch record that must be tamper-evident needs the hash chain in the service too, or a copy of its digest into the Letflow audit (new design). |
| Edition | Fully independent licence and release. Easiest to keep closed. |

### 5.6 Effort (assumption, rough)

Same product scope as A **plus** platform plumbing: sign-in and tenants, service credential, deploy and monitoring, two-way sync, second audit. Assumption: 3 to 5 months more than A, before the first batch works.

| Phase | Content | Months |
|---|---|---|
| 0 | Prototype of the API and sync contract (section 8) | 1 to 2 |
| 1 | Service skeleton, tenants, sign-in, credential, `core` and `batch` parts | 6 to 9 |
| 2 | Stream | 2 to 3 |
| 3 | Discrete | 4 to 6 |
| 4 | Machine feed and edge | 2 to 4 (easier than in A) |

Risks: two sources of truth; double security work; the team is small; every Letflow API change now breaks a second consumer; the row 4 and hold changes in core are still needed.

## 6. Option C: integrate an existing MES or historian; Letflow adds documents only

### 6.1 Shape

The client (or we) installs an existing product (an open-source or commercial MES, a historian). Letflow carries only what it is good at: documents, forms, process steps, approvals, stock, assets, with links to the MES by reference.

Candidate products: **not researched in this task.** Part 6 lists commercial products from search snippets (SG Systems, Siemens Opcenter, BatchMaster, Parsec TrakSYS, SYSPRO, Proficy), all "Unverified". Open-source candidates (for example an open-source ERP with a manufacturing app, a time-series database with a dashboard tool, a Node-RED style gateway) exist from general knowledge: **assumption, not verified, no licence checked.** A licence check is a task before any choice (a strong copyleft licence changes what we may bundle).

### 6.2 What changes in the core

| Change | Note |
|---|---|
| Almost none | Letflow uses existing webhooks, `IntegrationMappings`, documents and the process engine. |
| Possible: inbound route for results | If the MES must write back (for example a release decision into a stock hold): the same new route and the same hold rule as in A and B. |

### 6.3 Data model sketch

Letflow holds only **references and documents**: `mes_link` (external batch id, Letflow lot, Letflow document), approval documents, and the stock documents Letflow already has. Recipes, batch records and genealogy stay in the other product. Events: outbound webhook "document approved" (existing producers: audit entries; whether a webhook kind exists for each was not checked) and inbound calls from the MES.

### 6.4 Data arrival, real time, offline, tenant, security

| Topic | Option C |
|---|---|
| Plant data | The other product brings its own connectors. Letflow sees only summaries. |
| Real time and offline | Whatever the product offers. Many MES products run on-premise (assumption, part 6 shows "not stated" for deployment). |
| Tenant isolation | Many products are single-customer installs: one install per client (assumption). Letflow tenant isolation does not cover them; each install is the client's or ours to secure. |
| Security and audit | Two systems, two audits; Letflow audit covers only what passes through it. A batch record is not in the Letflow chain. |
| Edition | Letflow stays free of MES code. The other product's licence and price apply (part 6 section 4: all prices unverified). |

### 6.5 Effort (assumption)

| Phase | Content | Months |
|---|---|---|
| 0 | Product shortlist and licence check; one test install | 1 |
| 1 | Links, forms, documents, process steps for one client | 1 to 2 per client |
| 2 | Inbound result route and hold rule, only if needed | 1 to 2 |

Risks: we sell a product we do not own; the client pays twice; weak genealogy in Letflow; dependence on a vendor; the fertilizer and electronics fit of each product is unknown (part 6: "not found in public sources").

## 7. Comparison

| Criterion | A in-platform modules | B separate service | C integrate |
|---|---|---|---|
| Change in the core | Ledger causes, lot status (hash change, upgrade run, review); posting-kernel decision | Same ledger and hold change **plus** service credential, identity link | Small; the same hold rule only if write-back is needed |
| Genealogy tied to stock | Yes, one database, one audit | Two sources of truth; sync | Only in the other product |
| Machine data and real time | Weak (no time series); needs inbound route; use aggregates | Strongest (own stack) | By the product |
| Offline / edge | Mobile queue; gateway separate | Service can run at the plant | By the product |
| Tenant isolation | Inherited | Rebuilt and re-tested | Per install |
| Security surface | One system, one new route | Two systems | Two systems, vendor code |
| Audit | One chain | Two trails | Two trails |
| Open/closed fit | Closed modules over community core (allowed) | Fully separate | Not our code |
| Effort to first batch (assumption) | 4 to 5 months incl. prototype | 7 to 11 months | 1 to 3 months per client |
| Main risk | Shared ledger policy; small team | Duplication of the platform | Fit, licence, selling a third-party product |
| Fit with the Letflow strategy (one platform, many modules) | Best | Weakest | Medium |

## 8. What to prototype first (A, 3 to 4 weeks, assumption)

1. **Hash and upgrade proof.** On a test tenant, add the two ledger causes and a lot status to a copy of the stock policy; run U1 and U2; record what U1 reports and what happens to other installed modules. This is the biggest unknown of A.
2. **One thin batch slice.** Recipe version, one batch, consume two raw lots, produce one finished lot, hold and release, trace both ways. Use the existing stock and lot code; no UI beyond what the proof needs.
3. **Reading with `source` field and a file import** (part 2 recommendation), to test that raw tag data stays outside.
4. **Paper check with the client** (when allowed): the questions of part 2 section 7 and part 3 section 7. No client was contacted.

What not to prototype first: a machine connector (A phase 4), discrete (facts missing), a second service (B) unless point 1 fails.

## 9. ISA-95 alignment (general knowledge, standard text not opened)

| ISA-95 idea | Where it lands in option A |
|---|---|
| Level 3 manufacturing operations: production, quality, inventory, maintenance | `mes_core` (production, quality, genealogy); stock (inventory); assets and equipment states (maintenance, light) |
| Level 2 control (PLC/SCADA) | Outside; edge gateway in phase 4 |
| Level 4 business (ERP) | Outside; import and webhooks (row 18) |
| Equipment hierarchy (site, area, unit) | Location tree plus equipment record |
| Information objects (material, equipment, personnel, process segment, work request/response) | Item and lot, equipment, org and roles, recipe/routing step, work order and batch |

The mapping is a **fit by name**; no claim of ISA-95 conformance. B and C could align the same way; A has the least translation.

## 10. Recommendation and open questions

**Proposal (not an owner decision):** choose **A**, in phases: prototype (section 8) then `mes_core` plus `mes_batch`, then `mes_stream`. Keep machine data outside the core: aggregates in, raw tags in the client historian; build the inbound route only in phase 4. Hold **B** for a client that needs an on-premise plant system that works offline for long periods, and **C** as the fallback for a client that already runs a MES. Reason: A reuses lots, ledger, audit, tenants and modules; B and C do not remove the ledger change that A needs.

Open questions for the owner (not decided here):

1. Is MES community (MIT) or corporate (closed)? It decides where the code and the ledger change live.
2. May the stock ledger's closed cause list grow, and may a lot get a quality status (part 1 row 4, part 3)?
3. Is the posting-kernel decision record (`core-extraction-design.md` section 7) taken before `mes_core` posts to the ledger?
4. Does a service or machine credential type exist, and what is the plan for an inbound device route (not verified in section 3)?
5. Does any client need long offline work on site (decides B)?
6. Electronics prospect facts (part 1 question 3) before `mes_discrete` is sized.

## 11. Sources and what was not verified

* **Letflow facts:** the files named in section 3, opened on this branch on 2026-11-12: `module.ex`, `integration_mappings.ex`, `webhooks.ex`, `event_store/partition_maintenance.ex`, `security-invariants.md`, `core-extraction-design.md`, `T-1521.md`, parts 1, 2, 3, 6 of this design. `depends_on` lines read by grep in `stock.ex` and `assets.ex`. `manifest_hash.ex` was **not** opened; the hash coverage is quoted from `core-extraction-design.md` section 3.
* **Not verified:** mobile offline queue scope (matched by grep only); a machine credential type; platform throughput; whether web has any offline mode.
* **ISA-95** and **ISA-88**: general knowledge and the secondary pages named in part 6; standard texts not opened. **Market products:** part 6 snippets, unverified. **Open-source MES candidates:** none researched.
* **All effort figures, months and sizes** are assumptions from comparison with part 1 to 3, not measured.
* Nothing here was discussed with a client.
