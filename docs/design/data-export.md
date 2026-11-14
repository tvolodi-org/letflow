# Data export

The backend currently provides synchronous machine-id exports (T-1955, S1a-1).
No Data export screen ships in this slice. The existing module xlsx endpoints and
their page buttons remain until the screen replaces them in S1b.

## Current API

Both routes under `/api/v1/data-export` require the tenant-scope `DataExport`
permission. TENANT_ADMIN holds it by default; PLATFORM_ADMIN holds it only inside
the platform tenant. Neither STOREKEEPER nor TENANT_AUDITOR holds it. Access uses
permission atoms, never a role-name check in the handler.

`GET /datasets` returns `datasets`, each with `id`, `formats` (`xlsx`, `csv`,
`json`) and `filters` (`key`, `kind`). A dataset is offered only when its owning
module is installed and `Ledger.authorize/3` grants the caller its read authority.
The registry order is stock balances, stock movements, asset balances.

`POST /` accepts, for example:

```json
{
  "ids": "machine",
  "lang": "ru",
  "datasets": [
    {"id": "stock_balances", "format": "xlsx", "filters": {}}
  ]
}
```

`ids` is required and must be `machine` in this slice. `lang` is `ru` (default),
`kk` or `en`. Each dataset requires `id` and `format`; `filters` defaults to an
empty object. Unknown body keys, empty or duplicate selections are refused.
Formats are validated before ids, and all ids before filters. Validation finishes
before any dataset read. An unknown, uninstalled or unreadable dataset has the
same `dataset_unknown` refusal. Tenant authority comes exclusively from the
authenticated connection; a body `tenant_id` is refused.

| Dataset | Filters | Machine columns |
|---|---|---|
| `stock_balances` | `as_of_date`, `scope_subtree`, `org_unit`, `location`, `sku` | sku, location, org_unit, responsible, lot, unit_ref, quantity, last_posting_seq |
| `stock_movements` | `scope_subtree`, `org_unit`, `location`, `sku` | entry_id, posting_seq, posting_time, event_time, cause, reverses_entry_id, reason_code, document_type, document_id, document_number, related_document_id, correlation_id, leg_no, sku, location, org_unit, responsible, lot, quantity, unit_ref, document_line_id, masked |
| `asset_balances` | `as_of_date`, `scope_subtree`, `org_unit`, `location`, `asset` | asset, org_unit, location, material_responsible, actual_user, unit_ref, quantity, last_posting_seq |

Dates use ISO `YYYY-MM-DD`; slot filters are UUIDs; `scope_subtree` is a nonempty
UTF-8 node id of at most 64 bytes. Balance reads omit zero quantities. Movements
have one row per leg, in posting-sequence and leg order. Scoped reads retain the
ledger's masking: hidden legs disclose no slot ids or document line id. Asset
`unit_ref` is stored text (`pcs`), not a catalog reference. These datasets contain
only fields already exposed by their module read routes, using the same Views
allowlists. No additional personal fields are loaded.

Balance pages pin the cutoff from page one's report, including dated reads through
`Ledger.balances_on_date/5`. A timezone change during a dated export can change the
day boundary between pages. Movements are an append-only prefix: the ledger's
counter lock orders commits, and metadata records the last posting sequence.
All timestamps and download filename dates use UTC.

## Files, limits and audit

A single dataset returns its file. Multiple selections return a zip containing one
file per dataset plus `manifest.json` (id, filename, format, written row count,
truncated, cap). Filenames use dataset ids with hyphens and the UTC date.

Xlsx files have `data` and `report` sheets; quantities exceeding 15 significant
digits remain text. Text cells cannot become formulas. CSV is UTF-8 without a BOM
in machine mode, comma-separated, with CRLF endings and quoting. Its formula guard
applies to text only: numeric `-5` remains numeric. JSON includes dataset, ids,
lang, generated_at, filters, meta, cap, truncated, rows_total_written, columns and
rows; quantities stay strings.

The cap is 10,000 **file rows per dataset**, including movement legs. A truncated
file says so in `x-export-truncated`, xlsx's report (English, Russian or Kazakh),
JSON and the zip manifest. CSV relies on the header and manifest to retain its
machine-readable table shape. All downloads carry `Cache-Control: no-store`.

At most ten successful downloads per actor in 600 seconds are allowed. Counting
uses the tenant's own audit entries; count failure refuses the request. Parallel
requests at the window edge may both pass. A 429 carries `Retry-After: 600`.
There is no new cache, process, dependency, feature flag or database table.

After all reads and rendering succeed, one `data_export.downloaded` audit entry
records actor, ids mode, language, dataset ids, formats, filters, written row counts
and truncation. No row data is audited. Audit insertion failure returns a detail-free
500 and no file. Refused exports produce no download audit entry. Query cancellation
maps to 503 `ledger_read_timeout`, without returning partially collected rows.

Providers implement `Letflow.DataExport.Dataset` in their own module directory.
The runtime config `:data_export_datasets` registers them without core-to-module
edges (boundary Rule 5). Shared validation and balance pagination live in the core
behaviour module. `:data_export_row_cap` and `:data_export_page_limit` are test-only
application settings, with production defaults when unset.

## Remaining slices (planned, not current behaviour)

1. S1a-2: readable code/name headers, batched lookups, localized asset unit words,
   readable CSV BOM, and readable default. Requiring explicit machine mode now
   means the future default changes no request currently accepted.
2. S1b, after S1a-2: Data export screen, navigation and permission; remove the three
   machine-id page buttons and dead `assets.journal.export` text together. Keep
   readable count paperwork and audit CSV on their pages. Keep the documented
   REQ-728 module xlsx API. Link the three pages to Data export for its holders.
   Use the shared page header and ListDetail, dataset selection, per-dataset
   settings and the full loading/error/empty/exporting/truncated/rate-limit states.
3. S2: asset movements/cards, items, locations and counts; movement date ranges and
   tenant-local readable timestamps. Status filters belong to applicable datasets.
4. S3: documents by kind and audit log.
5. S4: async jobs, expiring owner-only download links and a three-day purge. Its
   security design must rederive authority from a stored actor without a conn and
   recheck it at execution and download time.
6. S5 (optional): scoped DataExport grants and API-token callers.

Each follow-up waits for the previous slice. This backend slice does not complete
the full Data export feature; its PR must reference, rather than close, that issue.
