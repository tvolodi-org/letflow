# MES-6: Market and standards scan (public sources)

Status: DRAFT. Options only. No code, no client contact, nothing on production.
Date of research: 2026-11-12 (all web facts are "seen on this date").
Reader: plain English, short sentences, tables.

## 0. How to read this

- Every fact has a source link in section 8. Source numbers look like [S1].
- "Verified" = stated by the vendor or the standards body itself, or by two sources.
- "Unverified" = one marketing page, one review site, or a search snippet only. Treat it as an assumption.
- No client names. No confidential data. No price is a quote.
- Most sources are vendor marketing or review sites. None is an independent benchmark.

## 1. Short answer

1. For **fertilizer / agro-chemical batch plants** the public offer is thin. Vendors sell a general process MES (recipes, batch records, lot genealogy, weighing, labels). We found no public page with granulator or bagging-line details (unverified gap).
2. For **electronics** the offer is deep and mature: SMT line integration, component and serial traceability, route enforcement, paperless work instructions.
3. **Price** is rarely public. Public estimates run from about USD 50 per user per month (small SaaS) to USD 0.4 to 1.2 million for a full project. The sources disagree. All are unverified.
4. **ISA-95** tells us where a MES sits and which objects it exchanges with the ERP. **ISA-88** tells us how to model batch recipes and equipment. Both are modelling guides, not a certification.
5. Buyers first ask: scope of one pilot line, ERP link, traceability proof, who owns the data, price basis.

## 2. Competing products: chemical, fertilizer, process batch

| Product | What public sources say | Deployment | Price signal | Confidence |
|---|---|---|---|---|
| SG Systems (V5) | MES + QMS + WMS pitched at agro-chemical makers. Lot traceability, weigh targets and tolerances, barcode checks, forced step order, electronic batch history, label printing at fill point, pallet traceability to shipment [S1][S2] | Not stated in the snippets | Not public | Unverified (vendor page) |
| Siemens Opcenter Execution Process | Process-industry MES. A crop-protection plant case links batch system, LIMS and ERP [S3][S4] | Not stated | Not public | Unverified |
| BatchMaster | Chemical ERP with formulation, QC, traceability, a WMS and MES module, electronic batch records [S5] | Not stated | Not public | Unverified |
| Parsec TrakSYS | General MES. Recipe management, batch execution, sign-offs, lot and quality tracking; has a chemicals page [S6][S7] | Not stated | Not public | Unverified |
| SYSPRO | ERP with a chemicals and fertilizers brochure. Lot traceability across WIP, warehouse, dispatch and recall [S8] | Not stated | Not public | Unverified |
| GE Vernova Proficy MES (via a reseller page) | Lot genealogy: consumption, blending, split and merge, rework, finished-goods genealogy [S9] | Not stated | Not public | Unverified |
| Vicinity, Mar-Kov, InstantGMP, MasterControl, Aptean | Listed on directories as batch / chemical or regulated-batch software [S10] | Some cloud | One directory lists Vicinity at USD 250 per user per month | Unverified |

Typical modules in this group (seen in two or more sources): recipe / formula management, batch execution with step order, weighing and dosing check, lot genealogy (forward and backward), labels, electronic batch record, quality / lab link, ERP link.

Not found in public sources (gap, do not assume): tank-farm and liquid blending detail beyond SG Systems' title, granulation control, bagging and palletizer integration, fertilizer-specific compliance. Ask vendors directly in a later step.

## 3. Competing products: electronics devices

| Product | What public sources say | Price signal | Confidence |
|---|---|---|---|
| Aegis FactoryLogix | Electronics specialist. PCB assembly, component traceability, links to pick-and-place, AOI and reflow machines, paperless work instructions. Used by SMT houses and avionics / medical contract makers [S11][S12][S13] | Not public | Unverified (review site + vendor news) |
| Siemens Opcenter Execution Electronics | Dedicated edition: traceability, quality, material and change management; PCB and box-build as-built data [S14] | Not public | Verified as vendor claim |
| Critical Manufacturing | Positioned for high-mix and semiconductor. Publishes guidance on SMT line monitoring [S15][S11] | Not public | Unverified |
| Others (Plex, AVEVA) | Named as broad MES; Plex strong in discrete sectors [S16] | Plex listed USD 500 per user per month on one directory [S17] | Unverified |

Typical modules: material and component tracking (reel, lot), serial-level genealogy, route enforcement (a unit cannot skip a step), machine integration (SMT, AOI, test), work instructions, quality / defect, rework, engineering change control, ERP link.

A Gartner note, quoted by trade press, says most MES vendors serve discrete industry [S18] (second-hand, unverified).

## 4. Rough price level (all unverified)

| Item | Public figure | Source |
|---|---|---|
| Small SaaS MES per user | USD 50 to 300 per user per month (quoted as LNS Research data, second-hand) | [S17] |
| Small vendor list prices | WIPtrac USD 45 to 50 per user; Tulip USD 100 to 250 per interface per month | [S17] |
| Mid-range per year | USD 12,000 to 75,000 per year (one guide); USD 20,000 to 100,000+ per year per site (ITQlick) | [S17] |
| Enterprise | USD 600,000+ per year before implementation (one guide) | [S17] |
| Implementation | 1 to 2 times the software cost, or 50 to 150% of first-year license | [S17] |
| Whole project | USD 375,000 to 1.2 million; total cost over 5 years 200 to 300% of software cost (a vendor, Shoplogix) | [S17] |
| 10 production lines | USD 0.6 to 1.25 million including implementation and training (one source) | [S17] |

How to read it: the sources are vendor-linked and conflict. Price depends on users, lines, sites, integration work. Pricing basis differs (per user, line, machine, site). Use only as an order of magnitude: a small pilot is tens of thousands of USD per year; a full multi-line project is hundreds of thousands. Not for any budget decision.

Deployment: public sources mention both cloud (SaaS) and on-premise. Plants with old machines need add-on sensors or operator entry [S19]. We did not find a source for the share of each.

## 5. ISA-95 in one page

What it is: a standard (also IEC 62264) that says what a manufacturing operations system does and how it exchanges data with business systems [S20][S21].

Levels (0 to 4 only; a source that shows "0 to 5" does not match the standard [S22]):

| Level | Meaning | Example |
|---|---|---|
| 0 | Physical process | Reactor, granulator, SMT line |
| 1 | Sensors and actuators | Scale, valve, flow meter |
| 2 | Control | PLC, SCADA |
| 3 | Manufacturing operations (MES) | Orders, batches, quality, traceability |
| 4 | Business planning | ERP: plans, stock value, sales orders |

Parts (editions differ by source; check the ISA / IEC catalogue before citing an edition) [S20][S21]:

| Part | Subject |
|---|---|
| 1 | Models and terminology |
| 2 | Object models and attributes (personnel, equipment, material, process segment) |
| 3 | Activity models of level 3 (production, quality, inventory, maintenance operations) |
| 4 | Object models for operations management |
| 5 | Business-to-manufacturing transactions |
| 6 | Messaging service model |
| 7, 8 | Alias service model; information exchange profiles (one source) |

B2MML is an XML form of the Part 1 and 2 objects [S20][S23].

What we must keep in mind:
1. Keep the line clear. Letflow is level 3 and a thin level 4 link. It does not replace PLC control (level 2) or the ERP accounting.
2. Use the same four resource names for our data: personnel, equipment, material, process segment. Do not invent others.
3. Keep "order from ERP" separate from "work done in the plant". Send back actual consumption and output.
4. Design the ERP exchange as messages (Part 5 idea), not shared tables.
5. Level 3 has four activity families: production, quality, inventory, maintenance. Our first release covers only what a pilot needs (see MES-3 and MES-4 of this series when written).

## 6. ISA-88 in one page

What it is: the batch control standard (also IEC 61512). It gives one model for recipes, equipment and procedure [S24][S25].

Three models:

| Model | Levels |
|---|---|
| Physical | Enterprise, site, area, process cell, unit, equipment module, control module. A unit is the level you cannot drop. |
| Procedural | Procedure, unit procedure, operation, phase. A phase is the reusable block. Some levels may be left out. |
| Recipe | General, site, master, control. General and site are business level; master and control are used in execution. The control recipe is one batch, and the batch record comes from it. |

What we must keep in mind:
1. Separate the recipe (what to make) from the equipment (what can do it). The same recipe should run on another unit that has the needed capability.
2. A batch has its own copy of the master recipe (the control recipe). Later changes to the master do not change a batch that already started.
3. Keep a full batch record: which equipment, which material lots, which values, who signed.
4. Fit to our plants: a liquid fertilizer stream maps well (tanks, dosing, mixing = units and phases). A granular line with bagging is partly continuous. ISA-88 batch fits the batch steps (formulation, granulation run, a bagging lot); continuous parts need a different treatment. This is our own reading, not a source claim (assumption).
5. Electronics are discrete. ISA-88 helps little there; ISA-95 route and serial models matter more (assumption).
6. ISA-88 describes models. Real batch control stays in the PLC or batch system at level 2. Letflow keeps the recipe, order, record and sign-off.

## 7. What clients usually ask first

Taken from public MES selection guides (vendor-written, so each stresses its own strength) [S19][S26][S27]:

| Question | Short note |
|---|---|
| Which one line or product do we start with? | Pilot on one line with visible losses; roll out line by line. A big-bang scope can use the budget before a useful report. |
| When will live data show on the pilot line, and what must we bring? | Network and PLC access, stop-reason list, a named owner. |
| How does it link to the ERP? | Which connectors; the full flow order → MES → machine → feedback → ERP; who maintains it after updates. |
| Can you show forward and backward lot or serial tracing? | Demo a recall case. |
| Is the price per site, line, machine or user? What is included? | Hardware, sensors, implementation, training, support. |
| Audit trail, electronic signatures, role-based access? | Often named with 21 CFR Part 11 (a pharma rule; not assumed to apply to us). |
| How do old machines connect? | PLC if new; add-on sensor or manual entry if old. |

## 8. Implications for a Letflow MES draft (options, not decisions)

| Option | Idea | Note |
|---|---|---|
| A | Start with one chemical pilot: recipe, batch order, lot genealogy, weighing record, sign-off | Matches the vendor "core" set in section 2 |
| B | Add electronics later: serial genealogy, route enforcement | Needs machine links; the electronics client is still to be clarified |
| C | Do not compete on machine integration at first; allow operator entry and barcode | Matches "old machines" reality |

Open questions for the owner (not decided here): the electronics product type; whether granular bagging is batch or continuous; whether a pharma-style signature rule applies; the cloud or on-premise choice.

## 9. Sources (opened via search on 2026-11-12; search snippets only, pages not read in full)

| Id | Title and URL | Type |
|---|---|---|
| S1 | SG Systems, agricultural chemicals: https://sgsystemsglobal.com/industry-solutions/agricultural-chemical-manufacturing | vendor |
| S2 | SG Systems, batch control and tank farms: https://sgsystemsglobal.com/?p=34458 | vendor |
| S3 | Siemens, BASF case study: https://resources.sw.siemens.com/cs-CZ/case-study-basf | vendor |
| S4 | GetApp, chemical manufacturing software list: https://www.getapp.com/all-software/chemical-manufacturing/page-2/ | directory |
| S5 | BatchMaster chemical ERP: https://www.batchmaster.com/chemical-erp/ | vendor |
| S6 | Parsec, batch management: https://parsec-corp.com/?p=1265 | vendor |
| S7 | Parsec, TrakSYS for chemicals: https://parsec-corp.com/?p=469 | vendor |
| S8 | SYSPRO chemicals and fertilizers: https://sg.syspro.com/dl/IF/SYSPRO-Chemicals_Fertilizers-CM-IF.pdf | vendor |
| S9 | GE Vernova, MES traceability and genealogy: https://gevernova.com/software/blog/mes-traceability-genealogy | vendor |
| S10 | Slashdot chemical manufacturing software: https://slashdot.org/software/chemical-manufacturing/?page=2 | directory |
| S11 | Reliamag, best MES platforms: https://reliamag.com/topics/guides/best-mes-platforms-manufacturing | review |
| S12 | Aegis, FactoryLogix at SMT: https://www.aiscorp.com/?p=10369 | vendor |
| S13 | iConnect007, SWEMCO selects FactoryLogix: https://iconnect007.com//article/101399/swemco-selects-factorylogix-mes-for-realtime-factory-visibility/101402/smt | trade press |
| S14 | Siemens Opcenter Execution Electronics: https://www.siemens.com/en-us/products/opcenter/execution/electronics/ | vendor |
| S15 | Critical Manufacturing, electronics capabilities: https://www.criticalmanufacturing.com/blog/advanced-mes-critical-capabilities-for-electronics-manufacturing-part-2/ | vendor |
| S16 | Manufacturing Today, ten MES platforms: https://manufacturing-today.com/tech-brief/mes-platforms-manufacturing-execution/ | trade press |
| S17 | Price pages: https://www.getmonetizely.com/articles/procurement-guide-how-are-manufacturing-execution-systems-mes-priced-for-enterprises ; https://www.symestic.com/en-us/blog/mes-system-prices-2026 ; https://www.top10erp.org/products/mes-by-plex/pricing ; https://shoplogix.com/?p=10743 ; https://www.itqlick.com/wiptrac/pricing | vendor / directory |
| S18 | iConnect007, Aegis in Gartner report: https://iconnect007.com/article/108424/aegis-software-recognized-as-notable-vendor-in-gartner-report/108427/smt | trade press |
| S19 | Fabrico, MES software: https://www.fabrico.io/blog/mes-software/ | vendor |
| S20 | Wikipedia, ISA-95: https://en.wikipedia.com/wiki/ISA-95 | encyclopedia |
| S21 | ISA, ISA-95 page: https://www.isa.org/isa-95 | standards body |
| S22 | Industrial Monitor Direct, ISA-95 levels: https://industrialmonitordirect.com/blogs/knowledgebase/isa-95-automation-levels-explained-0-through-5-complete-reference | blog (conflicts with the standard) |
| S23 | OPC Foundation, ISA-95 reference: https://reference.opcfoundation.org/ISA-95/docs/2 | foundation |
| S24 | Wikipedia, ISA-88: https://en.wikipedia.org/wiki/ISA-88 | encyclopedia |
| S25 | Automation World, ISA88: https://www.automationworld.com/products/control/news/13304370/isa88-standardizes-flexible-manufacturing | trade press |
| S26 | Sepasoft, what to look for in MES: https://www.sepasoft.com/blog/learn/what-to-look-for-in-mes-software/ | vendor |
| S27 | Symestic, MES RFP: https://www.symestic.com/en-us/what-is/mes-rfp | vendor |

Limits of this scan: the standards texts themselves (paid) were not read; part editions and dates must be checked in the ISA / IEC catalogues. No vendor was contacted. Prices are not quotes.
