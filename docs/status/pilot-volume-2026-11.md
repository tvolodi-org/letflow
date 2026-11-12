# Pilot-size read performance and index review (T-1562, BA batch 2 item 10)

Measured 2026-11-09 on the local test stack (one PostgreSQL 16.15 container, a shared 12-CPU host, other sessions
running), base commit `b522d06bc`. The numbers are a floor of what a pilot sees on a quieter machine and a
ceiling for nothing: QA and production were not measured. Repeat with:

```
MIX_TEST_PARTITION=<n> mix test --only pilot_volume test/letflow/performance/pilot_volume_test.exs
```

The run takes about 8 minutes (seeding 7.7 of them); the test is excluded from the default suite and asserts
nothing about the limits, a miss is printed and recorded here.

## Data set (counted from the database, full size, no scale-down)

```
users 50, cards 20000 (entity_assets_card rows), ledger_leg 200000, ledger_entry 1100, ledger_balance 40000
seeding: cards 137 s (4 workers), register 328 s (serial)
```

* 20 000 cards through `Records` (owner path); every 10th is retired, every 3rd is `low_value`, 50 org units,
  numbers `PERF-000001..`, names a pure function of the number (identical every run).
* 200 000 register rows = ledger legs, posted through `Ledger.post/1` into the **real assets ledger** with the real
  registration and `LedgerPolicy.declare/2`: one `commission` leg per card (20 000), then `change` rounds (two legs per
  line) until 200 000 legs. `declare/2` caps a posting at 100 lines, so the 1 100 entries have 100 to 200 legs.
  The entries are posted without the `ledger.posted` audit entry (speed), so `GET /reconcile` (P10) is informative only.
* 50 users (`TokenMintFixture.role_holder!`, TENANT_ADMIN); the caller is one token, 4 concurrent callers in P12.
* Reads go through the full `Letflow.Router` with a real bearer token (as `register_router_test.exs`).
* Not measured: browser render time (no stable browser on the host, same limit as `stock-lines-browser-perf-2026-11.md`).

## Limits (UAT assumptions; the BA item only suggested list/search under 1 s and report under 5 s, the rest are mine)

| reads | limit |
|---|---|
| P1-P4, P6, P7 (list, search, movements, documents) | median under 1 000 ms, max under 2 000 ms |
| P5 (balances) | median under 2 000 ms |
| P8 (report, export) | median under 5 000 ms |
| P11 (page open, the screen's server calls summed) | under 3 000 ms |
| P12 (4 callers) | each median within 2x of its single-caller median |
| P10 (reconcile chunk) | none |

## Results (ms, median / max of 5 runs after 1 warm-up; printed by the test)

| id | read | median | max | verdict |
|---|---|---|---|---|
| P1 | card list first page (50), `POST /entities/query` | 53 | 68 | OK |
| P2 | card list deep page (200 rows, page 49) | 71 | 77 | OK |
| P3 | card list filtered by kind + org unit | 60 | 70 | OK |
| P4a | card search by name (`contains`) | 61 | 66 | OK |
| P4b | card lookup by inventory number (`eq`) | 55 | 63 | OK |
| P5a | assets balances first page | 8 | 9 | OK |
| P5b | assets balances, one location | 9 | 9 | OK |
| P5c | assets balances, one card | 7 | 7 | OK |
| P5d | assets balances at a cutoff (`as_of_date`) | 34 | 47 | OK |
| P6a | assets movements first page | 129 | 158 | OK |
| P6b | assets movements, one document | 26 | 29 | OK |
| P7 | assets documents list | 6 | 6 | OK |
| P8a | saved report "Asset list" (`POST /entities/query`, sorted, 200 rows) | 49 | 58 | OK |
| P8b | balances export `format=xlsx` (one page) | 8 | 11 | OK |
| P10 | reconcile, one chunk | 23 | 26 | no limit |
| P11 | page open: the screen's 50 pages of 200 cards + org units, in sequence | 3320 | 3320 | **OVER** (limit 3000) |
| P12a | 4 callers, card list first page (5 s) | 61 | 96 | within 2x of P1 (53) |
| P12b | 4 callers, balances first page (5 s) | 8 | 19 | within 2x of P5a (8) |

Request used per row: P1 `{entity_type: assets_card, filters: [deleted=false, active=true], sort: inventory_number,
page_size: 50}`; P2 the same with `page_size: 200` and the cursor the server returned after 48 pages; P3 adds `kind eq`
and `org_unit_id eq`; P4 adds `name contains word17` / `inventory_number eq`; P5/P6 as in the table; P8a the report's
body (no `active` filter, 200 rows). P11 replays `fetchAllRecords` of `web/src/modules/assets/assets.api.ts`
(`page_size: 200`, cursor loop, `MAX_PAGES = 50`) plus the org-unit query, as `useAssetRows` / `useOrgUnitRows` do.

## Finding: the cards screen loads every card, and stops at 10 000

`AssetCardsPage` filters kind, org unit and retired on the server but **searches in the browser** and loads **all** cards
in pages of 200 (`fetchAllRecords`, at most 50 pages). At pilot size:

* 18 000 active cards need 90 pages; the loop stops after 50, so **only the first 10 000 cards (by inventory number) are
  on the screen**, and the search cannot find the rest. This is a functional limit, not only a speed one.
* The 50 pages cost 3 320 ms in sequence (about 66 ms each; the SQL of one page is 0.1 ms, the rest is the fixed cost of
  a query request: token, role and definition reads). That is 11 % over the stated page-open limit, **before** the
  browser parses and renders 10 000 rows.

Not fixed here (rule of this task: a bigger change goes to the operator): the cure is on the screen/route side, not an
index: server-side paging and search for the cards list (the `contains` filter on `name` and the `eq` on
`inventory_number` already answer in 55-61 ms, P4a/P4b), or a larger server page size. Follow-up to queue.

## Index review

The test runs `EXPLAIN (ANALYZE, BUFFERS)` on the SELECTs each read really ran (captured from the repo's telemetry,
not hand-written), then lists the indexes with their `idx_scan` counts after the whole run. Summary:

| read | plan | verdict |
|---|---|---|
| P1 card list page | index scan, 0.1 ms | fine |
| P3 kind + org unit | `Seq Scan on entity_assets_card`, 20 000 rows, 267 rows out, **4.0 ms** | seq scan on a table over 10 000 rows; costs 4 ms, so no index is added (a request costs 60 ms in total). Revisit if cards grow past ~200 000 |
| P4a name `contains` | index scan 0.4 ms (the `contains` on the page sort order stops early) | fine for this data; a `contains` that matches few rows scans the table |
| P4b number `eq` | `uq_assets_card_inventory_number`, 0.02 ms | fine |
| P5 balances (a/b/c) | `ledger_balance_k2_k1_index`, `ledger_balance_pkey`; 0.03-0.17 ms | fine; the only seq scan is the one-row `ledger_counter` |
| P6 movements | entries: index, 0.07 ms; legs of the page's entries: **Parallel Seq Scan on `ledger_leg`**, 200 000 rows, 14-17 ms | within limits (movements 129 ms, one document 26 ms); the leg read does not use `ledger_leg_entry_leg_no_key` for a page of entries. Not an index gap to fix at this size; note for later |
| P7 documents | tiny tables (no documents posted in this data set) | not representative |

Indexes of the assets ledger partitions after the run (`idx_scan`; includes the seeding): `ledger_balance_k2_k1_index`
400 000, `ledger_balance_pkey` 202 480, `ledger_entry_ledger_event_index` 200 303, `ledger_entry_subject_op_key` 2 919,
`ledger_entry_origin_key_key` 2 919, `ledger_leg_entry_leg_no_key` 2 188, `ledger_entry_ledger_seq_key` 1 010,
`ledger_leg_k1_k2_event_index` 630, `ledger_entry_document_index` 6, `ledger_leg_pkey` 3. Never scanned in this
workload: `ledger_leg_k1_k2_index`, `ledger_leg_k2_k1_index`, `ledger_entry_bpm_task_index`,
`ledger_entry_correlation_index`, `ledger_entry_device_seq_unique_index`, `ledger_entry_leg_target_key`,
`ledger_entry_pkey`, `ledger_entry_reverses_unique_index`. "Unused by this workload" is not "unneeded" (several back
unique constraints and the reversal and offline paths); none is dropped here. On `entity_assets_card`:
`entity_assets_card_record_id_key` 20 001, `uq_assets_card_inventory_number` 387, `entity_assets_card_pkey` 0,
`uq_assets_card_external_ref` 0. The full list is in the test output.

## Fixes made and left

* Made: none. Every ledger/report/list read is far inside its limit; no migration, no `lib/` change.
* Over its limit: P11 only; the cause is the load-everything screen, not an index (see the finding). Left for the
  operator: (1) server-side paging and search on the cards screen, (2) the silent 10 000 card cap.
* Left, low priority: the leg read of `GET /movements` scans the leg partition; a seq scan on `entity_assets_card`
  for the kind + org unit filter. Both are milliseconds at 20 000 cards / 200 000 legs.
* Method limits: one host and one PostgreSQL container, other sessions running; 5 timed runs per read; the ledger
  entries have no audit entries; browser time not measured; no QA/production measurement.

## Follow-up (T-1801, 2026-11-12): the other list screens at pilot size

Question: do the stock, locations, items and codes screens have the same fetch-all-and-search-in-browser pattern as the
asset cards had (fixed for the cards in B16#1)? Measured on the same local stack (one PostgreSQL container, shared
12-CPU host), through the full `Letflow.Router` with a real bearer token. Repeat with:

```
MIX_TEST_PARTITION=<n> mix test --only pilot_volume test/letflow/performance/pilot_volume_lists_test.exs
```

(`PILOT_ROWS=<n>` shrinks the data set for a dry run; the default is 12 000 rows per type, about 4 minutes in total,
of which seeding is 55 s per type with 4 workers.) Data set: 12 000 rows each of `catalog_item`, `code_tag`,
`location_node`, `org_employee`, all active, through `Records` (owner path). 12 000 is one size above the 10 000 cap, not a
claim about what a pilot holds: the pilot's own counts are not known to this note.

### Which screens load everything (read from the code, `grep -rn fetchAllRecords web/src`)

| screen (module) | read | where the search happens |
|---|---|---|
| asset cards (assets) | server-paged since B16#1 | server |
| items, lots (catalog_items) | `fetchAllRecords`, 200 per page, `MAX_PAGES = 50` | browser (`LotsPage` filters the loaded items by `active`; no server search) |
| codes (codes) | `fetchAllRecords` for `code_tag` (sorted by `value`), the open assignments, and the three target types | browser |
| locations tree, links (locations) | `fetchAllRecords`, same loop | browser (the tree is built from all rows) |
| org units, sites, positions, employees (org) | `fetchAllRecords`, same loop | browser |
| stock register, documents, counts (stock) | balances, movements, documents, counts are cursor-paged by "Load more" (not fetch-all); the filter and form **pickers** (`usePickerOptions`, also the assets copy) read **one page of 200** | picker: none, the options are the first 200 records |

Each of the four modules has its own copy of `fetchAllRecords` with the same `MAX_PAGES = 50`.

### Results (ms; one run of the screen's loop, one request for the picker page)

| type | loop pages | rows reached | server had more | loop time | per page | picker page (200) |
|---|---|---|---|---|---|---|
| `catalog_item` | 50 | 10 000 | **yes** | 2 530 | 51 | 47 ms, 200 rows, more on server |
| `code_tag` | 50 | 10 000 | **yes** | 1 507 | 30 | (no picker) |
| `location_node` | 50 | 10 000 | **yes** | 3 083 | 62 | 52 ms, 200 rows, more on server |
| `org_employee` | 50 | 10 000 | **yes** | 2 792 | 56 | 48 ms, 200 rows, more on server |

### Reading

* **Silent truncation exists on all four loops.** Past 10 000 records of a type the loop stops after page 50 with a next
  cursor still present and the screen shows no notice; rows 10 001.. are invisible and, since the search is in the browser,
  unfindable. Same defect as the asset cards had.
* **Speed is not the first problem:** 50 pages take 1.5 to 3.1 s before the browser parses 10 000 rows, i.e. at the
  page-open limit of 3 000 ms used above for the cards.
* **Which type can realistically get there:** `code_tag`, because one code is issued per card (20 000 cards in the
  pilot-size set above means up to 20 000 codes), and the codes screen then also loads the cards, locations and org units
  as assignment targets. Items, locations and employees reach 10 000 only in a large catalog; unknown for the pilot.
* **Pickers show the first 200 and say nothing.** With more than 200 items, locations, units or people the filter and
  document-form pickers cannot offer record 201 and later (the server answered with a next cursor in every picker row
  above). The `useNames` label lookup is a separate read and is not affected.

### Fixes made and left

* Made: none in `web/` or `lib/`. This task measures; the data set that shows the defect is not a pilot count, and a
  correct fix is a screen change per module (message in en/ru/kk, state shots, tests), which is more than "fix only what
  is clearly broken" allows in one task. Added: the on-demand measurement `pilot_volume_lists_test.exs`.
* Left, for the operator to queue, in this order: (1) **codes**: server-side paging and search for `code_tag` the way
  B16#1 did for the cards (the `eq` on `value` already exists as the screen's value filter), plus a "showing the first
  10 000" notice from the shared loop; (2) the same notice (no new paging) in the other three `fetchAllRecords` copies,
  ideally by moving the loop to one shared helper that returns `truncated`; (3) pickers: a search box that queries the
  server (`contains` on name/code) instead of a fixed first page of 200.
* Method limits: one host, other sessions running; one run per row (the cards measurement used five); 12 000 rows, so the
  numbers say "at the cap", not "at the pilot's count"; browser render time not measured; no QA measurement.
