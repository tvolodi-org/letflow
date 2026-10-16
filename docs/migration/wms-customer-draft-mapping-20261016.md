# WMS customer requirements draft vs. our REQ-473..493 drafts (2026-10-16)

Status: mapping and gap list. It files nothing, allocates no REQ id and changes no requirement. Written by letflow-2 (BA, sole filer) at the supervisor's request.

- **Customer file:** `docs/WMS/WMS_Procurement_Requirements_Draft.md` (now versioned in this repository, copied byte for byte from the user's text in the sibling `letflow` checkout, written 2026-10-14, about 40 KB). It is the base WMS requirements document (decision 0057 D7). Its tags: **[S]** source (`WMS.docx`), **[C]** clarified by the customer, **[P]** proposed from common practice and needing customer validation. `WMS.docx` and `WMS_English_Translation.md` are intermediate files and not needed (user ruling, 0057 D8).
- **Our drafts:** REQ-473..480, 484..493, 495 on the local branch `docs/req-wms-draft-v2-20261014` (pending, no GitHub issue, not on main). They were written from relayed user decisions of 2026-10-14, not from this file.
- **Boundary kept (file section 1, "Implementation boundary"):** BPM decides when, who and which route; the module decides whether the stock operation is valid and posts it atomically. The module owns the operational stock ledger; 1C and SAP mainly hold the general ledger. Our drafts already follow this split. Where a draft embeds routing, it is listed below.

## 1. Section-by-section mapping

| File section / id | Covered by | Verdict |
|---|---|---|
| 1 Scope, boundary, BPM/module contract | REQ-475..479, REQ-480, REQ-499 (REQ-484), REQ-501 | Covered in principle. The typed outcome and domain event back to BPM are not specified (gap G1). |
| 1 Release split | slices 0 to 5 only (org, items, purchase request, goods receipt) | Our scope is far smaller than the file's "Release 1" (see G2). |
| 2 Roles | pack roles in REQ-473/475/490 | Partial: no quality inspector, supervisor, operator roles yet. |
| 2 Core identifiers, stock dimensions | REQ-474, REQ-489 | Partial: item, UoM, location string, receipt number only. No lot, serial, status, owner, custodian (G3). |
| PR-01 purchase request | REQ-475, REQ-476 | Covered (money in minor units, totals server-side). |
| PR-02 versioned attachments | REQ-487 (now GH #2588, REQ-500) | Covered, slice 1 only. |
| PR-03 approve/reject/return | REQ-477 | Covered (BPM route, `distinct_from`). |
| PR-04 assignment, supplier, PO | REQ-478, REQ-479 | Covered with plain-string supplier/PO references. Counterparty and PO entity are deliberately not built (C1). |
| PR-05 line fulfilment | REQ-478 (status half) | Partial: the receipt link exists in REQ-489..492, but no service acceptance and no payment-request link (G4). |
| PR-06 versions, no stale approval | REQ-477 `authorised_version` | Covered. |
| PR-07 stock and duplicate demand at submission | REQ-492 is the on-hand read | Gap: no requester/approver view, no duplicate-demand check (G5). |
| MD-01 item master and sync | REQ-474 | Partial: item and UoM only; no alternate units, conversion factors, barcodes, tracking policy, shelf life, storage class, sync or exception queue (G3, C1). |
| MD-02 / MD-03 locations, compatibility | none | Gap (G6). Locations are a free string in REQ-489. |
| MD-04 lot, serial, expiry | none | Gap (G3). |
| MD-05 ABC/XYZ | none | Gap, file marks it release 2 candidate. |
| MD-06 owner vs custodian | none | Gap (G3). |
| MD-07 measured length/weight | none | **Conflict C4** (integer quantity only). |
| MD-08 append-only, balanced ledger | REQ-489, REQ-491, REQ-492 | Partial and **conflict C5**. |
| MD-09 event time vs posting time, sequence | REQ-478 `event_seq` for procurement only | Gap for the stock ledger (G7). |
| WM-01 expected receipt, unplanned receipt | REQ-489..491 | Partial: a receipt line links to the request line; no expected-receipt record, no unplanned-receipt exception route (G8). |
| WM-02 discrepancy, quarantine | none | Gap (G8). |
| WM-03 .. WM-16 (labels, cross-dock, returns, putaway, replenishment, alerts, allocation, pick routes, pack, ship, counts, yard, work management, route service) | none | Gaps, outside slices 0 to 5 by design. |
| HD-01 Russian and Kazakh handheld UI | REQ-480 (API only) | Not covered; the client is a separate project. |
| HD-02 offline execution, partitions, merge resolution | none | **Conflict C2.** |
| HD-03 labels, HD-04 voice | none | Gap, option. |
| IN-01 system-of-record and interface catalog | decision (2) in REQ-473 | **Conflict C1.** |
| IN-02 idempotent messages, retries | REQ-491 (key = task id), REQ-480 | Partial for inbound commands; no outbound ERP messages (G9). |
| IN-03 pending/accepted/rejected ERP acknowledgments | none | Gap (G9). |
| IN-04 conflict and reversal rules | none | Gap; reversal of a posted receipt by a new row is not specified (G7). |
| IN-05 versioned contract with BPM, correlation chain | REQ-480 (design only) | Partial: correlation id yes, one chain across BPM, module and ERP no (G1). |
| IN-06 cross-reference IDs, exception queue | none | Gap, depends on C1. |
| CS-01 / CS-02 reports and report builder | REQ-492 on-hand only | Gap (G10). |
| CS-03 module-side permissions regardless of BPM task | REQ-491 "permission reality proven" | Covered in intent; warehouse/zone scope waits on GH #2533 and #2535 and REQ-486. |
| CS-04 LDAP/AD and SSO | not examined | Open: not checked against the platform here; no claim made. |
| CS-05 immutable audit with BPM/ERP ids | REQ-495 audit of org units; entity audit | Partial (stock operations, ERP ids missing). |
| CS-06 versioned configuration, effective dates | none | Gap. |
| 9 Nonfunctional NF-01..NF-09 | none | Gaps: all are "targets to set"; they need customer numbers first. |
| 10b Kazakhstan document matrix | REQ-488 placeholder | Content now available; **conflict C3** on who issues. |

## 2. Conflicts needing a decision (user, not a peer)

- **C1 Source of truth for masters and purchase orders.** Our drafts record a relayed user statement (2026-10-14): the module owns all in-scope data including purchase orders; 1C and SAP are ledger mirrors; no inbound master sync. The file (IN-01, MD-01, PR-04, WM-01) leaves item master, supplier, purchase order and transfer sources "to be mapped", possibly 1C or SAP, and requires sync with an exception queue. The file's own text on stock agrees with us (module owns the stock ledger).
- **C2 Offline.** Our drafts: separate online client, no offline execution in release 1, REQ-480 says so. The file: HD-02 and NF-05 require offline execution of preassigned documents, with partitions and merge resolution; its findings table marks this Critical and says Letflow mobile v1 excludes offline writes. Both are dated 2026-10-14; which holds is not established.
- **C3 Who issues the Kazakhstan legal documents.** REQ-488: in scope for the module, not assigned to 1C by default (relayed user statement). File 10b: "designated system issues the form" (1C, SAP or a legal-document service) with the module supplying evidence. REQ-488 already records that it overrides the file's default.
- **C4 Quantity type.** REQ-489 allows integer quantities only (a deliberate slice limit: a decimal is a JSON number on the wire). The file needs exact unit conversion factors (MD-01) and measured length/weight with tolerance (MD-07). Metal and cable issue is one of its acceptance scenarios, so integers cannot carry release 1.
- **C5 Ledger shape.** The file requires balanced source/destination legs per transfer, reconstruction of balances at a cut-off, nonnegative available stock, and posting reversals (MD-08, WM-06). REQ-489..492 are a single create-only receipt row with a derived sum. The no-negative guard under a lock is explicitly not delivered (REQ-492 text); GH #2532 closed delivered only field-level min/max. The drafts' note that #2532 is open is stale.
- **C6 Fixed route inside the module?** The file says the module shall not embed a fixed approval sequence. REQ-490 ships a "Goods Receipt Approval" process definition in the pack. Acceptable only as a replaceable default that a tenant's BPM can re-route without module code; REQ-490 should say so (small edit, proposed below).

## 3. Gaps (not covered by any draft)

- **G1** Typed command outcome and domain event back to BPM, one correlation chain (IN-05, NF-09).
- **G2** Release 1 scope in the file (receiving, putaway, stock, picking, shipping, counts, handhelds) versus our slices 0 to 5 (procurement and goods receipt only).
- **G3** Stock dimensions: lot, serial, expiry, inventory status, owner, custodian, alternate units, barcodes.
- **G4** Service acceptance and payment-request links (PR-05).
- **G5** Stock and duplicate-demand view at submission (PR-07).
- **G6** Location master, hierarchy and compatibility rules (MD-02, MD-03).
- **G7** Event time versus posting time, sequence, reversal by new transaction (MD-09, IN-04).
- **G8** Expected receipt, unplanned receipt route, discrepancy and quarantine (WM-01, WM-02, WM-04).
- **G9** Outbound ERP events with pending/accepted/rejected acknowledgments (IN-02, IN-03); depends on C1.
- **G10** Reports with as-of balances, exports, report builder (CS-01, CS-02).

## 4. Open customer questions (from the file's section 10 and from this mapping)

Answered by the user on 2026-10-16 (relayed; recorded in decision 0057 D10-D14), removed from the list: pilot item scales and tolerances (part of 4), which system seeds masters (1: 1C is not available, test data seeded by the BA through REQ-505), state e-document issuing (part of 1, C3: postponed, port and Z-forms only), offline maximum outage (part of 2: configuration, default 3 days; partition and conflict rules pending the architect). Retention (part of 9) is OPEN: the answer was cut off.

1. Per legal entity, warehouse and object: which system owns item masters, suppliers, purchase orders, transfers and legal documents (C1, C3)?
2. Is offline execution required in release 1, with what maximum outage, partition key and merge authority (C2)?
3. Which release-1 flows are launch requirements, later phases or priced options (reports builder, BI mart, yard, scales, voice)?
4. Are measured quantities and unit conversions required at launch (C4)?
5. Counting method per warehouse (snapshot or location freeze); evidence required to release quarantine; at which steps owner or custodian may change.
6. For which warehouses and items is unplanned receipt allowed?
7. Which item classes use FIFO, FEFO or LIFO?
8. Is "all operations on handhelds" read as physical warehouse execution only (file finding, Medium)?
9. Acceptable latency, ERP sync delay and audit retention (NF-01..NF-03).
10. Goods categories for external dispatch, to complete the 10b document matrix.

The five Kazakhmys questions in decision 0056 are unrelated to this list and remain open with the user.

## 5. Proposed changes to the local drafts (made on the local branch, not in this PR)

- Re-point REQ-484 to REQ-499 / GH #2587, REQ-487 to REQ-500 / GH #2588, and add REQ-501 / GH #2590 (module write handlers) as a prerequisite of REQ-491.
- Replace "GH #2532 open" with closed; REQ-486 depends on GH #2533 and #2535 (open).
- Add a `CUSTOMER DRAFT` traceability line to REQ-475..480, 488..492 with the file ids they cover, and the conflicts C1 to C6 as open questions in REQ-473's decision block, REQ-480, REQ-488, REQ-489 and REQ-490.
- No new REQ is drafted for G1 to G10: they are listed here so the user can rank them first.

## 6. Rulings (added 2026-10-16)

The team, not the user, rules on C1-C6 and the order of G1-G10 (delegated; sent to the advisor by the supervisor). The advisor (letflow-ec) ruled on all six; the rulings are recorded in `docs/migration/decisions/0057-wms-customer-draft-reconciliation.md` (Accepted: advisor ruling relayed by the supervisor 2026-10-16). Only the ten questions in section 4 are customer-dependent. The source files `WMS.docx` and `WMS_English_Translation.md` are not needed (0057 D8). Where documents contradict, international practice is the tie-break (0057 D9).
