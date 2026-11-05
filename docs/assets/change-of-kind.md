# Change of kind: stock becomes a tracked asset

Status: specification, not built (REQ-691, GH #3719, assets phase C item C3). Docs only: no code, no
migration, no definition JSON, no route, no screen, no seed. The asset module, its document types, its
process definition and its ledger registration are later requirements, written from this file after the
phase C gate (D-063, D-085).

A change of kind is one workflow document by which a quantity held in the stock register becomes a tracked
record of the asset register (the example of `architectures/assets.md`: a chair bought as inventory becomes a
tracked low-value asset). Posting it is one transaction that posts to both registers with the same document id.

Sources: owner decisions D-061 (one transaction may post to two registers), D-063 (a manual gate ends each
phase), D-065 (an Inventory Object is its own record with its codes; responsible person and actual user hold
employee ids), D-067 (assets and documents scoped by org unit) and D-085 (phase C specifications may be
written now) in `ai-dala-portfolio/DECISIONS.md`; decision 0073 (`docs/migration/decisions/0073-domain-neutral-ledger-primitive.md`)
with its section "Amended (REQ-676, assets B1)", items A2, A3 and A4; decision 0076 (master data layer, R7
visibility table); REQ-679 (B4, `docs/assets/stock-workflow-documents.md`); and this entry, REQ-691 in
`docs/requirements.yaml`.

Marks used below: **proposal** = the business analyst's proposal, to be confirmed by the owner at the phase C
gate; **from C1** = an item of the asset register side (ledger id, slot set, causes, asset card type) that
phase C item C1 specifies and that has no requirement entry yet. This file uses the asset slot set of
`architectures/assets.md` (OrgUnit, Location, MaterialResponsible, ActualUser, Asset). When the C1 entry
exists it is added to `depends_on` of REQ-691 by an amendment.

## 1. Which items change kind (proposal)

The table is a proposal, to be confirmed by the owner at the phase C gate (section 9).

| Kind of item | Register | Rule |
|---|---|---|
| Inventory | stock | A quantity of a SKU (and lot) on the balance, counted as a quantity. May change kind. |
| Inventory in use | stock | Inventory handed over to an employee (REQ-679 hand over); it stays in the stock register as a quantity under the employee's Responsible slot. May change kind, from the employee's slot. |
| Inventory Object | stock | A valuable single item that stays on the balance, is counted one by one in the stock register and is its own record with its codes (D-065). It does not change kind by this document: it is already an individual stock record (open owner question, section 9). |
| Low-value asset | asset | An item written off from the balance but still tracked: one asset register record flagged off-balance. It may carry a quantity (review finding 5). Created by this document. |
| Fixed asset | asset | One asset register record per item, quantity 1. Created by this document. |

A change of kind takes a quantity of a SKU (and lot) out of the stock register and creates low-value or
fixed asset records. The reverse direction, a change between two asset kinds and a change of an intangible
asset are out of scope.

## 2. Plain tables

Two module-managed record types of the asset module (from C1): the **header** `kind_change` and the **line**
`kind_change_line` (names are a proposal). Tables are plain; nothing is stored as a blob. The line-to-header
reference `header_id` is a foreign key inside the pack; every master reference is a record id checked in code
(decision 0076 R6), not a foreign key. Field types come from the closed list `@field_types` of
`lib/letflow/entities/definition/validator.ex` (string, integer, decimal, boolean, date, datetime, enum, json,
localized_text). The number, state and issued time are not stored on the header: they are read from the
versioned document that `document_id` names, as for the stock documents (REQ-679 section 1.4).

Header `kind_change`:

| Field | Type | Req. | Master |
|---|---|---|---|
| `document_id` | string (id of the versioned document) | yes | none |
| `event_time` | datetime (ISO 8601 with offset, stored in UTC) | yes | none |
| `org_unit_id` | string (record id; the scope column, section 8) | yes | org_unit |
| `reason_text` | string | no | none |
| `note` | string | no | none |

Line `kind_change_line`:

| Field | Type | Req. | Master |
|---|---|---|---|
| `id` | string | yes | none |
| `header_id` | string (FK in pack) | yes | none |
| `line_no` | integer | yes | none |
| `catalog_item_id` (SKU) | string | yes | catalog_item |
| `catalog_uom_id` (unit) | string | yes | catalog_uom |
| `catalog_lot_id` (lot) | string | no; required when the item's tracking policy requires a lot (REQ-641) | catalog_lot |
| `quantity` | decimal, `decimal_strict: true` | yes, greater than zero | none |
| `stock_location_id` | string | yes | location_node |
| `stock_responsible_id` | string (employee holding the stock) | yes | org_employee |
| `target_kind` | enum `low_value`, `fixed` | yes | none |
| `asset_org_unit_id` | string | yes (default: header `org_unit_id`) | org_unit |
| `asset_location_id` | string | yes | location_node |
| `material_responsible_id` | string (materially responsible employee) | yes | org_employee |
| `actual_user_id` | string (actual user employee) | no | org_employee |
| `asset_card_id` | string (the card created by this line, set at posting) | no | asset card type (from C1) |

Every quantity is a decimal field with `decimal_strict: true`, as in REQ-679 criterion 3. A fixed-asset line
has quantity 1 and creates one asset card; a low-value line creates one asset card carrying the line's
quantity. No price or value field exists on this document (section 9, open question 1).

## 3. The two postings

Posting the document commits two postings in one transaction (0073 A2), one per register. The stock ledger id
is the fixed id of the stock register; the asset ledger id is the fixed id of the asset register (from C1);
the two ids differ.

| Posting | Cause | Sign rule | reason_required | Legs |
|---|---|---|---|---|
| Stock posting | `kind_change_out` (name from the stock registration, proposal) | negative | false | one negative leg per line |
| Asset posting | `kind_change_in` (name from C1, proposal) | positive | false | one positive leg per line |

Cause and sign rule come from the closed set of `lib/letflow/design/gh2657-wms-stock-ledger-core.md` section
14.3 (`positive`, `negative`, `zero_sum_by_slot_1`, `any`, and `reversal` used only by reversals). Slots are
named by name, never by `k1..k8` position.

Stock leg (negative quantity), per line:

| Slot | Filled from |
|---|---|
| OrgUnit | header `org_unit_id` |
| Location | line `stock_location_id` |
| Responsible | line `stock_responsible_id` |
| SKU | line `catalog_item_id` |
| Lot | line `catalog_lot_id` |
| `unit_ref` | line `catalog_uom_id` |

Asset leg (positive quantity), per line:

| Slot | Filled from |
|---|---|
| OrgUnit | line `asset_org_unit_id` |
| Location | line `asset_location_id` |
| MaterialResponsible | line `material_responsible_id` |
| ActualUser | line `actual_user_id` |
| Asset | the id of the asset card created by that line (`asset_card_id`) |
| `unit_ref` | line `catalog_uom_id` |

The quantity and the unit of the asset leg equal those of the stock leg of the same line.

Rules of 0073 A2 as they apply here: both postings carry the `document_type` and the `document_id` of this
document; they have different ledger ids; both are committed or neither; a posting whose `document_type` or
`document_id` differs or is empty is refused with `ledger_document_mismatch`, a second posting to the same
ledger id with `ledger_duplicate_ledger_in_transaction`, and a third posting with `ledger_too_many_postings`.
Each posting keeps its own counter row, gap-free `posting_seq`, digest chain and `ledger.posted` audit entry
(0073 A4).

## 4. One transaction

Posting the document is one transaction that creates the asset cards of all lines, commits the stock posting
and the asset posting, and marks the document posted; or it commits none of these.

* The locks of both postings are taken by the one lock step of 0073 A3 (the union of the balance keys of both
  postings sorted by `(ledger_id, k1..k8)`, then the counter rows by `ledger_id`), not in line order, so the
  order of the `module_writes` lines does not matter.
* The posting runs on a **user task** node whose `module_writes` carry exactly two posting lines, which the
  activation check of 0073 A2 allows (at most two, with different ledger ids). It never runs on a service task
  node (0073 D-L12; the SERVICE origin stays refused).
* The `event_time` is the document's event time, at most 96 hours back and 5 minutes ahead (0073 D-T).

## 5. Master checks (before the posting)

They run in the asset module's own write path, before the posting, because `declare/2` reads no master data
(0073 D-P). A failed check creates no asset card, posts nothing and leaves the document a draft.

| Check | Function (origin/main) | Applies to |
|---|---|---|
| SKU active | `Letflow.Modules.CatalogItems.active?/2` | every line |
| Unit valid for the SKU | `Letflow.Modules.CatalogItems.item_uom_valid?/3` | every line |
| Lot belongs to the SKU | `Letflow.Modules.CatalogItems.item_lot_valid?/3` | every line with a lot |
| Location active | `Letflow.Modules.Locations.active?/2` | stock location and asset location |
| Org unit active | `Letflow.Modules.Org.active?/2` | header unit and asset org unit |
| Org unit and location linked (D-065) | `Letflow.Modules.Locations.linked?/3` | stock side and asset side |
| Employee active | `Letflow.Modules.Org.active_employee?/2` | stock responsible, materially responsible, actual user (if given) |

Further module checks (not master reads): a fixed-asset line has quantity 1; the stock balance covers the
quantity (the ledger refuses a negative balance).

## 6. Life cycle and reversal

States: **draft, posted, reversed** (the versioned document also has issued and cancelled, as in REQ-679
section 9.1). A posted document never changes and is never deleted (REQ-679 criterion 7: documents fixed once
signed; D-062, D-061). The event time is at most 96 hours back and 5 minutes ahead (0073 D-T).

A posted change of kind is corrected only by ONE reversal transaction that carries the reversal of both
postings (0073 A4, same `document_type` and `document_id`, both or neither). A reversal of one of the two
postings alone is refused. The reversal does not delete the asset cards it created.

Open design questions for C1, with no answer of their own here: which state the cards take after a reversal;
whether a reversal is refused once an asset card has a later movement.

## 7. Process shape

One process definition `kind_change` in the asset module (from C1): draft, issue, then post on a user task
node as in section 4. The state is read from the versioned document and the posting marks, as for the stock
documents. No approval step is named (section 9, open question 4).

## 8. Access

* The header and line types declare the scope `{:column, "org_unit_id"}` (decision 0076 R7 row "Asset cards,
  receipt/transfer/count documents"; D-067). The line type carries a copy of the header's `org_unit_id`. When
  the stock side and the asset side name different org units, the column holds the header's `org_unit_id`,
  the unit that gives up the stock; whether the receiving unit sees the document (a masked other side) is an
  item for the scoped read of B6.
* The poster needs the `post` permission of the stock registration AND the `post` permission of the asset
  registration: each posting is authorized by its own registration. The reversal needs both `reverse`
  permissions. No role is named here; role grants are 0073 OQ-11 of slice L4 and its asset counterpart in C1.
* A scoped principal cannot post until slice L6 (0073 OQ-21).

## 9. Open owner questions

No answer is given here.

1. The value of the new asset card: price and value live on the receipt document or the asset (review finding
   4). Whether it is copied from the receipt line, typed, or left empty. Source: `architectures/assets.md`.
2. Whether an Inventory Object may change kind. Source: section 1 of this file.
3. Whether the reverse direction (asset back to stock) is needed.
4. Whether a change of kind needs an approval step (`architectures/assets.md` open question 6).
5. The rule table of section 1, to be confirmed at the phase C gate (D-063).
