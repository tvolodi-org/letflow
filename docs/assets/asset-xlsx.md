# Asset xlsx: import and export of asset cards, depreciation included

Status: specification (REQ-729, GH #3792, assets phase C item C4). The import (sections 1 to 5) is built by REQ-762
(GH #3899, assets module 0.4.0): `Letflow.Modules.Assets.Import.import_card/3`, registered in the manifest key
`:import_functions`. It adds one reason not listed in section 4: `card_inactive` (the existing card is retired). The
reasons `asset_kind_locked` and `asset_inventory_number_locked` are mapped from `Cards` `:kind_locked` and
`:inventory_number_locked` (T-1490, `CardLocks`). The export reads are a later requirement.

Sources: owner decisions D-061 (depreciation is an information field, imported or typed, not calculated), D-062
(xlsx in the first version), D-063 (a manual gate ends each phase) and D-085 (phase C specifications are written
before gate B) in `ai-dala-portfolio/DECISIONS.md`; `ai-dala-portfolio/architectures/assets.md` (table under "The
model", section "Reports and import"); `letflow-team/project/assets-gap-analysis.md` (sections 3 and 6); decisions
0073 (D-T, D-L12), 0077 (D1 to D8) and 0079 (D5, D8, Q4) in `docs/migration/decisions/`; the requirement of item
C1, REQ-689, with its file `docs/assets/asset-register.md` (present on origin/main when this file was written);
and this entry, REQ-729 in `docs/requirements.yaml`.

Marks used below: **proposal** = the business analyst's proposal for UAT, to be confirmed by the owner at the gate
of phase C. **UAT assumption** = an assumption to be confirmed by the process owner. This file decides only the
shape of the asset files: columns, row rules and what each export holds. Money rules and the open points of
section 8 are not decided here.

## 1. Import path

Asset cards are imported only through the managed import path of decision 0077 D5:

1. The assets module lists `assets_card` in its manifest key `:import_functions`
   (`Letflow.Modules.Catalog.import_function/2` resolves it, `call_import_function/5` calls it).
2. The route is the existing `POST /entities/records/assets_card/import` in upsert mode; any other mode answers
   422 and writes nothing (0077 D5 point 2). No route is added.
3. The file is read by the reader of 0077 D1 (`xlsx_reader`). Limits and mapping of 0077 D1 to D3 are unchanged:
   first worksheet only, at most 200 data rows, request body 2_097_152 bytes, uncompressed 26_214_400 bytes,
   DOCTYPE refused; cells are mapped by `CsvImport.convert_row/5`.
4. Rows are upserted by external ref only (`external_ref_system` plus `external_ref_id`). The dry run of 0077 D7
   is offered.
5. The tenant is taken only from the authenticated caller (0077 D4); no cell or header names a tenant.
6. **Who may run it.** `import_scope_check/6` in `lib/letflow/routers/entities/record_import.ex` offers upsert mode
   to no scoped caller (any mode but `:create` is refused for a caller whose scope is not `:all`). So a scoped
   caller cannot run this import: only a tenant-wide caller imports asset cards.
7. **How it writes.** The import function writes every card only through the assets module's own card write
   functions, calls no `Records`, holds no Owner and puts no cell text into an error, as
   `Letflow.Modules.Org.Import` does. The card rules and the audit entry of a card write therefore hold for
   imported rows.

## 2. Template columns

The header row of an asset import file is one column per field of the `assets_card` field table of
`docs/assets/asset-register.md` section 3, in that table's order, as found at the time of writing:

| # | Column | Type | Note |
|---|---|---|---|
| 1 | inventory_number | string | required; unique per tenant (D-097) |
| 2 | name | string | required |
| 3 | kind | enum | required; `fixed`, `low_value` or `intangible` |
| 4 | org_unit_id | reference | required (the import is the one channel that still writes the card's unit, T-1488); external id of an org_unit, or its record id as the card export writes it (section 3 rule 1) |
| 5 | acquisition_date | date | optional; the real receipt date |
| 6 | currency | string | optional; empty means the tenant currency |
| 7 | acquisition_cost | decimal | optional; `decimal_strict` |
| 8 | accumulated_depreciation | decimal | optional; `decimal_strict` |
| 9 | book_value | decimal | optional; `decimal_strict` |
| 10 | depreciation_as_of | date | optional |
| 11 | valid_until | date | optional; only for kind `intangible` |
| 12 | external_ref_system | string | the row's external ref system |
| 13 | external_ref_id | string | the row's external ref id |
| 14 | depreciation_method | string | optional; a method code `straight_line`, `reducing_balance` or `units_of_production` (D-134, T-1871); any other value is refused with `field_invalid`, header `depreciation_method`, unless it equals the value already stored on the card (so a legacy text re-imports unchanged); information only (T-1530; added at the end so numbers 1..13 stay) |
| 15 | depreciation_rate | decimal | optional; `decimal_strict`; percent per year as typed, information only (T-1530) |

The row's external ref is also written into the card's own `external_ref_system` and `external_ref_id` fields (as
0077 D5 point 4 says of the catalog module). If the C1 field table changes before the module is built, this
template follows it, in its order.

The file has no location, materially responsible person, actual user or quantity column, because those values
live only in the asset register (REQ-689 criterion 4; `asset-register.md` section 3). Any other header is the
whole-file refusal `xlsx_unknown_header` of 0077 D3, as are the other whole-file refusals of D3 (`xlsx_unreadable`,
`xlsx_too_large`, `xlsx_header_missing`, `xlsx_duplicate_header`, `xlsx_external_ref_pair`).

## 3. Row rules

One rule per line. Reason codes introduced by this file are constants and carry no cell text; those marked
(0077) exist already.

1. `org_unit_id` holds the external id of an org_unit under the same external-ref system as the row. It is
   resolved in the same tenant to the record id of the live target. A missing or deleted target is
   `reference_not_found`, an inactive one `reference_inactive`, both with the constant header `org_unit_id`
   (0077 D5 point 4).
2. A `kind` cell outside `fixed`, `low_value` and `intangible` is refused: `asset_kind_invalid`.
3. A `valid_until` cell on a row whose kind is not `intangible` is refused: `asset_valid_until_not_allowed`.
4. A row that changes the kind of a card that already has a posted document is refused: `asset_kind_locked`
   (REQ-689 criterion 4); one that changes its inventory number (a card matched by external reference) is refused:
   `asset_inventory_number_locked`.
5. Each money cell follows the `decimal_strict` grammar of `CsvImport` (`@decimal_strict`); any other text is the
   row error `csv_invalid_decimal` (0077 D3).
6. A `currency` cell that differs from the tenant currency is refused: `asset_currency_mismatch`
   (`asset-register.md` section 6, D-097).
7. A missing required cell (`inventory_number`, `name`, `kind`, `org_unit_id`) is refused: `asset_field_required`
   with the constant header of the field.
8. An `inventory_number` already used by another card of the tenant is refused: `asset_inventory_number_taken`.
9. The row is the full desired state of the importable fields, so an absent optional cell clears that field, as in
   `Letflow.Modules.Org.Import`.
10. A row equal to the stored card is `unchanged` and writes no event (0077 D6); a new card is `created`, a changed
    one `updated` (`Letflow.Entities.ManagedImport`).
11. A refused row changes nothing; the other rows of the file are still processed and reported per row, as in
    the managed import of 0077 D5 point 3. The screen "Import data" asks for `atomic=true` (T-1556): the whole file runs in
    one transaction and is committed only when no row is refused; otherwise nothing is written, the answer carries
    `"applied": false` and the clerk fixes the refused rows and uploads the whole file again (rows are matched by external
    id, so nothing is duplicated). Without `atomic` the API keeps the partial-success behaviour above.
    A refused row names its row (`line`), its column (`header`, for a cell or field refusal and for the constant reasons
    that have one: `inventory_number`, `kind`, `currency`, `valid_until`, `quantity`, `org_unit_id`, `external_ref_id`)
    and a reason the screen shows in Russian, Kazakh and English. A wrong xlsx header answers 422 with the unchanged
    detail string and a `headers` member that lists up to five offending header names.
12. A target of a reference must come earlier in the file or be stored already (0077 D5 point 4).

## 4. No placement, no posting

An asset import writes asset cards only. It never posts to the asset ledger, never creates a balance row and
never writes a document. An imported card therefore has quantity 0 in the register until a commission document of
item C2 (`docs/assets/asset-workflow-documents.md`) puts it there (REQ-689 criterion 8, REQ-690). Two reasons:

- The ledger refuses an event time more than 96 hours back (decision 0073 D-T). This is why the real acquisition
  date is the card field `acquisition_date`, and not the event time of a posting.
- A posting from a service task is refused until slice L5 (decision 0073 D-L12), and an import function runs as
  a service.

## 5. Depreciation by import

`acquisition_cost`, `accumulated_depreciation`, `book_value` and `depreciation_as_of` are set by the import or
typed, never calculated (D-061, REQ-689 criterion 7). A re-import of a file with new depreciation values updates
the card and answers that row `updated`; in the audit trail it is a card update, not a posting.

**UAT assumption**: the import checks no sign of a money cell and no relation between the money fields (for
example that `book_value` equals `acquisition_cost` minus `accumulated_depreciation`). A wrong figure in a file
is therefore stored as typed.

## 5a. Opening lines (G6, assets 0.11.0, decision 0083 D7)

`POST /api/v1/entities/records/assets_opening_line/import?upsert_by=external_ref` fills a DRAFT opening document from an
xlsx file by the managed import path (the import function `import_opening_line` of the assets manifest,
`Letflow.Modules.Assets.Documents.OpeningImport`). The header is created first (`POST /documents`) with its own external
reference pair; cards are imported first (section 1).

- Columns (the entity field names): `header_id`, `asset_id`, `location_id`, `material_responsible_id`, `actual_user_id`,
  `quantity`, `external_ref_system`, `external_ref_id`; optional `org_unit_id`. Every reference cell is an EXTERNAL id under
  the row's own `external_ref_system`; `location_id` and `actual_user_id` may be empty. A column that is not a field of
  the line (for example `price`) is refused by the core reader (`xlsx_unknown_header`).
- Upsert by the row's pair within the document: a new pair creates a line (next `line_no`), an equal row is `unchanged`,
  a changed row updates the line and keeps its `line_no`.
- Row reasons (constant, no cell text): `reference_not_found` / `reference_inactive` with the field, `document_not_draft`,
  `org_unit_mismatch`, `lines_count` (the 101st line of a document), `quantity_invalid` (zero or negative; a non-number is
  the core's `csv_invalid_decimal`), `line_invalid`.
- At most 200 data rows per file; at most 100 lines per document. Draft only: the import never issues or posts, and it does
  not run the checks of the opening (duplicate asset, location rules, card linked, already in the register); the check
  route `POST /documents/:id/check` shows them.
- Who: a tenant-wide caller with the import permission (as for cards); a scoped caller cannot run upsert mode and the
  STOREKEEPER import is for module `stock` only.

## 6. Card export

The asset cards are exported through the existing record export `POST /entities/records/assets_card/export?format=xlsx`
(0077 D8, `Letflow.Entities.XlsxExport.build/3`). No route and no dependency is added.

- Sheet `records` holds the card fields in definition order, as row 1; sheet `export` holds `entity_type`,
  `exported_at` and `next_cursor` (0077 D8).
- The handler `run_export/5` in `lib/letflow/routers/entities.ex` has no branch refusing a module-managed type (a
  read, served for every visible type). This is checked again when the export is built.
- The export applies the field redaction and the scope filter of the export route, so a scoped reader gets only
  the cards of its units (REQ-689 criterion 9).
- `org_unit_id` is exported as the stored record id. The card import accepts it (T-1866): the external id is tried
  first, then a record id of a live org_unit of the same tenant, so export, edit, import round-trips. An unknown or
  other-tenant id is `reference_not_found`.

## 7. Register balances export

A second xlsx export, of the asset register balances:

- One row per balance key: the slot values `asset`, `org_unit`, `location`, `material_responsible` and
  `actual_user`, named by slot name, then the quantity and the unit.
- A second sheet holds the report fields of note section 8.4 of
  `lib/letflow/design/gh2657-wms-stock-ledger-core.md` (`basis`, `cutoff_seq`, `as_of`, `timezone`, `filters`,
  `ledger_seq`), in the shape of decision 0079 D8.
- A file holds only the rows the caller's read of the asset ledger answers, never more.
- No money column: money is never in the register (REQ-689 criterion 7).
- Its route is `GET /api/v1/modules/assets/balances?format=xlsx` (REQ-763): file `asset-balances.xlsx`, sheets
  `balances` and `report`, one page per file (`next_cursor` on the report sheet). Like the stock exports, it is not
  promised to re-import.

## 8. Open owner questions

No answer is given here to any of them.

1. (Answered by decision 0083 and built in G6, section 5a.) How old assets are placed into the register in bulk: by an xlsx import of commission lines into draft
   commission documents, or by an asset opening document reusing decision 0079 D1 to D6. Source: decision 0079
   Q4. Superseded (T-1486, REQ-782): a commission cannot carry an old date (0073 D-T), so old assets are placed by
   the asset opening document of decision 0083 (proposed, to be accepted at the gate of phase C): the cards come in
   by this import first, then opening lines place them, typed or imported. The earlier proposal of commission
   documents typed one by one is withdrawn.
2. Whether one asset list file that joins card and register values (the government list of `assets.md`) is an
   export of this item or a report of phase E. Source: `assets.md`, section "Reports and import".
3. Whether 200 rows per file (0077 D2, a UAT assumption) is enough for an asset list. Source: decision 0077 D2.
4. The currency of the money fields. Source: REQ-689 criterion 10; D-097 decides one currency per tenant, KZT by
   default, and only the reading of `asset-register.md` section 6 is left to confirm.
5. Whether an exported card file should re-import with external ids instead of record ids. Source: section 6
   above and decision 0079 D8.

## 9. Out of scope

The asset card and the register registration themselves (item C1, REQ-689); the asset documents (item C2,
REQ-690); the change of kind (item C3, REQ-691); placing old assets into the register by a file (section 8,
question 1); import of historical movements; the import screen for asset files (the phase A import screen is
REQ-675); printed forms and government lists that join card and register values (phase E); depreciation
calculation (not in the first version, D-061); period close (D-062).
