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
| 4 | `stock_opening_line` | `Stock.Documents.OpeningImport` | `header_id, org_unit_id, location_id, responsible_id, catalog_item_id, catalog_uom_id, quantity, received_on, external_ref_system, external_ref_id` |

The converted files are pushed through these real routes by `test/letflow/modules/stock/qoimeks_files_test.exs`.
Facts that shape the procedure: every reference cell is an **external id** under the row's own system; `parent_id`
must name a location earlier in the file; quantity must be above 0; the converter writes at most 100 lines per opening document (its own conservative chunk size, below the platform limit), so
each lines file has its own header (`QOI-HDR-NN`); an opening header cannot be created empty, so it is created
together with its first real balance (below).

## Steps

1. **Extract** from the frozen copy of the Qoimeks database three CSV files in a directory outside the repository:
   `locations.csv` (`loc_code, loc_name, loc_parent`), `items.csv` (`sku, sku_name, unit`), `balances.csv`
   (`sku, loc, qty`, optional `as_of`). The Qoimeks schema is not in this repository: if its column names differ, write a
   `map.json` `{"<extract column>": "<neutral name>"}` and pass `--mapping`. Comma or semicolon delimiters and a BOM are read.
2. **Convert** (no network, no database):
   `python3 -I scripts/pilot/qoimeks_convert.py convert --in IN --out OUT --system qoimeks-rehearsal --org-unit-ext U --responsible-ext E --received-on YYYY-MM-DD`.
   `U` and `E` are the external ids of the org unit and the responsible employee created in the QA tenant (Qoimeks has no
   such notion). Read `OUT/report.txt` (row numbers and constant reasons, no cell text): exit 3 means rows were dropped;
   decide with the customer's contact, then fix the extract or pass `--allow-drops`.
   Outputs: `01-locations-NN.xlsx`, `02-uoms.xlsx`, `03-items-NN.xlsx`, `04-opening-lines-NN.xlsx`, `manifest.json`,
   `report.txt`, `expected_counts.txt`.
3. **Upload masters** in the manifest order (locations, uoms, items) with `dry_run=true` first, then `atomic=true`. Save
   each response JSON as `RDIR/<file name without .xlsx>.json`.
4. **Headers**: `python3 -I scripts/pilot/qoimeks_convert.py headers --out OUT --responses RDIR --org-unit-id UUID --responsible-id UUID`
   writes `OUT/headers/QOI-HDR-NN.json`; `POST /api/v1/documents` each body (one draft opening per header, created with its first balance).
5. **Upload the lines files** (`dry_run=true`, then `atomic=true`). Expected per file: row 1 `unchanged` (or `updated`), the others `created`, nothing refused.
6. **Compare counts**: take `scripts/demo/demo_counts.sh snapshot > after.txt` and run
   `scripts/pilot/qoimeks_compare.sh OUT/expected_counts.txt after.txt TENANT_SLUG`. Exit 0 means equal, 1 prints
   `DIFF key expected actual`, 2 is bad input (wrong slug, empty file). The QA copy tenant must be empty before the rehearsal.

Repeating: re-upload the master files (step 3) and the lines files (step 5) with the same files; every row is `unchanged`.
Do NOT repeat step 4: an opening header pair that exists is refused (`external_ref_taken`, HTTP 409). Reuse the existing
headers and skip their creation. Balance references are `BAL:<len(sku)>:<sku>:<loc>`, so keys containing `:` stay distinct.

## Deliberately not here

Tenant and realm creation, users, the cut-over and the read-only switch (steps 4-6 of T-1569 section 5), posting of the
opening documents and the ledger-side count comparison (a manual follow-up on the QA copy), lots, prices, movement
history, and every owner decision still open in T-1569. The converter is not wired into the product; no route or flag runs it.
