# Stock workflow documents: receipt, issue, transfer, hand over, return, write off

Status: specification, not built (REQ-679, GH #3670, assets phase B item B4). Docs only: no code, no
migration, no definition JSON, no route, no screen. The module, its types, its process definitions and its
ledger registration are later requirements, written after GATE A from this file. GATE B still needs the
owner's check with the portfolio manager (D-063, D-073).

Sources: owner decisions D-061 (only workflows write to the registers; registers are read-only and corrected
by new entries), D-062 (documents are fixed once signed; balance as of a date; backdating limit; audit
trail), D-065 (employees, links, codes, Inventory Object as its own record), D-066 (storage and trees),
D-067 (scope by org unit) and D-073 (phase B specifications before GATE A) in
`ai-dala-portfolio/DECISIONS.md`; decision 0073 (domain-neutral ledger primitive, as amended by REQ-676,
section "Amended (REQ-676, assets B1)") and decision 0076 (master data layer) in `docs/migration/decisions/`;
and the requirement entry REQ-679 in `docs/requirements.yaml`.

Marks used below: **proposal** = the business analyst's proposal, to be confirmed by the owner at GATE B;
**default** = the simplest reasonable default taken for an open question, "default, owner may change at
GATE B"; **assumption** = "assumption, owner may change at GATE B" (owner decisions D-086 and D-087,
2026-11-04).

## 1. Common rules

### 1.1 Ledger rules applied (decision 0073 and its REQ-676 amendment)

* Postings come from a human task (user task node). A service task posts only when its node carries the explicit consent flag `ledger_post_consent` and the definition was activated with an OIDC credential (REQ-688, D-L12); without it the SERVICE origin is refused.
* `event_time` of a posting is the document's event time field. It may be at most 96 hours back and at most
  5 minutes ahead; beyond that the posting is refused with `event_time_too_old` or `event_time_in_future`
  (D-T). An older date is an opening balance (item B3), not one of these documents.
* Sign rules per cause (D-C): `positive`, `negative`, `zero_sum_by_slot_1`, `any` (and `reversal`, used only
  by the reversal of a posting).
* The module policy `declare/2` reads no master data (D-P). Master checks therefore run in the stock module's
  own write path, before the posting. The ledger's own master validation is slice L7 (D6).
* One fixed ledger id per tenant for the stock register (D-L3). These documents post to the stock ledger id
  only, one posting per transaction. The two-register transaction of REQ-676 (A2) is for the change of kind
  (phase C) and is not used here.
* A scoped principal cannot post until slice L6 (0073 D9, OQ-21). Scoped posting is not part of phase B
  (assumption, owner may change at GATE B).

### 1.2 Stock register slots

Slots: **OrgUnit, Location, Responsible, SKU, Lot**. The unit of measure is the ledger's `unit_ref`, not a
slot. Slots are named here by name, never by `k1..k8` position. Price and value are never a slot (section 4).

### 1.3 Plain tables

Each document is two module-managed record types of the stock module (slice L4): a **header** and a
**line**. Tables are plain; nothing is stored as a blob.

* The line-to-header reference (`header_id`) is a foreign key inside the pack. Every master reference is a
  declarative record id checked in code (decision 0076 R6 rules 2 and 5), not a foreign key.
* Field types come from the closed list `@field_types` of `lib/letflow/entities/definition/validator.ex`:
  string, integer, decimal, boolean, date, datetime, enum, json, localized_text.
* Every quantity field is a decimal field with `decimal_strict: true`
  (`lib/letflow/design/gh2654-decimal-exact-strings.md` D1, D3, D5).
* Type names (proposal): `stock_receipt` / `stock_receipt_line`, `stock_issue` / `stock_issue_line`,
  `stock_transfer` / `stock_transfer_line`, `stock_handover` / `stock_handover_line`, `stock_return` /
  `stock_return_line`, `stock_writeoff` / `stock_writeoff_line`.

### 1.4 Header fields common to all six documents

REQ-712 (GH #3749) replaced the first draft of this table. The header record holds only the fields below.
The **number, state and issued time are not stored on the header**: they are read from the versioned document
of decision 0056 (`Letflow.Documents`) that `document_id` names (number gap-free per document type, assigned
at issue; state draft, issued or cancelled from the status of its live version). Who posted, when, and the
reversal entry are read from the posting marks of REQ-713 and the ledger entry, not stored on the header
either. So the header has no `number`, `status`, `posted_at`, `posted_by` or `reversed_by_entry` field.

| Field | Type | Req. | Master |
|---|---|---|---|
| `document_id` | string (id of the versioned document) | yes | none |
| `event_time` | datetime (ISO 8601 with offset, stored in UTC) | yes | none |
| `org_unit_id` | string (record id) | yes (the scope column, section 9) | org_unit |
| `note` | string | no | none |

Each document's own header fields are added in its section. Common line fields: `id`, `header_id`
(FK in pack, required), `line_no` (integer, required), and `catalog_item_id` (SKU, required, master
catalog_item), `catalog_uom_id` (unit, required, master catalog_uom), `catalog_lot_id` (lot; optional,
required when the item's tracking policy requires a lot, REQ-641; master catalog_lot), `quantity`
(decimal strict, required, greater than zero).

Time zone (assumption, owner may change at GATE B): the default tenant time zone is Asia/Almaty. It is used
only to show and to enter dates; `event_time` is stored in UTC.

## 2. Receipt

**Meaning (proposal, confirmed by the owner at GATE B):** a receipt adds a quantity of a SKU (and lot) to an
org unit, location and responsible employee, from a counterparty or from none.

Header fields (beyond 1.4):

| Field | Type | Req. | Master |
|---|---|---|---|
| `location_id` | string | yes | location_node |
| `responsible_id` | string | yes | org_employee |
| `counterparty_id` | string | no ("from none") | catalog_counterparty |
| `supplier_document_ref` | string | no | none |

Line fields (beyond 1.4): `unit_price` (decimal, `decimal_strict` true, optional), `line_value` (decimal,
`decimal_strict` true, optional). These two are the only price and value fields in the six documents
(section 4).

Ledger legs:

| Cause | Sign rule | reason_required | Legs per line |
|---|---|---|---|
| `receipt` | positive | false | 1 |

| Leg | OrgUnit | Location | Responsible | SKU | Lot | unit_ref |
|---|---|---|---|---|---|---|
| 1 (+quantity) | header `org_unit_id` | header `location_id` | header `responsible_id` | line `catalog_item_id` | line `catalog_lot_id` | line `catalog_uom_id` |

Master checks: section 8, rows "receipt".

## 3. Issue

**Meaning (proposal):** an issue removes a quantity from the register (consumed, sold or given outside the
register).

Header fields (beyond 1.4): `location_id` (yes, location_node), `responsible_id` (yes, org_employee),
`reason_text` (string, no). No price or value field.

Line fields: common only.

| Cause | Sign rule | reason_required | Legs per line |
|---|---|---|---|
| `issue` | negative | false | 1 |

| Leg | OrgUnit | Location | Responsible | SKU | Lot | unit_ref |
|---|---|---|---|---|---|---|
| 1 (-quantity) | header `org_unit_id` | header `location_id` | header `responsible_id` | line `catalog_item_id` | line `catalog_lot_id` | line `catalog_uom_id` |

## 4. Price and value on the document only

* The receipt line carries `unit_price` and `line_value`, both decimal with `decimal_strict: true`.
* Price and value are never a ledger slot, a leg column or a balance column. The ledger counts quantity only.
* Issue, transfer, hand over, return and write off carry no price or value field in this specification.

Open owner questions, with defaults (default, owner may change at GATE B):

* Currency field. Default: none; one tenant currency, shown by the screen, not stored on the line.
* Is the line value typed or computed from quantity and price, and its rounding? Default: typed by the user,
  checked only to be a non-negative decimal; no rounding rule is applied by the module.
* Do issue or write off documents need a value? Default: no.

## 5. Transfer

**Meaning (proposal):** a transfer moves a quantity from one org unit and location to another.

Header fields (beyond 1.4; `org_unit_id` of 1.4 is the **from** unit):

| Field | Type | Req. | Master |
|---|---|---|---|
| `from_location_id` | string | yes | location_node |
| `from_responsible_id` | string | yes | org_employee |
| `to_org_unit_id` | string | yes | org_unit |
| `to_location_id` | string | yes | location_node |
| `to_responsible_id` | string | yes | org_employee |

Line fields: common only.

| Cause | Sign rule | reason_required | Legs per line |
|---|---|---|---|
| `transfer` | zero_sum_by_slot_1 | false | 2 |

| Leg | OrgUnit | Location | Responsible | SKU | Lot | unit_ref |
|---|---|---|---|---|---|---|
| 1 (-quantity) | header `org_unit_id` | `from_location_id` | `from_responsible_id` | line `catalog_item_id` | line `catalog_lot_id` | line `catalog_uom_id` |
| 2 (+quantity) | `to_org_unit_id` | `to_location_id` | `to_responsible_id` | line `catalog_item_id` | line `catalog_lot_id` | line `catalog_uom_id` |

## 6. Hand over to a person

**Meaning (proposal):** a hand over moves a quantity to an employee who uses it (inventory in use,
`assets.md` "The gray zone"). It stays in the register, with that employee as Responsible.

Header fields (beyond 1.4; `org_unit_id` is the unit that hands over):

| Field | Type | Req. | Master |
|---|---|---|---|
| `from_location_id` | string | yes | location_node |
| `from_responsible_id` | string | yes | org_employee |
| `to_org_unit_id` | string | yes (may equal `org_unit_id`) | org_unit |
| `to_location_id` | string | yes | location_node |
| `to_responsible_id` | string (the employee who receives) | yes | org_employee |

Line fields: common only. Cause `handover`: sign rule zero_sum_by_slot_1, reason_required false, 2 legs per
line. Legs: as transfer (section 5), leg 2 carries the receiving employee in the Responsible slot.

## 7. Return and write off

### 7.1 Return

**Meaning (proposal):** a return moves a handed-over quantity back from the employee.

Header fields (beyond 1.4; `org_unit_id` is the unit the quantity returns to): `from_org_unit_id` (yes,
org_unit), `from_location_id` (yes, location_node), `from_responsible_id` (the employee who returns; yes,
org_employee), `to_location_id` (yes, location_node), `to_responsible_id` (yes, org_employee).

Line fields: common only. Cause `return`: zero_sum_by_slot_1, reason_required false, 2 legs per line. Leg 1
(-quantity): `from_org_unit_id`, `from_location_id`, `from_responsible_id`. Leg 2 (+quantity): `org_unit_id`,
`to_location_id`, `to_responsible_id`. SKU, Lot and `unit_ref` as in section 5.

### 7.2 Write off

**Meaning (proposal):** a write off removes a quantity that is lost, damaged or used up, with a reason.

Header fields (beyond 1.4): `location_id` (yes, location_node), `responsible_id` (yes, org_employee),
`reason_code` (enum lost, damaged, used_up, other; yes), `reason_text` (string; required when `reason_code`
is other). No price or value field.

| Cause | Sign rule | reason_required | Legs per line |
|---|---|---|---|
| `writeoff` | negative | **true** | 1 |

Leg 1 (-quantity): as the issue leg (section 3). The ledger reason is filled from `reason_code` and
`reason_text`.

### 7.3 Conservation of the two-leg causes

Transfer, hand over and return post two legs with opposite signs and equal quantity per line, so they
conserve the quantity per SKU and per lot. The sign rule `zero_sum_by_slot_1` conserves only the value of
slot 1 (OrgUnit, in the order above); it does not itself prove that the SKU and the lot are equal on both
legs. That gap is an **open design question for the stock registration of slice L4**. This file chooses no
slot order of its own. Until slice L4 answers it, the module's write path builds both legs from the same
line fields (sections 5 and 6), so equality holds by construction.

## 8. Master checks (stock module write path, before the posting)

A failed check posts nothing and leaves the document a draft. They run in the module's own write path
because `declare/2` reads no master data (0073 D-P) and the ledger's master validation is slice L7 (D6).

| Check | Function (origin/main) | Receipt | Issue | Transfer | Hand over | Return | Write off |
|---|---|---|---|---|---|---|---|
| SKU active | `Letflow.Modules.CatalogItems.active?/2` | yes | yes | yes | yes | yes | yes |
| Unit valid for the SKU (today the base unit only) | `Letflow.Modules.CatalogItems.item_uom_valid?/3` | yes | yes | yes | yes | yes | yes |
| Lot belongs to the SKU | `Letflow.Modules.CatalogItems.item_lot_valid?/3` | yes | yes | yes | yes | yes | yes |
| Location active | `Letflow.Modules.Locations.active?/2` | yes | yes | both | both | both | yes |
| Org unit active | `Letflow.Modules.Org.active?/2` | yes | yes | both | both | both | yes |
| Org unit and location linked (the not-linked rule; a movement whose unit and location are not linked is refused) | `Letflow.Modules.Locations.linked?/3` | yes | yes | both legs | both legs | both legs | yes |
| Responsible employee active | `Letflow.Modules.Org.active_employee?/2` | yes | yes | both | both | both | yes |
| Counterparty active | `Letflow.Modules.CatalogItems.active?/2` (covers every catalog_items type) | if given | n/a | n/a | n/a | n/a | n/a |

Default (owner may change at GATE B): the responsible employee is not required to belong to the document's
org unit (section 11).

## 9. Life cycle, process shape and access

### 9.1 Life cycle

States as read from the versioned document and the posting marks: **draft, issued, posted, reversed** (and
**cancelled**, REQ-713). In REQ-712 only draft and issued exist; issue gives the number and fixes the content
(decision 0078 D5: issue first, post second). The state is not a header field (section 1.4).

* A draft may be edited, discarded and posts nothing.
* An issued document is fixed (no header or line field changes) and waits for its posting.
* Posting is one transaction that commits the ledger posting and marks the document posted, or commits
  neither.
* After posting no field of the header or of any line changes, and the document is never deleted (D-062:
  documents fixed once signed; D-061: corrections by new entries). "Signed" means a paper signature on the
  printout of the document (assumption, owner may change at GATE B); the document is fixed by posting in the
  system, not by an electronic signature.
* A posted document is corrected only by a reversal of its posting under the reversal rules of decision 0073
  (as amended by REQ-676). The reversal marks the document reversed and keeps it. A correct replacement is a
  new document.
* The event time of the posting is the document's `event_time`, refused beyond 96 hours back or 5 minutes
  ahead (section 1.1). An older date is an opening balance (item B3).

### 9.2 Process shape

For each document the stock module has one process definition (`receipt`, `issue`, `transfer`, `handover`,
`return`, `writeoff`) in which the posting runs on a **user task** node whose module write handler declares
`posts_ledger` (`lib/letflow/design/gh2657-wms-stock-ledger-core.md` section 14.3), never on a service task
node (0073 D-L12). The posting goes to the stock ledger id only, one posting per transaction. The posting
handler writes through `create/3` its bookkeeping target (0073 Consequences, cost note): the document
header's posting record, a managed type `stock_posting_mark` of the stock module (proposal). No approval
step is named (open question, section 11).

### 9.3 Access

* Every header and line type declares the scope `{:column, "org_unit_id"}` (decision 0076 R7: documents
  scoped by org unit). The line type carries a copy of the header's `org_unit_id`. For transfer, hand over
  and return, which have two org units, the column holds the unit in `org_unit_id` of the header (transfer:
  from unit; hand over: the unit that hands over; return: the unit the quantity returns to). Whether the
  other unit sees such a document (a masked other side) is an item for B6 (D-067).
* Post and reverse use the stock registration's `post` and `reverse` permissions (rule 12 requires them to be
  distinct). Their role grants are 0073 OQ-11 of slice L4. No role is named here. A scoped principal cannot
  post until slice L6 (0073 D9, OQ-21).
* A line field filled from a scanned code is resolved by `Letflow.Modules.Codes.resolve/2`. A target out of
  the principal's scope answers like an unknown code (0076 R7 ruling 2).
* The audit trail of the documents is scoped by org unit like the other scoped types (D-067; assumption,
  owner may change at GATE B).

## 10. Speed assumptions

Assumed volumes are those of the speed test (decision 0073 A9 numbers win where it names them): stock
register 3,000,000 entries and 1,000,000 balance rows; asset register 100,000 entries and 50,000 balance
rows; reads at p95 under 500 ms with 100 concurrent readers. Posting one document under 500 ms, a list page
under 300 ms, a balance as of a date under 1 s. All are assumptions, owner may change at GATE B. The storage
shape (partitioned or separate tables) follows the speed test result under 0073 A8.

## 11. Open owner questions

Each has a source and a default (default, owner may change at GATE B).

1. Money questions of section 4 (currency, typed or computed value and its rounding, value on issue and write
   off). Source: `assets.md` review finding 4. Default: as in section 4.
2. Approval before posting. Source: `assets.md` open question 6. Default: none; the user who holds the
   `post` permission posts.
3. Whether the responsible employee must belong to the document's org unit. Source: REQ-679 open questions.
   Default: no.
4. The meaning of the six documents (sections 2 to 7). Source: REQ-679 criterion 2. To be confirmed at
   GATE B.
5. Inventory Object lines (D-065: its own record type, no entry yet). Default: not part of these documents.
6. Conservation per SKU and lot against `zero_sum_by_slot_1` (section 7.3): a design question for the stock
   registration of slice L4, not for the owner.

## 12. Phase A dependencies

This file rests on the following phase A decisions and requirements. It is amended if the GATE A check
changes any of them (D-073).

* Storage and trees, D-066: REQ-642 (master data as real columns and foreign keys inside a pack,
  cross-pack references declarative), REQ-645 and REQ-646 (location tree), REQ-649 (org tree path, depth
  bound 40, a unit with a balance cannot be retired).
* Access and scope, D-067: decision 0076 R7, REQ-674 (uuid scope column fix), REQ-519 (enforcement).
* Employees, D-065: REQ-643, writes REQ-661.
* Links: REQ-644, writes REQ-662.
* Codes: REQ-648, writes REQ-663.
* Lots and catalog: REQ-647 (writes REQ-664), REQ-604 (counterparty type), REQ-641 (item tracking policy).
* Ledger: REQ-616 (decision 0073), REQ-620, REQ-621, REQ-676 (B1).

Out of scope: balance as of a date and the audit trail (B2), opening balances (B3), counts (B5; count
paperwork in phase B is xlsx with signer lines, printed forms come in phase E), the scoped balances read
(B6), the change of kind and every asset register document (phase C), Inventory Object lines, printed
hand-over paperwork, signatures and labels (phase E), xlsx import of documents, period close (D-062).
