# Qoimeks pilot migration rehearsal (prepared, not started)

Scope: steps 1-3 of the plan in T-1569 section 5 (extract, convert, load into a QA copy, compare counts). This is
**preparation**: nothing here is run by the product, and nothing here may touch production or a customer's live data.
Work on a **copy** of the Qoimeks data and a **QA** tenant only. Output files hold customer data: keep them outside
the repository checkout (the converter refuses an `--out` inside it) and never commit them.

## Does the stock module accept the same files?

Not the asset files of `docs/assets/asset-xlsx.md`. Stock has no card import; it shares the master data of the core
modules and has one import of its own (all through
`POST /api/v1/entities/records/<type>/import?upsert_by=external_ref`, 200 data rows per file, `dry_run` and `atomic` offered):

| Order | Entity type | Importer | Columns written by the converter |
|---|---|---|---|
| 1 | `location_node` | `Locations.Import` | `code, name, node_kind, parent_id, external_ref_system, external_ref_id` |
| 2 | `catalog_uom` | `CatalogItems.Import` | `code, name, active, external_ref_system, external_ref_id` |
| 3 | `catalog_item` | `CatalogItems.Import` | `code, name, base_uom_id, kind, active, external_ref_system, external_ref_id` |
| 4 | `code_tag` | `Codes.Import` | `value, kind, external_ref_system, external_ref_id` |
| 5 | `code_assignment` | `Codes.ImportAssignment` | `code_id, target_type, target_id, external_ref_system, external_ref_id` |
| 6 | `stock_opening_line` | `Stock.Documents.OpeningImport` | `header_id, org_unit_id, location_id, responsible_id, catalog_item_id, catalog_uom_id, quantity, received_on, external_ref_system, external_ref_id` |

The converted files are pushed through these real routes by `test/letflow/modules/stock/qoimeks_files_test.exs`.
Facts that shape the procedure: every reference cell is an **external id** under the row's own system; `parent_id`
must name a location earlier in the file; quantity must be non-zero; positive and negative lines never share one
opening document. The converter writes at most 100 lines per opening document (its own conservative chunk size,
below the platform limit), so each lines file has its own header (`QOI-HDR-NN`); an opening header cannot be created
empty, so it is created together with its first real balance (below).

## Steps

1. **Extract** from the frozen copy of the Qoimeks database three required CSV files in a directory outside the repository:
   `locations.csv` (`loc_code, loc_name`, optional `loc_parent`; omit it for a flat list), `items.csv`
   (`sku, sku_name, unit`, optional `home_loc` the usual place as a `loc_code`, `alt_loc` the second place and `barcode` the SKU's barcode
   from Qoimeks `Штрихкод`; a blank barcode is no code), and `balances.csv`
   (`sku, loc, qty`, optional `as_of`). The optional
   `codes.csv` holds the active rows of the Qoimeks codes table:
   `object_type` (`sku` or `location`), `object_code` (the SKU or place code), `code_type` (`ean13`, `ean8`, `code128`,
   `qr` or `manual`) and `code`. The converter works without it. The Qoimeks schema is not in this repository: if its
   column names differ, write a `map.json` and pass `--mapping`. The old flat form
   `{"<extract column>": "<neutral name>"}` applies to every file. When the same extract column has different meanings,
   use a top-level object keyed `locations`, `items`, `balances` and `codes`, each holding its own flat column object;
   omitted files keep their neutral names. Comma or semicolon delimiters and a BOM are read.
2. **Convert** (no network, no database):
   `python3 -I scripts/pilot/qoimeks_convert.py convert --in IN --out OUT --system qoimeks-rehearsal --org-unit-ext U --responsible-ext E --received-on YYYY-MM-DD`.
   `U` and `E` are the external ids of the org unit and the responsible employee created in the QA tenant (Qoimeks has no
   such notion). Read `OUT/report.txt` (row numbers and constant reasons, no cell text): exit 3 means rows were dropped;
   decide with the customer's contact, then fix the extract or pass `--allow-drops`. A blank location or item name is
   still dropped as `missing_name` by default, with the usual dependent-row drops. Only when the row's code is an
   acceptable display name, pass the explicit `--blank-name-fallback code` option. The report then says
   `blank names replaced by code: n` and lists each replacement by file and row number, without cell text;
   `manifest.json` records `blank_name_fallback` as `code`, or `null` when the option is off. Zero balances are listed
   separately under `skipped:` as `quantity_zero`; they are not drops and do not cause exit 3. Negative balances are
   kept with their exact sign: positive opening files come first, followed by files containing only negative lines
   (REQ-837).
   The usual place goes into `03-items-NN.xlsx` as the column `default_location_id` (G3, one place per item; an item
   whose place names no location is dropped as `unknown_default_location`). The second place is not imported:
   `report.txt` says how many kept items had one ("items with a second place, not imported (G3)"), and the snapshot
   key `items_with_default_location` is compared in step 7.
   Outputs: `01-locations-NN.xlsx`, `02-uoms.xlsx`, `03-items-NN.xlsx`, `06-codes-NN.xlsx`,
   `07-code-assignments-NN.xlsx`, `04-opening-lines-NN.xlsx`, `manifest.json`, `report.txt`, `expected_counts.txt`.
   The two code file types are written only when at least one code survives; every barcode and `codes.csv` row that
   survives produces one row in each. `qr` stays kind `qr`; all other code types become `barcode`. A repeated code for
   the same object is kept once, while the first object keeps a code offered again for another object.
3. **Upload masters and code files** in the manifest order (locations, uoms, items, item places, codes, assignments)
   with `dry_run=true` first, then `atomic=true`. Upload `06-codes-NN.xlsx` and `07-code-assignments-NN.xlsx` after any
   `05-item-places-NN.xlsx` files (after the item files when no 05 files were written), and before the opening lines.
   Save each response JSON as `RDIR/<file name without .xlsx>.json`.
4. **Headers**: `python3 -I scripts/pilot/qoimeks_convert.py headers --out OUT --responses RDIR --org-unit-id UUID --responsible-id UUID`
   writes `OUT/headers/QOI-HDR-NN.json`; send each body to `POST /api/v1/modules/stock/documents` with an
   `Idempotency-Key` header, so a scripted retry cannot create a duplicate opening header (one draft opening per
   header, created with its first balance). `POST /api/v1/documents` answers 403. Create the headers of the
   **positive** files now; the header of each file with negative lines waits until the setting of step 5 is on.
5. **Allow negative opening balances** before loading any lines. A tenant administrator with the
   `:LedgerSettingsManage` permission calls `PUT /api/v1/ledger-settings/stock` on the rehearsal tenant with exactly
   `{"allow_negative": true, "reason": "Qoimeks rehearsal: load negative opening balances"}`. Keep the reason in the
   request; the route requires it and audits the change. This switch is QA-only and does not change another tenant.
   Only now create the headers of the negative lines files (step 4, same route and `Idempotency-Key`); before the
   switch such a header is refused 422 `quantity_invalid`. Order: positive headers, switch on, negative headers.
6. **Upload the lines files** (`dry_run=true`, then `atomic=true`). Expected per file: row 1 `unchanged` (or `updated`), the others `created`, nothing refused.
   Opening documents are **drafts until posted**. The `stock_opening` approval's `four_eyes` defaults to `false` in
   a new tenant (owner decision D-165), so the issuer may approve their own document and the completion posts it.
   A tenant created before D-165 has the rule ON by default: the issuer cannot approve their own document and the
   completion answers 403 `separation_of_duties`. For such a one-admin tenant, before issuing and approving the
   documents call `PUT /api/v1/approval-rules/stock_opening/approve` with
   `{"four_eyes": false, "reason": "one-person Qoimeks rehearsal company"}` as in `docs/runbooks/pilot-rollout.md`
   step 6. After the lines are loaded, call `POST /api/v1/modules/stock/documents/<id>/issue` with an
   `Idempotency-Key` header for each document. This starts the `stock_opening` approval and creates its `approve`
   task. Complete that task through `POST /api/v1/tasks/<task id>/complete` with `{}`; completing the approval posts
   the document. `POST /api/v1/modules/stock/documents/:id/post` is only a retry route: before issue it answers 409
   `document_not_issued`, and while approval is pending it answers 409 `posting_pending`. Process the positive documents first
   and the negative documents last. Balances exist only after posting, so the read-back below and
   the quantity compare of step 8 work only after every document is posted.
   After the last file, a user with `StockRead` calls `GET /api/v1/modules/stock/balances` and checks every negative
   `(sku, loc)` key from `IN/balances.csv`: its quantity equals the extract exactly, including `-7` in the synthetic
   fixture. A skipped zero row has no opening line; its absent balance key reads as zero.
7. **Compare counts**: take `scripts/demo/demo_counts.sh snapshot > after.txt` (an operator without database access takes the record counts from the record exports and the stock document list instead) and run
   `scripts/pilot/qoimeks_compare.sh OUT/expected_counts.txt after.txt TENANT_SLUG`. Exit 0 means equal, 1 prints
   `DIFF key expected actual`, 2 is bad input (wrong slug, empty file). The QA copy tenant must be empty before the rehearsal.
   For a scripted run, take the credentials from the env file of the QA actor in the team root; never print it.

8. **Compare quantities (RH-7)**: `GET /api/v1/modules/stock/balances` is cursor-paged and its xlsx export contains only the first page
   (50 rows), never the whole balance list (the synthetic run had 13 pages for 603 rows, the real Client 1 run 3 pages for 589 rows).
   For the full comparison read every page and let the tool merge them: save the JSON response of
   `GET /api/v1/modules/stock/balances` as `PAGES/page-001.json`, then request `cursor=<next_cursor>` with the same filters and save each
   following page as `page-002.json`, `page-003.json`, ... until `next_cursor` is null. Run
   `python3 -I scripts/pilot/qoimeks_balances_compare.py --json-pages PAGES --csv IN/balances.csv --items IN/items.csv --locations IN/locations.csv`.
   The tool refuses an incomplete or gapped page sequence. For a one-page export only, `--xlsx stock-balances.xlsx` remains available.
   It prints one `DIFF` line per item and place that differs (with names), `ROWS` and one sha256 `HASH` per side over the sorted
   (item, place, quantity) list, and `RESULT`. Exit 0 means no difference and equal hashes, 1 differences, 2 bad input.
   Rows with quantity zero or below are left out on both sides (counted in `LEFT_OUT`); `--keep-nonpositive` compares them too.
   The negative-key read-back in step 6 is required even when this comparison leaves those rows out.

9. **Compare masters (REQ-881)**: save the Letflow records export (POST `/api/v1/entities/records/<type>/export`, format `json`) for each of `location_node`, `catalog_uom` and `catalog_item` as one or more JSON files in a directory `EXPDIR` (file names `<type>-<anything>.json`). Then run
   `python3 -I scripts/pilot/qoimeks_masters_compare.py --locations IN/locations.csv --items IN/items.csv --export-dir EXPDIR`.
   It prints one `DIFF` line per code that differs or is on one side only, `ROWS` and one sha256 `HASH` per side over the sorted (code, name) list for each of the three tables, and `RESULT` per table then overall. Exit 0 means all three tables are equal, 1 differences, 2 bad input. Export records with `deleted: true` are excluded.

10. **Write freeze (do it before step 1)**: the Qoimeks team switches on the Qoimeks `MAINTENANCE_MODE` (writes answer 503)
    before the extract and switches it off after the last check; write down the time it was on (about 40 s was enough
    for Client 1). Letflow does not switch it.
11. **ANALYZE (after the opening documents are posted)**: infra runs one `ANALYZE;` statement on the Letflow database through
    the same `PSQL` command line that `scripts/demo/demo_counts.sh` uses. It refreshes planner statistics only and changes no row.
12. **Rollback**: lift the Qoimeks write freeze (step 10). The Qoimeks data was never changed, and the phones still hold the
    Qoimeks address and token. The Letflow company is kept, not deleted. For anything entered in Letflow after the switch, take
    the stock movements export (`stock-movements.xlsx`) and enter it in Qoimeks by hand.

Repeating: re-upload the master files, the code files and the lines files (steps 3 and 6) with the same files; every
row, including every `code_tag` and `code_assignment` row, is `unchanged` only before the opening documents are
posted. After posting, lines files are refused `document_not_draft` and nothing is written.
Do NOT repeat steps 4 or 5: an opening header pair that exists is refused (`external_ref_taken`, HTTP 409), and the
negative-balance setting is already on. Reuse the existing headers and skip their creation. Balance references are
`BAL:<len(sku)>:<sku>:<loc>`, so keys containing `:` stay distinct.

## Move rules (Qoimeks inventory §8.10)

The move rules of Qoimeks Client 1 and where Letflow meets them. State: built, this section, or planned with its requirement id.

| Rule | How Letflow meets it | State |
|---|---|---|
| Copy | The runbook works on a copy; the source is untouched (intro, step 1) | built |
| One transaction | One transaction per file (`atomic=true`, `check_atomic` in `lib/letflow/routers/entities/record_import.ex`, steps 3 and 6) on a company that is empty before the load (step 7). The whole load is not one transaction: it is several files and posting tasks | built |
| Counts and hashes per table | Record counts (step 7, `scripts/pilot/qoimeks_compare.sh`), the quantity hash (step 8, `scripts/pilot/qoimeks_balances_compare.py`), the master data hash per table (step 9, `scripts/pilot/qoimeks_masters_compare.py`) | built |
| Current balances equal | Negative-key read-back (step 6) and `scripts/pilot/qoimeks_balances_compare.py` (step 8) | built |
| Check-only run first | `dry_run=true` before `atomic=true` (steps 3 and 6) | built |
| Short write freeze | Step 10, the Qoimeks `MAINTENANCE_MODE`, switched by the Qoimeks team | this section |
| ANALYZE after the load | Step 11, one `ANALYZE;` through `PSQL` after the opening documents are posted | this section |
| Rollback | Step 12, lift the Qoimeks freeze; the Letflow company is kept | this section |
| Outside working hours | The operator schedules the move outside Client 1's working hours | this section |
| No real data leaves production | Work on a copy and a QA company only (D-050); output files stay outside the repository | this section |
| Old copy kept 30 days | The Qoimeks copy and its extract are kept 30 days after the move | this section |
| Own User-Agent | A scripted client behind Cloudflare sets its own User-Agent header (inventory item 9) | this section |

## Minimum master data by API

The calls a fresh QA company needs, in order. Every module write body carries an `idempotency_key` (a uuid) or is refused with
`field_invalid`.

1. Legal entity: `POST /api/v1/modules/org/legal-entities` with `code`, `name`, `bin`.
2. Site: `POST /api/v1/modules/org/sites` with `code`, `name`, `legal_entity_id`.
3. Org unit: `POST /api/v1/modules/org/units`.
4. Employee: `POST /api/v1/modules/org/employees`; the name field is `full_name`.
5. Location: the record import of `location_node` (step 3).
6. Location link: `POST /api/v1/modules/locations/links` with `org_unit_id` and `location_id`. A location not linked to the
   org unit makes the opening line refused as `not_linked`.
7. Unit and item: module-managed, so a plain record create answers 403 `entity_type_managed`. They come in through the
   record import with `upsert_by=external_ref` (step 3), not a record create.
8. Opening document: step 4 and step 5. A line quantity is sent as a text (`"10"`); a JSON number is refused `quantity_invalid`.

## Synthetic QA dataset (qoimeks-qa rehearsal)

`scripts/pilot/qoimeks_gen.py` generates a fictitious Qoimeks-shaped dataset for the
`qoimeks-qa` dedicated QA company (D-050: no real client data). Run it with an `--out`
directory **outside** the repository:

```
python3 -I scripts/pilot/qoimeks_gen.py --out /tmp/qoimeks-qa-input
```

This writes `locations.csv` (134 rack locations plus a warehouse and zones, 142 nodes
total), `items.csv` (666 SKUs, unit `pcs`, quantities up to three decimal places) and
`balances.csv` (600 positive rows, 3 negative opening rows, 3 zero rows the converter
skips and 4 comma-decimal rows it drops — to exercise the converter's G4 and G8 rules). The seed
is fixed (`--seed 42`) so each run produces identical files. Pass the directory as
`--in` to `qoimeks_convert.py convert` with `--allow-drops` to proceed through the
bad rows and verify all 603 non-zero, valid balances are accepted.

With `--with-places` (off by default; the default files are unchanged) `items.csv` also carries
`home_loc` (the usual place, every 3rd item) and `alt_loc` (a second place, every 9th item), and every
25th item gets an additional lettered code (Latin prefixes such as `AB0025` and Cyrillic ones such as `КС0075`)
in a new `codes.csv` (`object_type` `sku`, `code_type` `manual`). The item code stays the digits-only one in
`items.csv` and `balances.csv`, so the importer sees the same items, not new ones. The option draws from its own random
stream, so locations and the placement of balances are the same with and without it.

`--voice-demo` (off by default; combines with `--with-places`) appends the small fixed demo catalog the
voice scenarios use: 12 items with lettered codes and Russian names (`BLT-M8-40` Болт М8х40, `BLT-M10-60`,
`NUT-M8`, `NUT-M10` Гайка, `WSH-8` Шайба плоская 8, `SCR-4-40` Саморез in kg, `PNT-WH-10` and `PNT-GR-3`
Краска, `CBL-3x2.5` and `CBL-3x1.5` Кабель in m, `GLV-L` Перчатки in pairs, `TAPE-48` Скотч) and 8 places
under the warehouse root (`A-01`, `A-02`, `A-03`, `B-01`, `B-02`, `C-01`, `RAMP` and the zone-coded `LA3`
named «Слева A 3»). `C-02` and `D-03` are left out on purpose. Usual places: `PNT-WH-10` -> `C-01`,
`GLV-L` -> `A-01`. `items.csv` then has the `home_loc`/`alt_loc` columns; no balances are added.

## Deliberately not here

Tenant and realm creation, users, the cut-over and the read-only switch (steps 4-6 of T-1569 section 5), the
ledger-side count comparison (a manual follow-up on the QA copy), lots, prices, movement history, and every owner
decision still open in T-1569. The converter is not wired into the product; no route or flag runs it.
