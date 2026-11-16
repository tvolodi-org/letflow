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
   `locations.csv` (`loc_code, loc_name, loc_parent`), `items.csv` (`sku, sku_name, unit`, optional `home_loc`
   the usual place as a `loc_code` and `alt_loc` the second place), `balances.csv`
   (`sku, loc, qty`, optional `as_of`). The Qoimeks schema is not in this repository: if its column names differ, write a
   `map.json` `{"<extract column>": "<neutral name>"}` and pass `--mapping`. Comma or semicolon delimiters and a BOM are read.
2. **Convert** (no network, no database):
   `python3 -I scripts/pilot/qoimeks_convert.py convert --in IN --out OUT --system qoimeks-rehearsal --org-unit-ext U --responsible-ext E --received-on YYYY-MM-DD`.
   `U` and `E` are the external ids of the org unit and the responsible employee created in the QA tenant (Qoimeks has no
   such notion). Read `OUT/report.txt` (row numbers and constant reasons, no cell text): exit 3 means rows were dropped;
   decide with the customer's contact, then fix the extract or pass `--allow-drops`.
   The usual place goes into `03-items-NN.xlsx` as the column `default_location_id` (G3, one place per item; an item
   whose place names no location is dropped as `unknown_default_location`). The second place is not imported:
   `report.txt` says how many kept items had one ("items with a second place, not imported (G3)"), and the snapshot
   key `items_with_default_location` is compared in step 4.
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

7. **Compare quantities (RH-7)**: export the stock balances (`stock-balances.xlsx`, sheet `balances`) and run
   `python3 -I scripts/pilot/qoimeks_balances_compare.py --xlsx stock-balances.xlsx --csv IN/balances.csv --items IN/items.csv --locations IN/locations.csv`.
   It prints one `DIFF` line per item and place that differs (with names), `ROWS` and one sha256 `HASH` per side over the sorted
   (item, place, quantity) list, and `RESULT`. Exit 0 means no difference and equal hashes, 1 differences, 2 bad input.
   Rows with quantity zero or below are left out on both sides (counted in `LEFT_OUT`); `--keep-nonpositive` compares them too.

8. **Write freeze (do it before step 1)**: the Qoimeks team switches on the Qoimeks `MAINTENANCE_MODE` (writes answer 503)
   before the extract and switches it off after the last check; write down the time it was on (about 40 s was enough
   for Client 1). Letflow does not switch it.
9. **ANALYZE (after the opening documents are posted)**: infra runs one `ANALYZE;` statement on the Letflow database through
   the same `PSQL` command line that `scripts/demo/demo_counts.sh` uses. It refreshes planner statistics only and changes no row.
10. **Rollback**: lift the Qoimeks write freeze (step 8). The Qoimeks data was never changed, and the phones still hold the
    Qoimeks address and token. The Letflow company is kept, not deleted. For anything entered in Letflow after the switch, take
    the stock movements export (`stock-movements.xlsx`) and enter it in Qoimeks by hand.

Repeating: re-upload the master files (step 3) and the lines files (step 5) with the same files; every row is `unchanged`.
Do NOT repeat step 4: an opening header pair that exists is refused (`external_ref_taken`, HTTP 409). Reuse the existing
headers and skip their creation. Balance references are `BAL:<len(sku)>:<sku>:<loc>`, so keys containing `:` stay distinct.

## Move rules (Qoimeks inventory §8.10)

The move rules of Qoimeks Client 1 and where Letflow meets them. State: built, this section, or planned with its requirement id.

| Rule | How Letflow meets it | State |
|---|---|---|
| Copy | The runbook works on a copy; the source is untouched (intro, step 1) | built |
| One transaction | One transaction per file (`atomic=true`, `check_atomic` in `lib/letflow/routers/entities/record_import.ex`, steps 3 and 5) on a company that is empty before the load (step 6). The whole load is not one transaction: it is several files and posting tasks | built |
| Counts and hashes per table | Record counts (step 6, `scripts/pilot/qoimeks_compare.sh`), the quantity hash (step 7, `scripts/pilot/qoimeks_balances_compare.py`), the master data hash per table (REQ-881) | built; master hash planned, REQ-881 |
| Current balances equal | Step 7, `scripts/pilot/qoimeks_balances_compare.py` | built |
| Check-only run first | `dry_run=true` before `atomic=true` (steps 3 and 5) | built |
| Short write freeze | Step 8, the Qoimeks `MAINTENANCE_MODE`, switched by the Qoimeks team | this section |
| ANALYZE after the load | Step 9, one `ANALYZE;` through `PSQL` after the opening documents are posted | this section |
| Rollback | Step 10, lift the Qoimeks freeze; the Letflow company is kept | this section |
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
`balances.csv` (600 valid rows plus 10 deliberately bad rows — zero, negative and
comma-decimal quantities — to exercise the converter's G4 and G8 drop checks). The seed
is fixed (`--seed 42`) so each run produces identical files. Pass the directory as
`--in` to `qoimeks_convert.py convert` with `--allow-drops` to proceed through the
bad rows and verify the remaining 600 balances are accepted.

## Deliberately not here

Tenant and realm creation, users, the cut-over and the read-only switch (steps 4-6 of T-1569 section 5), posting of the
opening documents and the ledger-side count comparison (a manual follow-up on the QA copy), lots, prices, movement
history, and every owner decision still open in T-1569. The converter is not wired into the product; no route or flag runs it.
