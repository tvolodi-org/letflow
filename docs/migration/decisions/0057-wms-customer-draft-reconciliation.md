# 0057 -- WMS customer requirements draft: rulings on conflicts C1-C6 and the order of gaps G1-G10

Status: Accepted: ruled by the advisor session (letflow-ec) under the user's delegation, relayed by the supervisor (letflow-supervisor-22) and recorded by letflow-2 (BA), 2026-10-16. Customer-dependent items (end of this record) are NOT decided here.

Date: 2026-10-16

Source: `docs/WMS/WMS_Procurement_Requirements_Draft.md` (sibling `letflow` checkout, user, 2026-10-14) and `docs/migration/wms-customer-draft-mapping-20261016.md`. Its `[S]` tags cite `WMS.docx` and `WMS_English_Translation.md`, which are in no letflow checkout, so `[S]` wording is unchecked.

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

Pilot item scales and tolerances; who issues СНТ and ЭСФ today and whether IS ЭСФ access exists; which system seeds the masters and whether 1C keeps editing them during the pilot; offline limits later; and the source files `WMS.docx` and `WMS_English_Translation.md`.
