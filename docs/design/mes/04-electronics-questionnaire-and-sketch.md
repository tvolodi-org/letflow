# MES on Letflow, part 4: electronics producer: questionnaire and first sketch

Status: **DRAFT** (owner request 2026-11-12, task T-1821, MES-4). Design options only. No code, no client contact, nothing on production, money, DNS, secrets, demo or a public repository.

Written for a reader whose English is a second language: short sentences, tables, a glossary. Part 1 (`docs/design/mes/01-domain-and-fit-gap.md`) has the general glossary and the fit/gap table; terms here that are new are explained in section 4.

## 0. Read this first: what is known and what is a guess

We know almost nothing about this prospect. The owner only said: "an electronic device producer, needs clarification". There was no client contact.

* Part A (questionnaire) asks questions. It states no fact about the client.
* Part B (sketch) is built on **guesses**. Every guess is labelled `GUESS` and has a line "answer that would change it" (the question number from Part A). When an answer comes, the guess is either confirmed or replaced. Until then, nothing in Part B may be used to promise anything.

## Part A. Questionnaire for a first call (one page)

Time: about 45 minutes. Ask in this order. Write the answer in the right column. "Why we ask" is for our team, not to be read aloud.

| # | Topic | Question | Why we ask | Answer |
|---|---|---|---|---|
| 1 | Products | What do you make? Boards only, or finished devices in a case? How many different products and variants? | Decides if we trace boards, devices, or both. | |
| 2 | Volumes | How many units per day, per product? Smallest and largest order size? | A few hundred serials a day and a hundred thousand a day need different designs. | |
| 3 | Lines and sites | How many lines? How many sites or buildings? Is any step done by a subcontractor? | Number of stations to model; outsourced steps break our trace. | |
| 4 | Process steps | List the steps in order: SMT (surface-mount: parts placed on a board), reflow (oven), inspection (AOI/X-ray), through-hole, assembly, flashing (loading software into the device), test, packing. Which do you have? | This is the routing. | |
| 5 | Work orders and routing | Who creates a work order (ERP or planner)? Is the route the same for every unit of a product, or does it change by variant? Can a work order be split or merged? | Work order and routing model. | |
| 6 | BOM and revisions | How is the BOM kept (ERP, PLM, Excel)? How often does it change? Do products have revisions that must be tracked per unit? Are substitute parts allowed? | BOM revision per work order; substitutes need a rule. | |
| 7 | Serial numbers | Does each unit get a serial number? Who assigns it, and when (label printed at start, or burned in at flashing)? Are there serials on boards and on the final device? Is there a panel (several boards in one sheet)? | Serial genealogy; panel to board split. | |
| 8 | Traceability to component lots | Must you know which component lot went into which unit? For all parts or only some (chips, batteries)? How are reels/trays identified today (barcode, 2D code)? Which customers ask for it? | Biggest design driver: consume-by-scan or consume-by-batch. | |
| 9 | Test stations and data | Which tests (in-circuit, functional, burn-in)? What does a station produce (a pass/fail, a file, a database row)? Is the data kept somewhere now? How big is one result? | Test results as records vs. attached files; need for a station interface. | |
| 10 | Machine connection | Which machines (pick-and-place, AOI, testers)? Which brand and interface? Do any speak IPC-CFX or SECS/GEM (machine communication standards)? Who may touch the machine network? | Manual entry first, or a feed. Security and infrastructure decision. | |
| 11 | Rework and scrap | What happens to a failed unit: repair, retest, scrap? How many repair loops are allowed? Who decides? Is a reason code needed? | Rework loop and scrap booking. | |
| 12 | ERP and other systems | Which ERP? Which other systems (PLM, warehouse, quality system, test database)? What should flow in and out? | Interface scope; avoid building what already exists. | |
| 13 | Compliance and customers | Do you serve medical, automotive, aerospace or defence? Which certificates (ISO 9001, ISO 13485, IATF 16949)? Does any customer need an audit trail, an electronic signature, or a retention period (how many years)? | Decides "GMP-like" records vs. legal validation. | |
| 14 | Shifts and people | How many shifts? How many operators per line? Who may release a lot or a work order? Are tablets or scanners on the floor? Is there a network on the floor? Which languages? | Roles, mobile or kiosk use, offline need. | |
| 15 | Today and pain | How is production recorded today (paper, Excel, a system)? What is the main pain: a recall, a customer audit, lost time, scrap? What would "success after 6 months" look like? | The reason to buy; sets the first slice. | |
| 16 | Decision | Who decides? Is there budget and a date? Any other vendor being compared? | Qualifies the prospect. (Ask only the owner's contact; no price is quoted.) | |

Rules for the call: do not promise a date or a price; do not show a demo; write down the client's own words.

## Part B. Sketch of the options (all GUESSES until Part A is answered)

### B1. What a discrete MES needs, as a first guess

| Need | Source | Label |
|---|---|---|
| Work order with a quantity of one product, linked to a BOM revision | Part 1, fit/gap rows 2 and 3 | GUESS: that this client has work orders at all. Answer that would change it: Q5. |
| Routing: the ordered stations a unit passes | Part 1, glossary | GUESS: one fixed route per product. Changes with Q4, Q5. |
| Serial number per unit and genealogy (unit to component lots) | Part 1, fit/gap row 14 (size L) | GUESS: needed. If Q7 and Q8 are "no", the whole design shrinks to lot level, like the batch style. |
| Test results kept per unit | Part 1, fit/gap row 14 | GUESS: pass/fail plus a few measured values. Changes with Q9. |
| Rework loop and scrap | Part 1, fit/gap row 14 | GUESS: a failed unit goes back to a repair step and is retested. Changes with Q11. |
| Device history record (the full record of one unit; the discrete form of the electronic batch record, row 12) | Part 1, fit/gap row 12 | GUESS: wanted only if Q13 names a regulated customer. |

What Letflow already has for this (from Part 1, section 4, read in code on 2026-11-12): item `tracking_policy` including `serial`; lot master; a stock ledger with the lot in its key; codes and labels (scan); locations (can model lines and stations); the process engine with human tasks and a four-eyes rule; audit chain; modules. What it does **not** have: BOM, work order, routing, serial unit record, station result record, consume/produce booking. Those are the gaps; nothing here is built.

### B2. Three design options

All three use the platform's own pieces: a module with record types, the process engine for steps, the ledger for material. Names of record types below are placeholders, not decisions.

**Option 1. Lot-level light (smallest).**

* Idea: track by work order and component lot only. No serial per unit. One work order = one lot of finished product. Material is consumed per work order from component lots (scan the reel once per work order). Test result is a summary per lot (counts of pass, fail, scrap).
* Letflow pieces: item and lot masters, ledger (consume and produce, new causes, see Part 1 row 4), work order record, quality release of the lot.
* Good if: low volume, no serial requirement, no regulated customer.
* Not enough if: a customer asks "which board had this chip?".
* Size (GUESS, by comparison with Part 1 rows 2, 3, 4, 8): M.
* Becomes the right choice if: Q7 = no serials, Q8 = lot level, Q13 = no regulated customer.

**Option 2. Serial genealogy with test records (middle, the most likely).**

* Idea: each unit has a serial. A work order creates serial records. A unit moves along the routing; at each station a human task or a scan records the step. Component lots are linked to a serial at the station where the part is fitted (scan of reel code plus unit serial). A test result is a record per unit per test: pass/fail, a few values, station, time, operator. A failed unit goes to a rework loop: repair step, then back to the test step, with a counter and a limit.
* Letflow pieces: serial unit record (new), routing (a process definition per product, reusing the engine), test result record type (reuses entity records with history), codes module for scan, ledger for component stock, audit chain for tamper evidence. Trace backward: serial to component lots. Trace forward: component lot to serials.
* Good if: serials exist, customers ask for traceability, volume is moderate.
* Open design points: one row per unit per step may be a lot of rows at high volume (needs Q2); raw test files (waveforms, logs) should be stored as attached documents, not in records (needs Q9).
* Size (GUESS): L, the largest single gap in Part 1 (row 14), plus M for work order and BOM.
* Becomes the right choice if: Q7 = yes, Q8 = by component lot, Q9 = pass/fail plus values.

**Option 3. Station feed on top of option 2 (largest).**

* Idea: as option 2, but machines and testers send their results by themselves through an inbound interface (a gateway), not by hand. Public electronics standards exist for this: IPC-CFX (IPC-2591) for machine messages and IPC-1782 for traceability levels (see section 5). A gateway would translate messages into Letflow records.
* Letflow pieces: same as option 2, plus a new inbound device interface. Today Letflow has outbound webhooks and scripts only (Part 1 row 10); no inbound device feed exists.
* Good if: high volume, machines already speak a standard, manual entry is too slow.
* Open design points: network access to the factory floor, security of an inbound credential (a new design with security review), what happens when the link is down (buffer and replay).
* Size (GUESS): L to XL, and infrastructure work, not only software.
* Becomes the right choice if: Q10 = machines with CFX or a station database, Q2 = high volume, and the client accepts the infrastructure work.

### B3. Comparison

| | Option 1 | Option 2 | Option 3 |
|---|---|---|---|
| Trace unit to component lot | No | Yes | Yes |
| Test result per unit | Summary only | Yes, entered or scanned | Yes, automatic |
| Rework loop | Count only | Yes, with limit | Yes |
| Machine feed | No | No (manual or scan) | Yes |
| Size (GUESS) | M | L | L to XL |
| Needs a new security design | No | No | Yes (inbound credential) |

Suggested path (a proposal, GUESS-based): start with option 2 only after Q7, Q8 and Q9 are answered; keep option 3 as a later step; use option 1 as a fallback if the client has no serials. Do not build anything before the call.

### B4. Letflow rules that apply to every option

Tenant isolation (each client's data is separate), a role per person (operator, shift lead, quality releaser: new module roles, Part 1 row 16), audit of every write, no secrets in records. These are platform rules (`docs/migration/decisions/`, `docs/roles.md`), not guesses.

## 4. Extra glossary (new terms only)

| Term | One-line meaning |
|---|---|
| SMT | Surface-mount technology: small parts are placed on the surface of a circuit board by machine. |
| Reflow | An oven that melts solder paste to fix the parts. |
| AOI | Automated optical inspection: a camera checks the board. |
| ICT / functional test | In-circuit test: checks parts and connections. Functional test: checks the device does its job. |
| Panel | A sheet that holds several boards, cut apart later. |
| Reel | A roll or tray of one component type with one lot code. |
| Flashing | Loading software into the device. |
| Device history record | The full record of how one unit was made and tested. |
| IPC-CFX | An electronics standard for machine messages on the shop floor. |
| SECS/GEM | An older standard for equipment communication, common in semiconductor plants. |

## 5. Sources and what was not verified

* Letflow facts: Part 1 (`docs/design/mes/01-domain-and-fit-gap.md`, section 4), which lists the files opened on 2026-11-12. Not re-opened here beyond that file.
* Public sources: a web search on 2026-11-12 returned IPC pages that describe IPC-2591 (CFX) as a standard for machine-to-machine communication in electronics manufacturing, and IPC-1782 as a standard for manufacturing and supply-chain traceability with four traceability levels. Pages: <https://www.electronics.org/solutions/ipc-factory-future>, <https://www.electronics.org/digital-manufacturing>, <https://www.ipc.org/TOC/IPC-2591-Version1-2-toc.pdf>. These are overview and table-of-contents pages: **the standards texts were not opened**, and the current version number of each was not confirmed. Treat the one-line descriptions as assumptions.
* SECS/GEM, ICT, AOI, SMT descriptions: general knowledge, not looked up. ISO 13485 and IATF 16949 are named only.
* All sizes (S/M/L/XL): assumption, rough comparison with Part 1, not measured.
* Everything about the client in Part B is a GUESS; nothing was discussed with the client.
