# Government lists of stock and assets as saved reports

Status: specification, not built (REQ-735, GH #3857, assets phase E item E2). Docs only: no code, no
migration, no definition JSON, no module version, no saved report row, no seed, no test, no route, no screen.
Any later build (a definition change, a joined list, an export) is a later requirement written from this file
after the owner's gate of the phase it belongs to (D-063, D-085).

**The owner has not sent the link to the government forms** (`architectures/assets.md`, open question 5), so the
two column lists below are the six columns named in `assets.md` and are **provisional** until that link arrives.
The forms shape reports only, not the model (`assets.md`): no column of a form adds a field to any record type.

Sources: owner decisions D-061, D-062, D-063, D-067, D-085 and D-086 in `ai-dala-portfolio/DECISIONS.md`
(D-097 of 2026-11-05 lists "the stock government list" as later backlog; this file still specifies it, as the
entry asks); `ai-dala-portfolio/architectures/assets.md` (section "Reports and import", open question 5);
`letflow-team/project/assets-gap-analysis.md` (sections 3 and 6); decisions 0066
(`docs/migration/decisions/0066-generic-saved-views-over-records.md`, D1 to D4), 0078 (D2, D7) and 0079 (D2, D8)
in `docs/migration/decisions/`; the entries REQ-619, REQ-634, REQ-689 (with its file
`docs/assets/asset-register.md`, present on origin/main), REQ-704, REQ-714, REQ-728 and REQ-729 in
`docs/requirements.yaml`; and this entry, REQ-735 (drafted on the branch of spec PR #3858; at the time of writing
it is not yet on origin/main).

Marks used below: **proposal** = the business analyst's proposal for UAT, to be confirmed by the owner when the
form link arrives and at the gate of phase E. **UAT assumption** = an assumption to be confirmed by the process
owner.

## 1. What a saved report is today

- A saved report is a view of kind `report` over exactly one entity type: one filter, a summary part (a non-empty
  aggregates list and zero or more `group_by` clauses) and an optional detail part (columns and sort)
  (REQ-619, decision 0066 D2). A report body with a join key answers 422 `unknown_key` (REQ-619 criterion 2).
- The aggregate functions are `count`, `sum`, `avg`, `min` and `max` (`@aggregate_atoms` in
  `lib/letflow/entities/views/clauses.ex`). `sum` and `avg` take only integer and decimal fields
  (`check_aggregate_field_type/2` in `lib/letflow/entities/query/compiler.ex`).
- A filter, sort, `group_by` or aggregate field must be allowlisted, and only fields with `queried` true are
  allowlisted (`lib/letflow/entities/query/allowlist.ex`). Detail columns need only exist on the type
  (`check_columns/3`).
- The screen is the report builder of REQ-634 (`web/src/pages/entities/ReportBuilderPage.tsx`, route
  `entities/:entityType/reports`).
- Export of a report and joined reports are out of REQ-619's scope.

## 2. The two lists and their columns (provisional)

Stock list (five columns): SKU code, receipt date, current balance, price, value.
Asset list (six columns): asset code, receipt date, current balance, price, value, depreciation.

Facts on origin/main used in the table: the stock receipt header `stock_receipt` holds `received_on`, the real
receipt date (decision 0078 D7: printed on the government lists, never the event time); the line
`stock_receipt_line` holds `catalog_item_id`, `catalog_lot_id`, `quantity`, `unit_price` and `line_value`
(REQ-714 criterion 1). In `priv/modules/stock/entity_definitions/stock_receipt.json` and `stock_receipt_line.json`
`queried` is true only on `document_id` (header), `header_id` and `org_unit_id`. Price and value are never in
the ledger (`docs/assets/stock-workflow-documents.md` section 4, decision 0079 D2). A balance is a ledger row, not
a record; it is read through the stock balances route and its xlsx export (REQ-728), which has no price or value
column (decision 0079 D8). The asset card `assets_card` (`docs/assets/asset-register.md` section 3, REQ-689
criterion 4) carries `inventory_number`, `name`, `kind`, `org_unit_id`, `acquisition_date`, `acquisition_cost`,
`accumulated_depreciation`, `book_value` and `depreciation_as_of`, and no quantity: the quantity of an asset
lives only in the asset register (REQ-689 criterion 8). The card is specified only; no assets module exists on
origin/main.

| List | Column | Record type and field | Answer |
|---|---|---|---|
| Stock | SKU code | `stock_receipt_line.catalog_item_id` (a record id, not the code) | not reachable by the report builder: a report has no join to the SKU's code (REQ-619 criterion 2) |
| Stock | Receipt date | `stock_receipt.received_on` (header); the line holds `header_id` only | not reachable on a line row: no join from the line to the header |
| Stock | Current balance | no record field (a ledger balance row, REQ-728) | not reachable by the report builder: a balance is not a record |
| Stock | Price | `stock_receipt_line.unit_price` | reachable today as a detail column of a report over `stock_receipt_line`; not sortable, filterable or usable in a summary until a definition change sets `queried` true on it |
| Stock | Value | `stock_receipt_line.line_value` | as Price; reachable as a detail column, summable only after a definition change sets `queried` true |
| Asset | Asset code | `assets_card.inventory_number` | reachable by a saved report once the C1 card exists; sorting needs `queried` true (section 3) |
| Asset | Receipt date | `assets_card.acquisition_date` | reachable once the C1 card exists |
| Asset | Current balance | no record field (the quantity lives only in the asset register) | not reachable by the report builder |
| Asset | Price | `assets_card.acquisition_cost` (proposal) | reachable once the C1 card exists; summing needs `queried` true |
| Asset | Value | `assets_card.book_value` (proposal) | reachable once the C1 card exists; summing needs `queried` true |
| Asset | Depreciation | `assets_card.accumulated_depreciation` | reachable once the C1 card exists; summing needs `queried` true |

"Reachable once the C1 card exists" means: reachable after a named definition change, namely the build of the C1
card with the `queried` flags of section 3 (the card does not exist on origin/main). Which card field is the
form's "price" and "value" is the proposal above, a UAT assumption (section 7).

## 3. The asset list as one saved report

One saved report of kind `report` over `assets_card`, named **Asset list** (government list, provisional), in
business terms:

- Filter: none.
- Detail part: the columns `inventory_number`, `name`, `kind`, `org_unit_id`, `acquisition_date`,
  `acquisition_cost`, `accumulated_depreciation`, `book_value` and `depreciation_as_of`, sorted by
  `inventory_number` ascending.
- Summary part: grouped by `kind`, with `count` and `sum` of `acquisition_cost`, `accumulated_depreciation` and
  `book_value`.

Definition precondition, a requirement on the later build of the C1 card and not a change made by this item:
`queried` true on `inventory_number`, `kind`, `acquisition_cost`, `accumulated_depreciation` and `book_value`,
because a sort, `group_by` or `sum` field must be allowlisted (`allowlist.ex`) and `sum` takes only decimal or
integer fields (`compiler.ex`; the three money fields are decimal).

The list has **no current balance column**. A written-off card, whose quantity is 0 in the register, still
appears on it (UAT assumption, to be confirmed by the process owner). The organisation unit is shown as a record
id (section 6).

## 4. The stock list today

The report builder cannot produce the stock list of section 2 as one report, for three reasons: the SKU code
needs a join (a line holds a record id); the receipt date lives on the header, not the line; no balance is held in
any record. The nearest output today is two separate files:

1. the stock balances xlsx export of REQ-728: SKU, lot, location, quantity; no price or value (decision 0079 D8);
2. a report over `stock_receipt_line` with the detail columns `header_id`, `catalog_item_id`, `catalog_lot_id`,
   `quantity`, `unit_price` and `line_value`.

Putting price and value next to a current balance needs a rule for which price applies to a balance built from
several receipts. That is a money rule for the owner (section 7) and is not decided here.

## 5. Access

- A saved report shows the reader only the records and fields that the query and aggregate routes give that
  reader (decision 0066 D3). Asset cards and stock documents are scoped by org unit (D-067), so a scoped reader's
  list holds the rows of the reader's units only.
- The definition is shared tenant-wide with every caller who may read the type (decision 0066 D1, REQ-619
  criterion 5) and is written only by holders of `EntitiesViewsManage` (0066 D4).
- A definition holds no record value.

## 6. Gaps

What the government lists need that the report builder does not have. Each is a source and the later requirement
it would need; no answer is given here.

| Gap | Source | Later requirement needed |
|---|---|---|
| A list that joins a record with ledger balances (current balance on both lists) | REQ-619 (no joins, REQ-300 out of scope); REQ-728; REQ-689 criterion 8 | a balance-with-value read or a joined report |
| A list that shows a referenced record's code instead of its record id (SKU code on the stock list, org unit on the asset list) | REQ-619 criterion 2 | a join or a resolved-reference column |
| The receipt date of the header on a line row | `stock_receipt` / `stock_receipt_line` split | a join, or a copy of the date on the line |
| `queried` true on `unit_price` and `line_value` of `stock_receipt_line` | `allowlist.ex`; the two stock definition files | a definition change and a module version |
| A list as of a date | REQ-704, decision 0078 D2 (a report reads the current records) | a dated read |
| Export or printing of a report | REQ-619 out of scope; print templates (L-07); `asset-xlsx.md` (REQ-729) for the asset balances export | an export and the print templates |

## 7. Open owner questions

No answers are given here. Each has its source.

1. The link to the government forms and which form comes first (`assets.md` open question 5). The column lists
   are provisional until it arrives.
2. Which card field is the form's "price" and "value". This file proposes `acquisition_cost` and `book_value`
   (UAT assumption).
3. The price of a stock balance built from several receipts or opening lines (last receipt, average, by lot): a
   money rule.
4. The currency of the money columns (`docs/assets/stock-workflow-documents.md` section 4; REQ-689 criterion 10;
   D-097 says one currency per tenant, KZT by default).
5. Whether a list is made per legal entity (several BIN in one tenant, D-062), since neither the card nor the
   receipt line holds a legal entity.
6. Whether written-off assets stay on the asset list (section 3).

## 8. Out of scope

The printed forms and their print templates in Russian and Kazakh (L-07, other phase E items), label printing,
export of a report to xlsx or PDF, joined reports, a balance-with-value read of the stock or asset module, any
change of a definition's `queried` flags, the count and hand-over paperwork (decision 0079, phases B and C),
depreciation calculation (not in the first version, D-061) and period close (D-062).
