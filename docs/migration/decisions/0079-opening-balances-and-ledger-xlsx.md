# 0079 — Opening balances of the stock register and its xlsx files

Status: proposed (2026-11-04, REQ-677, GH #3677). Owner: `CODE-DESIGNER`. The owner accepts it at the
phase B gate (GATE B, D-063). Specification only (D-073): the stock module (ledger slice L4), its
opening balance document and the export routes are later requirements, written after GATE A.
**REVIEWER sign-off: PENDING** (placeholder, the PR carries the verdict).
**SECURITY-REVIEWER: PENDING** (placeholder, ledger and scope paths; the PR carries the verdict).

Bucket **B** (generic platform capability: any vertical that holds stock may enter an opening balance and
export its register; nothing here names a customer).

Sources: owner decisions D-061 (two read-only registers, corrections by new entries), D-062 (xlsx in the first
version; balance as of a date; the ledger backdating limit; no period close), D-063 (phase gates) and D-073
(phase B is specification only, before GATE A) in `ai-dala-portfolio/DECISIONS.md`;
`ai-dala-portfolio/architectures/assets.md` (sections "The model", "Reports and import", row "Opening balances,
old dates", review finding 4); decision 0073 (D-T, D-L12, D-C, D-P with D9 OQ-20, the slice table rows L4, L5, L7
and the PILOT GATE, OQ-11) and its amendment "Amended by REQ-676"; the ledger design note
`lib/letflow/design/gh2657-wms-stock-ledger-core.md` sections 7.6, 8 and 9 (and 10 for reversal);
`lib/letflow/design/gh2658-wms-stock-dimensions.md` line 67; decision 0077 (D1 to D3, D5, D7, D8); decision 0076
(master data layer, scope declarations, D-067); NF-08 and CS-01 of `docs/WMS/WMS_Procurement_Requirements_Draft.md`;
and the entry REQ-677 in `docs/requirements.yaml`.

Assumptions of the owner (D-086, D-087, 2026-11-04) that this record relies on, each marked
**assumption, owner may change at GATE B**: the default tenant time zone is Asia/Almaty; "signed" means a
paper signature on the printout of the document; count paperwork in phase B is xlsx with signer lines (printed
forms come in phase E); scoped posting (L6) is not part of phase B. The volumes are those of the speed test of
decision 0073 A7..A9 (stock register 3,000,000 entries and 1,000,000 balance rows; reads p95 under 500 ms with
100 concurrent readers); the numbers of 0073 win where it names them. This record states no number of its own.

## 0. Why

A customer that moves to the product brings stock it already holds. The ledger refuses an `event_time` earlier than
its posting time by more than `max_event_lateness_hours` (default 96 hours, at most 720 by rule 12, no tenant or
operator override; 0073 D-T), so an opening balance cannot carry the real receipt date as its event time. A posting
from a service task is refused with `ledger_origin_not_supported` until slice L5 (0073 D-L12). The plan of
`architectures/assets.md` therefore says: keep the real receipt date as a field, and enter opening balances through a
human-started workflow, or by service postings after L5. This record writes that path down before slice L4 builds the
stock module, so L4 and the B4 stock workflows do not each invent one.

## D1. No backdating

- An opening posting carries `event_time` equal to its `posting_time`: it is an online posting with no
  `client_event_time` (note 8.1), never the real receipt date.
- Reason: 0073 D-T. The lateness cap is 96 hours by default, rule 12 caps a registration at 720 hours, and there is
  no tenant or operator override and no runtime setting. A receipt date months back would be refused
  `event_time_too_old`.
- The real receipt date is a field of the opening line, linked to its leg by `document_line_id` (note 9.1). This
  differs from `gh2658` line 67 (the receipt date is the posting time) for this cause only: for every other cause the
  receipt date stays the event time or the posting time, with no slot.
- Consequence for reports (B2 must say so on screen and in the export): a balance as of an event time earlier than
  the opening posting shows **no** opening quantity (note 8.2, basis "as of event time": `event_time <= T AND
  posting_seq <= N`). The opening is visible from the day it is posted.

## D2. The opening document and its posting

- The opening balance document type is managed by the stock module of slice L4.
- Line fields (R = required):

| Field | R | Content |
|---|---|---|
| org unit | R | the org unit of the document; the same on every line (D5) |
| location | R | a location linked to that org unit (D3) |
| responsible employee | R | an `org_employee` id (D-065, REQ-643, REQ-661) |
| catalog item | R | the catalog item |
| lot | when the item's `tracking_policy` (REQ-641) is `lot`, else empty | a lot of that item |
| quantity | R | decimal, greater than zero |
| unit | R | the item's base unit |
| receipt date | R | the real date the stock was received; a field, not the event time (D1) |
| unit price | optional | stays on the line |
| value | optional | stays on the line |

- Unit price and value stay on the line and are **not** slots or legs of the register (`architectures/assets.md`,
  review finding 4: price and value live on the document, not in the register).
- One document has at most 200 lines, because a posting has at most 200 legs (note 7.6). This equals
  `@import_record_cap` of `lib/letflow/routers/entities/record_import.ex`. A larger stock is entered as several
  documents.
- One document gives exactly one posting with the cause `opening`. The stock module registers the cause with the
  sign rule **positive** (the sign rules are those of 0073 D-C; the cause name `opening` is this record's). The
  posting carries the document's `document_type` and `document_id`, and one `document_line_id` per leg.

## D3. Line checks

Before the posting every line is checked; one row per check.

| Check | Source | Provided by |
|---|---|---|
| quantity greater than zero | sign rule positive of the cause (0073 D-C) | ledger slice L2 / L4 (stock module cause registration) |
| unit equals the item's `base_uom_id` (`priv/modules/catalog_items/entity_definitions/catalog_item.json`) | conversion is out of 0073's scope | stock module, slice L4 |
| org unit and location linked | D-065, REQ-644, REQ-662 | phase A (links) |
| lot belongs to the item | REQ-647, REQ-664 | phase A (lots) |
| lot present when the tracking policy asks for it | REQ-641 | phase A (item tracking policy) |
| responsible employee cell names an `org_employee` record | D-065, REQ-643, REQ-661 | phase A (employees) |

Master checks (item, location and unit active) come **only** with slice L7 (0073 D-P (D7) and D9 OQ-20: no master,
version or retired-master checks in L1..L4; the slice table row L7 and the PILOT GATE). So the opening document, like
the stock module, is not offered on a customer tenant before the PILOT GATE of 0073.

## D4. Workflow steps of the human-started opening process

1. A user starts an opening document for **one org unit**. A document type has one scope column (decision 0051 D6)
   and documents are scoped by org unit (D-067), so every line names that org unit.
2. Lines are typed or imported (D5).
3. A check of all lines answers per-line results (D3) and posts nothing.
4. A second user approves.
5. The approval posts (D2).

The steps are a process definition that the process owner configures in production. "The approver is not the user who
started the document" is a **UAT assumption, to be confirmed by the process owner**. Which role holds the permission to
post an opening document is not decided here; it is an open owner question (Q1). 0073 OQ-11 (role grants for the
permission atoms) is decided in slice L4.

## D5. xlsx import of opening lines

- Lines are imported through the managed import path of REQ-651: an import function registered by the stock module for
  the line type, **upsert by external ref only**.
- Reader, limits and mapping are those of 0077 D1 to D3 unchanged: first worksheet only, at most 200 data rows,
  2_097_152 bytes body, 26_214_400 bytes uncompressed. The dry run is that of 0077 D7.
- The org unit, location, employee, item, lot and document cells hold **external ids**, as references do in REQ-651.
- An import writes **draft lines only** and never posts. Only the approval step of D4 posts.
- Template columns: `org_unit`, `location`, `responsible_employee`, `item`, `lot`, `quantity`, `unit`, `receipt_date`,
  `unit_price`, `value`, `document`, `external_ref_system`, `external_ref_id` (one column per line field of D2, the
  document reference, and the two external ref columns).

## D6. Corrections and repeats

- A posted opening is never edited. A wrong opening is corrected by a **reversal of its whole entry** (note section
  10, slice L2b) and a new document (D-061: corrections by new entries).
- The posting of one document uses one `client_op_id`. A repeated approval of the same document answers the first
  posting's result and posts nothing more (note 9.2, idempotency per `subject_id` and `client_op_id`).
- An opening document is accepted at any time, also for a balance key that already has a balance, because cut-over is
  set per warehouse (NF-08). **UAT assumption, to be confirmed by the process owner.** (Default, owner may change at
  GATE B.)

## D7. Service path after L5

- A posting from a service task, such as a background import that posts without a human approval per document, is
  refused with `ledger_origin_not_supported` until slice L5 (0073 D-L12). This record does not design it.
- L5 must first meet the lifting conditions of D-L12: (a) the ledger rows are taken as lock-only pre-steps before the
  task-activation audit, with balance keys resolvable at plan time; (b) the subject's roles are re-resolved from the
  database at run time, the platform sentinel never holds the post permission and the `credential` rule applies; (c)
  when script-produced variables feed legs, activation requires an explicit consent flag on the node recorded with
  `activated_by`; (d) the cycle test T-LK-4 is inverted.
- The service path keeps the no-backdating rule of D1 and the 200-leg bound of D2.
- It needs its own requirement after L5, with the human path of D4 kept.

## D8. xlsx export of balances and movements

Two xlsx exports of the stock register, for the read routes of slice L4:

- **Balances**: one row per balance key: the slot values as stored, quantity and unit.
- **Movements**: one row per leg: `posting_seq`, `posting_time`, `event_time`, cause, `document_type`, `document_id`,
  the slot values, quantity, unit and, for a reversal, the reversed entry.

Each file has a second sheet holding the report fields of note 8.4: `basis`, `cutoff_seq`, `as_of`, `timezone`
(default Asia/Almaty, **assumption, owner may change at GATE B**), `filters`, `ledger_seq` (CS-01: the time basis on
each report).

- They are written with `Letflow.Entities.XlsxExport.build/3` or a sibling renderer on the `elixlsx` dependency of
  0077 D8. No new dependency.
- A file holds only the rows the caller's read answers (D-067; item B6 for a scoped caller), never more. Balances and
  movements are scoped by org unit; org unit, location, item and lot names are readable tenant-wide.
- Price and value are not in these files (they are on documents).
- An exported balance file is **not** promised to re-import as an opening document (**UAT assumption, to be confirmed
  by the process owner**, as in REQ-653).

## D9. Phase A dependencies

This record rests on: D-066 (trees and storage) with REQ-642, REQ-645, REQ-646 and REQ-649 (org tree path and depth
bound, location tree, master data as real columns, decision 0076); D-067 and decision 0076 (scope); employees D-065,
REQ-643 and REQ-661; links REQ-644 and REQ-662; lots REQ-647, REQ-664 and REQ-641; codes REQ-648 and REQ-663 (**not
used** by an opening line; an inventory object's codes are assigned through the codes module); import and export
REQ-650, REQ-651, REQ-653, REQ-654 and the import screen REQ-675; ledger REQ-620, REQ-621 and REQ-676. It is amended if
the GATE A check changes any of them (D-073).

Out of scope: the asset register and asset lists with amortization (phase C; see Q4), balance as of a date and the
audit trail (B2), stock workflows (B4), counts (B5), the scoped balances read (B6), import of historical movements
into the ledger, period close (D-062).

## Open owner questions

Each has a default; the owner may change it at GATE B.

- **Q1. Which role may post an opening document?** Not in any source. Default: the role that holds the post permission
  of the stock module, decided in slice L4 with 0073 OQ-11 (default, owner may change at GATE B).
- **Q2. Is a second person required to approve?** Default: yes, as in D4 (default, owner may change at GATE B).
- **Q3. Is an opening accepted at any time per balance key?** Default: yes (D6), a UAT assumption.
- **Q4. Does the asset register of phase C reuse the opening document?** Default: no decision here; phase C decides,
  and may reuse D1 to D6 (default, owner may change at GATE B).
- **Q5. When is the service path of D7 wanted?** Default: not before the PILOT GATE and not before L5 (default, owner may
  change at GATE B).
