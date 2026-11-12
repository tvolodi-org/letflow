# MES on Letflow, part 2: liquid fertilizers as streams, 3 design options

Status: **DRAFT** (owner request 2026-11-12, task T-1819). Design options only. No code, no client contact, nothing on production, money, DNS, secrets, demo or a public repository.

Written for a reader whose English is a second language: short sentences, tables, a glossary. Part 1 is `docs/design/mes/01-domain-and-fit-gap.md` (glossary and fit/gap; read it first).

## 1. The question

How can a plant that makes liquid fertilizer in a **stream** (no natural batch) be recorded on Letflow? Three options are compared: **A** manual entry and file imports, **B** periodic import from the plant historian, **C** a live connector to PLC / SCADA.

## 2. Extra words used here

| Term | One-line meaning |
|---|---|
| Stream | Material that flows all the time through pipes, tanks and mixers. |
| Tank / vessel | A container with a level, a content (which product) and a state. |
| Transfer | Moving liquid from tank X to tank Y (or from a line into a tank). Has start, end, amount. |
| Formulation | The target composition of a product grade (for example N-P-K percent, density). |
| Blend step | Mixing several inputs (for example ammonium nitrate solution, urea solution, water, additives) into a tank to hit the formulation. |
| Specification (spec) | Limits a product must meet (min/max of nutrient, density, pH...). |
| Mass balance | Mass in - mass out - change of stock = loss or error. Should be near zero. |
| Historian | A database that stores time series of machine signals ("tags"). |
| Tag | One named signal (for example "tank 3 level"). |
| OPC UA | Open industrial protocol: a client reads tags from a server, and can subscribe to changes. |
| MQTT / Sparkplug | MQTT: light publish/subscribe messaging. Sparkplug: a rule set on top of MQTT for industrial data. |
| Edge gateway | A small computer on the plant network that reads machines and sends data out. |

## 3. Model objects

How each object would be modelled. "Reuse" means a thing that exists on Letflow today (checked in part 1, section 4); "New" means it does not exist.

| Object | Meaning in this plant | Model on Letflow | Status |
|---|---|---|---|
| Tank / vessel | Raw, intermediate, product tanks | A **location** (tree: site, area, tank) plus an **equipment** card (type, capacity, unit). Level and content are readings on it | Location: reuse. Equipment with state: New (fit/gap row 6) |
| Tank content | Which product grade, how much (kg or L) | Stock ledger balance at the tank location, item = product grade, lot = fill or window | Reuse ledger. Unit and density rule: open question |
| Stream / transfer | Liquid moved between tanks | A **transfer document** with from, to, amount, start, end. Today's stock transfer is close; it needs time span and a source of the amount (manual, meter, computed from level) | Reuse + small change |
| Formulation | Target composition of a grade | A versioned recipe with ingredient lines (amount, tolerance) and target analysis limits | New (row 2) |
| Blend step | Adding inputs to a tank | A production run (row 3) that consumes raw lots and produces an output lot; booking uses new consume and produce causes in the ledger (row 4) | New |
| Lab sample and result | Sample from a tank at a time; analysis | Sample record (tank, time, who) and result lines (parameter, value, limit, pass/fail). Task form for the analyst | New (row 8) |
| Specification and release | A tank fill may be sold only if samples are inside spec | Release decision (release, hold, reject) by a second person; a held lot blocks issue | New (row 8); four-eyes rule exists |
| Mass balance | Per tank, per shift, per day | A computed report: opening stock + in - out - closing stock. Closing stock comes from level x density or from a count | New report on reused data |
| Shift log | Handover, events, readings | Shift record with entries and handover note; signed by shift lead | New (row 7) |
| Alarms and downtime | Stops, trips, causes | Downtime record with reason code; alarm list as read-only imported events (options B, C) | New (row 11) |

### Lot for a stream (the key design choice)

The stream has no natural batch. Three ways to cut it into lots (the client chooses; not decided here):

| Cut | Meaning | Good | Bad |
|---|---|---|---|
| Tank fill | One lot = one filling of a product tank until it is closed for sampling | Matches how the plant sells and samples ("tank 5, grade X") | A tank filled while being emptied (no clean cut) mixes lots |
| Shift or day | One lot = production of one shift or day per grade | Simple; matches the shift log | Does not match what is in the tank |
| Time window | One lot = fixed window (for example 8 hours) | Easy to compute from imported data | Arbitrary cut; harder to explain to a customer |

Assumption (UAT assumption, to be confirmed by the process owner): the first draft uses **tank fill** as the lot, with a "mixed" flag when a tank is topped up before release.

## 4. Data in: what is realistic for a first pilot

| Source | What it is | Facts and sources | Realism for a pilot |
|---|---|---|---|
| Manual entry | Operator types level, totaliser, sample result on a phone or PC at set times | Letflow already has forms, tasks and a mobile tier with offline queue (part 1, section 4) | **Yes.** Needs no plant IT |
| Import file (CSV / XLSX) | Export from SCADA screen, lab system or meter log, uploaded by a person | Letflow modules already import by file (catalog items, lots; part 1) | **Yes.** Low effort, mapping per file |
| Historian export | Scheduled export of tag values (CSV, or a database/REST query) | Historian = time-series store (vendor products differ; assumption: most can export CSV on a schedule) | **Likely yes**, if the client has a historian and allows an export folder or read-only query |
| OPC UA | Client reads tags from a server; client can subscribe to changes | OPC Foundation, Part 1 "Overview and Concepts" describes client/server, address space, subscriptions and monitored items: https://reference.opcfoundation.org/specs/OPC-10000-1/2.1.5 (search result page; body text not read in full). IEC edition: IEC 62541-1 | **Not for a first pilot.** Needs a connector (new dependency), network path into the plant, security setup |
| MQTT / Sparkplug | Devices or gateways publish values to a broker | Sparkplug is an open spec at the Eclipse Foundation (topic namespace, payload, session state) and is also ISO/IEC 20237: https://sparkplug.eclipse.org/specification/ and https://newsroom.eclipse.org/node/39754 (search summaries; spec text not read) | **Only if the plant already runs a broker.** Otherwise as C |

Security rule for any machine feed (assumption, from the platform invariants in the project docs, not re-checked here): Letflow never opens a connection into the plant network. Data goes **out** from the plant side (edge gateway or export job) to Letflow with a token. Secrets live by reference only.

## 5. The three options

### Option A: manual entry and file imports only

* **How:** Operators enter tank readings, transfers, samples and shift log by form (web or mobile). Totaliser and lab files can be uploaded.
* **Letflow work:** equipment and tank card, readings, transfer with time span, recipe, production run, sample and release, shift log, mass-balance report (fit/gap rows 2, 3, 4, 6, 7, 8, 15). No inbound device feed.
* **Effort (assumption, rough, not measured):** M to L in total, because the production layer does not exist yet. The data-in part is S.
* **Risks:** typing errors; late entries; operators skip readings; mass balance only as good as the readings.
* **Client provides:** product grades and specs, tank list, sample plan, shift pattern, sample files, a pilot team that enters data.
* **Pros:** fastest start; no plant IT or security work; proves the model and the screens.
* **Cons:** labour; low time resolution; no alarms; mass balance weak.

### Option B: periodic import from the historian

* **How:** Option A plus a scheduled job: the plant exports tag values (levels, flow totals) to a file or read-only endpoint every N minutes or per shift; Letflow imports them as **readings** (not as the book of record for stock) and fills mass balance, alarm list and downtime hints.
* **Letflow work:** A plus an import mapping (tag name to tank/meter), a scheduled import using existing scheduled jobs, a reading store with a source and quality flag, duplicate-safe import (same file twice must not double-count).
* **Effort (assumption):** A plus M. The mapping and its tests need real sample files.
* **Risks:** clock and time-zone mismatch; tag renames; gaps and spikes in data; export format changes; who owns the export job.
* **Client provides:** a tag list with units, sample export, export schedule and the person who maintains it, time zone, rule for bad values.
* **Pros:** more data, no manual typing of levels; no live link into the plant; reuses the file import style.
* **Cons:** delay (minutes to hours); needs a historian and an IT person; mapping upkeep.

### Option C: live connector (OPC UA or MQTT)

* **How:** An edge gateway on the plant side reads tags (OPC UA subscription or MQTT / Sparkplug) and pushes events to Letflow, near real time. Letflow shows live tank levels, raises alarms, builds downtime from machine state.
* **Letflow work:** B plus an inbound event API with token auth, buffering and replay after a break, a time-series store (the platform has none today: needs a design), alarm rules, and a gateway product or service (build or buy).
* **Effort (assumption):** L to very large; plus security review, tenant isolation of the feed and a runbook for the gateway.
* **Risks:** plant network policy; safety rules (read-only only, never write to PLC); data volume; support burden at the plant; a new component to run and monitor.
* **Client provides:** OPC UA server address and certificate policy or broker details, tag list, network and firewall approval, a named OT contact, test window.
* **Pros:** live view; best mass balance and downtime; strongest sales demo.
* **Cons:** longest and riskiest; needs OT engineers on both sides; infrastructure outside the platform.

### Comparison

| | A manual + files | B historian import | C live connector |
|---|---|---|---|
| Data delay | As typed | Minutes to hours | Seconds |
| Plant IT needed | None | Export job | Gateway, firewall, certificates |
| Letflow new parts | Production layer | + import mapping, readings | + event API, time series, alarms |
| Effort (rough) | M to L | A + M | L+ |
| Main risk | Human errors | Data quality, mapping | Network, security, support |
| Mass balance quality | Low to medium | Medium to high | High |
| First pilot? | **Yes** | **Second step** | **Later, only if the client pays for it** |

**Recommendation (a proposal for the owner, UAT only):** start with **A**, designed so that a reading has a `source` field (manual, file, import, live) from day one. Then **B** when the client shows a real export file. **C** only after B has run and the client confirms network access. Reason: the production layer (recipes, runs, samples, release) is the same in all three and is the bigger gap; machine data only improves it.

## 6. Open points of the design (not decided here)

1. Lot cut for a stream (section 3).
2. Stock unit: mass (kg), volume (L) or both with a density per grade and temperature rule.
3. Is the stock ledger or the reading the book of record for tank content? Draft: ledger is the record; readings are checked against it and differences are shown.
4. Whether samples need a second-person release (draft: yes, using the four-eyes rule).
5. Time-series storage for option C: not designed.

## 7. Questions to ask the client (list for the owner; no client was contacted)

**Product and process**

1. Which liquid products do you make (grades, N-P-K or other analysis)? How many?
2. How many raw material, intermediate and product tanks? Are product tanks filled and emptied at the same time?
3. How do you today cut the stream into something you sell and trace: by tank fill, shift, day?
4. Is the product sold by mass or by volume? Do you use a density table?
5. What inputs go into a blend and how is the dosing done (meters, weigh cells, level change)?

**Quality**

6. Which parameters do you test and where (own lab, external)? How often per tank or per shift?
7. Who decides release? What happens to off-spec product (rework, blend back, reject)?
8. Do customers or authorities ask for a certificate of quality or traceability to raw lots?

**Mass balance and shifts**

9. How do you do the mass balance today (paper, Excel, ERP)? Per tank, per shift, per day? What loss is acceptable?
10. How many shifts, how do you do handover, who signs?
11. Which stops and alarms do you want to see, and with which reasons?

**Machine data**

12. What control system do you have (brand, PLC, SCADA)? Is there a historian? Which one?
13. Can it export files on a schedule? In which format, to where?
14. Does it have an OPC UA server or an MQTT broker? Who is allowed to open a connection from the plant network, and who is your OT contact?
15. How many tags would we need, and how often do they change?
16. Is the plant network allowed to send data out to a cloud service? Any rule against it?

**People and systems**

17. Who would enter data in a pilot (how many people, on phone or PC, language ru/kk/en)?
18. Which ERP, if any, holds orders and stock? What must go in and out?
19. Any legal requirement for signatures or records (audits, certification such as ISO 9001, export rules)?
20. What is the goal and the budget range of the pilot, and what would make it a success?

## 8. Sources and what was not verified

* Letflow facts: from part 1 (`docs/design/mes/01-domain-and-fit-gap.md`, section 4); no new code reading was done for this part, except to check that the file exists.
* OPC UA: OPC Foundation reference site, Part 1 "Overview and Concepts" (https://reference.opcfoundation.org/specs/OPC-10000-1/2.1.5; scope page https://opcfoundation.org/developer-tools/documents/view/158). Only the search results (table of contents and scope text) were seen; the full text was not read.
* MQTT Sparkplug: https://sparkplug.eclipse.org/specification/ and https://newsroom.eclipse.org/node/39754 (ISO/IEC 20237). Search summaries only.
* ISA-88 and ISA-95: https://www.isa.org/standards-and-publications/isa-standards/isa-88-standards and the ISA technical report TR88.95.01 preview https://www.isa.org/getmedia/83cb8a4e-273c-4ce3-bfb4-68d81e8b681c/tr_889501_preview.pdf. Overviews only; the standards texts were not opened. This closes only partly the open point of part 1, section 8.
* **Assumptions (not verified):** that most historians export CSV on a schedule; all effort sizes (S/M/L); the "tank fill" lot cut; the ledger as book of record; the outbound-only data rule.
* Nothing here was discussed with a client.
