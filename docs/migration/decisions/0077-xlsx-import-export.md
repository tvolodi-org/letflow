# 0077 — xlsx import (and export): the reader dependency `xlsx_reader`, its limits and mapping

Status: decided (2026-11-02, REQ-650, GH #3603). Owner: `ELIXIR-DEV`. Owner decision D-062
(2026-10-31, `ai-dala-portfolio/DECISIONS.md`): the first version of the assets and stock
application includes xlsx. This record decides the **reading** half for the record import; the
export half (writer dependency) is REQ-653 and is not decided here.
**REVIEWER sign-off: PENDING** (placeholder — the PR carries the verdict).
**SECURITY-REVIEWER: PENDING** (placeholder — untrusted file parsing on a tenant write route;
the PR carries the verdict).

Bucket **B** (generic platform capability: any vertical may import a sheet).

## 0. Premises re-verified against the tree (2026-11-02)

- `POST /entities/records/:entity_type/import` (REQ-320) takes a JSON document or a `text/csv`
  body (`Letflow.Entities.CsvImport`, GH #3182, REQ-557); nothing in the product reads `.xlsx`.
- A module-managed type answers 403 `entity_type_managed` before the body is read
  (`handle_import_records/2`); REQ-651 changes that for types with an import function (D5).
- `mix.exs` has no spreadsheet dependency.

## D1. Reader dependency: `xlsx_reader`

`{:xlsx_reader, "~> 0.8"}`, locked at 0.8.12; it depends on `saxy` (locked 1.7.0). `decimal`
is an optional dependency of `xlsx_reader` and already locked, so `mix.lock` gains exactly two
lines (`xlsx_reader`, `saxy`).

Licences, read at the locked versions from the packages' own files in `deps/`:

- `xlsx_reader` 0.8.12: `hex_metadata.config` has `{<<"licenses">>,[<<"Apache-2.0">>]}`.
- `saxy` 1.7.0: `hex_metadata.config` has `{<<"licenses">>,[<<"MIT">>]}`, and `LICENSE.md` is the MIT
  text ("Copyright (c) 2018 Cẩm Huỳnh. Permission is hereby granted, free of charge ...").
- Neither package has a native part: no `.c`, `.rs` or `Makefile` file, no `compilers:` or NIF
  entry in either `mix.exs`. Both are pure Elixir.

Rejected:

- `xlsxir`: no release since 2019-03-12.
- A reader written on OTP `:zip` and an XML parser: the shared-strings, styles and date
  machinery is what `xlsx_reader` exists to absorb; rewriting it is more code to own for no gain.

## D2. Limits (each with its source)

| Limit | Value | Source |
|---|---|---|
| request body | 2_097_152 bytes | the root `Plug.Parsers` `length:` of `lib/letflow/plugs/api_pipeline.ex`, as for CSV |
| uncompressed size of all parts | 26_214_400 bytes | the product's largest accepted upload, `@max_upload_bytes` of `lib/letflow/repository/attachments.ex` |
| data rows per file | 200 | `@import_record_cap` of `lib/letflow/routers/entities/record_import.ex`, as for CSV; over it the existing 413 |
| worksheets read | the first, in workbook order | UAT assumption; other sheets are ignored |
| XML `DOCTYPE` | refused | a part containing one makes the whole file unreadable; no entity expansion is ever attempted |

The uncompressed-size limit is checked in two stages in `Letflow.Entities.XlsxImport`: first the
sizes the archive declares (`:zip.list_dir/1`, nothing inflated, so `xlsx_too_large` is answered
before any part is parsed), then, because the declared sizes are the archive's own claim, each part
is inflated one by one with a running total of the real bytes. The same pass refuses an XML part
with a `DOCTYPE` or in a non-UTF-8 encoding. "First sheet only" and "200 rows per file" are UAT
assumptions to be confirmed by the process owner (a larger catalog is loaded in several files).

## D3. Mapping (the CSV rules of `CsvImport`, unchanged)

Row 1 is the header; each header is exactly a field name (in upsert mode also
`external_ref_system` and `external_ref_id`, together). An empty cell gives no key. Each cell is
first turned into text, then coerced by the same per-cell function as a CSV cell
(`CsvImport.convert_row/5`, shared, not copied), so a row error has the same type codes
(`csv_invalid_integer`, `csv_invalid_date`, ...) and the same `"header"`:

| Cell | Text |
|---|---|
| string | as it is |
| number | shortest plain decimal form; an integral value is the integer text (`5.0` is `5`) |
| boolean | `true` / `false` |
| date-formatted | ISO 8601 date |
| date-and-time formatted | ISO 8601 with `Z`: **assumption**, the workbook stores no zone, the value is read as UTC |
| formula | the cached value the file stores; a formula is never evaluated |

A row's `line` is its sheet row number (header = 1); blank rows are skipped. A non-blank cell to
the right of the header is the row error `xlsx_cell_count` (no cell text). Whole-file refusals
are constant atoms: `xlsx_unreadable`, `xlsx_too_large`, `xlsx_header_missing`,
`xlsx_duplicate_header`, `xlsx_unknown_header`, `xlsx_external_ref_pair`; the 422 detail is a fixed
text per atom.

## D4. Tenant isolation

The file carries no tenant identifier and the route takes none from the path, the query or the
file: the tenant is the authenticated one (`prefix!(conn)`), as for every import. A type the caller
cannot see answers 404 before the bytes are read (INV-5), the same answer the CSV path gives. The
converter runs before `import_scope_check/6`, which sees the same records as for JSON and CSV
(decision 0051 D6 and M9 apply unchanged).

## D5. Managed import path (REQ-651, GH #3602)

Decision 0057 D12 seeds masters through the generic idempotent import; for a module-managed type
this is the path that does it, and it is the seeding path D12 names for managed masters.

1. **Registration.** A module declares the optional manifest key `:import_functions`, a list of
   `%{entity_type: name, function: atom}`. Rule 14 of `Letflow.Modules.Catalog.validate/2` refuses a
   malformed list, a name not in the manifest's `:manages_entity_types`, a duplicate name and a
   function the entry module does not export with arity 3. The core resolves a function by string
   comparison over the compiled manifests (`Catalog.import_function/2`, fail closed) and calls it in
   one place (`Catalog.call_import_function/5`); no request datum picks code and the core never builds
   an Owner. The key is not part of the manifest hash (it is code, not a definition).
2. **Route.** `POST /entities/records/:entity_type/import` for a managed type with a registered
   function no longer answers 403: it reads the JSON, CSV or xlsx body as before and requires upsert
   mode (422 otherwise, nothing written). A managed type with no function (the exam types, the lot
   type) still answers 403 `entity_type_managed`. The permission, the 200-row cap, the schema
   version, the type match, the refusal of upsert mode for a scoped caller (`import_scope_check/6`)
   and the field-restriction rule of `ImportUpsert` stay in front.
3. **Rows.** `Letflow.Entities.ManagedImport` runs the `ImportUpsert` row checks and calls the
   function once per row, in file order, as `f(prefix, entry, ctx)` (`ctx`: `actor_id`, a
   server-derived `idempotency_key`, `dry_run`). It returns `{:ok, %{record_id, outcome}}` or
   `{:error, reason}`. A function that raises answers the row `internal_error`; only the exception
   module is logged. The function writes through its own module's Owner (0050 D7).
4. **References.** A reference cell holds the external id of the target under the same
   external-ref system as the row; the module resolves it in the same tenant to the record id of the
   live target. None, a deleted target, a cell that is not text or a record id (which matches no
   external id) is `reference_not_found`; a target with `active` false is `reference_inactive`
   (0050 D3.2), also for an otherwise unchanged re-imported row. Both answer with the constant
   `header` naming the field, never the cell text. A target must come earlier in the file or be
   stored already. The catalog module (`Letflow.Modules.CatalogItems.Import`) registers `catalog_uom`,
   `catalog_item` (`base_uom_id`) and `catalog_counterparty`; it also writes the row's external ref
   into the type's own `external_ref_system` and `external_ref_id` fields.

## D6. Re-import

The same file again answers every row `unchanged` and writes no event (REQ-505 upsert). Existing rows
that carry the field pair but no record-level external ref are not found by the upsert and are
refused per row by the field unique constraint; nothing is overwritten. No upgrade of installed
tenants is needed (code only).

## D7. Dry run

`?dry_run=true` or `"dry_run": true` in a JSON body runs the whole file inside one transaction that
always ends in a rollback, so a row sees the rows before it and nothing is kept; the answer carries
`"dry_run": true` and the real answer is unchanged otherwise. It is offered only for managed types
with an import function (422 for any other type, so it can never silently write).

The nested-transaction fact the design had to read: `DBConnection` ignores `mode: :savepoint` inside an
outer transaction, and a nested `Records` multi that fails (a unique violation, for example) marks the
connection aborted, so every later statement of the outer transaction fails. A row refused before the
database (reference, validation, restriction, ref errors) does not do that. After a refused row the
runner sends a probe statement; if the connection is aborted it rolls everything back and replays the
whole file in a fresh transaction with that row's result fixed (not called, writes nothing, as in the
real import where its own transaction rolled back). Rows after it therefore get the results the real
import gives. Replays are capped at 20; beyond that the answer is 422 `dry_run unavailable` and nothing
was written. The cost is rows times refused-by-the-database rows; the abort also makes the driver
close and reopen the connection, which logs one `disconnected` error line per replay.

## Residual risk

The declared sizes in the archive are the archive's own claim and are not trusted. The entries
are taken from `:zip.list_dir/1` (the directory XlsxReader would read, with OTP's end-of-central-
directory and ZIP64 rules), and every part is inflated as a bounded stream (`:zlib.safeInflate/2`
from its local header) that stops as soon as the running real total passes the 25 MiB cap, so a
forged archive that understates its sizes is refused with `xlsx_too_large` before more than the
cap (plus one inflate chunk) is allocated. XlsxReader is then given a fresh archive rebuilt with
`:zip.create/3` from only the verified parts, so it never inflates bytes that were not counted,
and a hidden second directory (a fake EOCD in the comment, a ZIP64 locator) cannot show it
something else. Covered by tests C3m and C3n. What remains: up to
25 MiB per concurrent import request, bounded by the cap and the 2 MiB body limit.
