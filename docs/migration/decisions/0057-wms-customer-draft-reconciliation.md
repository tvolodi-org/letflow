# 0057 -- WMS customer requirements draft: rulings on conflicts C1-C6 and the order of gaps G1-G10

Status: Accepted: ruled by the advisor session (letflow-ec) under the user's delegation, relayed by the supervisor (letflow-supervisor-22) and recorded by letflow-2 (BA), 2026-10-16. Customer-dependent items (end of this record) are NOT decided here.

Date: 2026-10-16

Source: `docs/WMS/WMS_Procurement_Requirements_Draft.md` (the base document, addendum D7; user, 2026-10-14) and `docs/migration/wms-customer-draft-mapping-20261016.md`. Its `[S]` tags cite `WMS.docx`, an intermediate file that is not needed (addendum D8).

Kept boundary (file section 1): BPM decides when, who and which route; the module decides whether a stock operation is valid and posts it atomically. The module owns the operational stock ledger; 1C and SAP mainly hold the general ledger.

## Rulings

- **D1 (C1) Source of truth.** The module owns items, suppliers, purchase orders and stock. No inbound master sync. Masters come in by a one-time idempotent import (`EntitiesRecordsImport`, upsert by external id). Every master has a nullable `external_ref` `{system, id}` from day one.
- **D2 (C2) Offline.** Online first, offline later; REQ-480 stays. The client API stays offline-ready: a client-generated idempotency key on every command, a version on every mutable resource, event time separate from posting time, typed 409 conflicts. Nothing else is built for offline.
- **D3 (C3) Legal documents.** A `legal_document_issuer` port with two implementations: module-issued (the З-forms) and external-issued (СНТ, ЕСУТД: the module sends the data, waits for the registration number as acknowledgment, and dispatch is gated on it). One configuration per (document type, legal entity). Build the port and the З-forms only; no СНТ or ЕСУТД integration until access is confirmed.
- **D4 (C4) Quantity.** Exact decimal everywhere, a string on the wire, a scale per unit of measure, a rounding rule per item (half-up by default). Conversion factors are decimal strings applied to the base unit at posting. The ledger stores the base quantity plus the original quantity and unit. A tolerance rule sits on the item for measured goods.
- **D5 (C5) Ledger.** Take the file's model: append-only `stock_movement`, a header plus legs (item, location, status, lot, quantity delta, base unit); a transfer sums to zero per item; balances are derived by sum; cut-off is `posting_seq <= N`; one gap-free posting sequence per tenant or warehouse; a reversal is a new header that references the original. The no-negative guard runs inside the module write handler (REQ-501 mechanism) under row locks in a fixed order (item id, then location). `stock_balance` is a same-transaction cache, never the source of truth. REQ-489's single create-only receipt row is the wrong base.
- **D6 (C6) Replaceable routes.** REQ-490 states that the pack's process definition is a replaceable default that the tenant can version and re-route. The handler checks only the outcome contract (approved, by whom, bound to which version), never the route.

## Order of gaps

1. G7 posting sequence, event time versus posting time, reversal. 2. G3 stock dimensions: lot, serial, expiry, status, owner, custodian and alternate-unit columns go into the ledger schema now. 3. G1 typed outcome and event to BPM with one correlation chain (in REQ-480). 4. G6 location master and hierarchy. 5. G8 expected and unplanned receipt, discrepancy, quarantine. 6. G5 stock and duplicate-demand view. 7. G4 service acceptance and payment link. 8. G9 outbound ERP events with acknowledgments (waits for 1C/SAP access). 9. G10 reports. 10. G2 is a scope statement; the slices stay.

## Verification note on D4 (read by letflow-2, not run)

The advisor marked the core risk as not verified. Reading the repo on main 08a43e0b: a `:decimal` entity field requires `decimal_precision` and `decimal_scale` and maps to `numeric(p,s)` (`lib/letflow/entities/definition/validator.ex:471-485`, `ddl.ex:581-584`); `min`/`max`/`non_negative` are legal on integer and decimal (validator.ex:512, GH #2532 closed). But the write-side JSON schema for a decimal field is `{"type": "number"}` (`lib/letflow/entities/record/validator.ex:108`), so a decimal STRING is rejected on write and a JSON number is a float on the wire. The scale is per field, not per record, so a per-unit scale cannot be expressed. This is filed as a core issue (see the mapping document).

## Verification note on D1

The records import route creates a record per entry (`lib/letflow/routers/entities.ex:70`: `Records.create_record/2` per entry); an upsert by external id is not there, and no `external_ref` field exists in `lib/`. Both are module or core work to be specified.

## Effect on the drafts (local branch `docs/req-wms-draft-v2-20261014`)

REQ-489..492 (single-row receipt) are re-based: they are NOT to be filed as written. New drafts replace them in the order above. REQ-480 gains the offline-ready rules and G1. REQ-488 becomes the `legal_document_issuer` port. REQ-490 gains the replaceable-default text.

## Customer-dependent items (for the user, in plain language)

Answered 2026-10-16 (see the addendum, D10-D14): pilot scales, e-document systems, cutover and seed data, offline outage. Still open: document retention (the answer was cut off), and the later questions of the mapping document section 4.

## Addendum: user ruling of 2026-10-16 (relayed by the supervisor)

- **D7 Base document.** `docs/WMS/WMS_Procurement_Requirements_Draft.md` is THE base WMS requirements document. It is versioned in this repository, copied byte for byte from the user's text (the sibling `letflow` checkout, written 2026-10-14). The team may extend it; the user's text is not edited in place, so extensions go in the mapping document, decisions and the requirement entries.
- **D8 Source files not needed.** `WMS.docx` and `WMS_English_Translation.md` are intermediate files and are not needed. The earlier note that the `[S]` tags are unchecked is withdrawn, and the request for those files is removed from the customer questions.
- **D9 Precedence.** Where documents contradict, international practice takes priority, including over the base draft itself. It is the tie-break for any conflict. A decision that applies it cites the practice. The practice cited so far, which the base draft also lists in its section 12 as established patterns:
  - append-only inventory ledger with balanced postings and reversal by a new entry (the stock movement model of D5; the draft's MD-08 states the same, and the product documentation it lists, Microsoft Dynamics 365 Supply Chain inventory and warehousing, uses posted inventory transactions that are corrected by new transactions);
  - GS1 application identifiers for item, lot, expiry and serial in barcodes (the draft's HD-03 and MD-01 are consistent with this);
  - cycle counting with variance review before an adjustment posts (WM-12).
  No conflict between the draft and these practices has been found so far, so D9 changes no earlier ruling; it applies to conflicts found later. The citations are to the standards and documents named, not to a clause-level reading of them by letflow-2.

## Addendum: user answers of 2026-10-16 (relayed by the supervisor)

The user answered the customer-dependent items above. Recorded as relayed; the user's own wording is not available to the team.

- **D10 Pilot item scales and tolerances.** By common practice: ISO and standard unit scales, as defaults, configurable per item class. No customer-specific numbers are needed for the pilot (resolves the open item for D4 / REQ-504 defaults).
- **D11 State e-document systems.** IS ЭСФ, ЕСУТД and СНТ issuing are POSTPONED. Build the `legal_document_issuer` port and the module-issued Z-forms only (REQ-488); no state integration. The registration-number gate of D3 stays as the condition for any later external issuer.
- **D12 Cutover and seed data.** 1C is not available now. The pilot is seeded with TEST DATA; the BA (letflow-2) produces the seed data set (items, suppliers, locations, org) and loads it through the generic idempotent import (REQ-505). The team does not wait for 1C. Whether 1C later edits masters stays out of scope until it exists (D1: the module owns masters).
- **D13 Offline limits.** The maximum outage is a configuration value, default 3 days. Partitioning and conflict rules: the architect advises (asked of the advisor letflow-ec by the supervisor); the answer is combined into the REQ-480 text when it arrives. Not decided here.
- **D14 Retention of documents: OPEN.** The user's answer was cut off in transmission. Until it is re-sent, retention is configurable; a conservative placeholder number is adopted only where a requirement needs one, and is marked PROVISIONAL there.
