# Stock workbook import: the check (REQ-884)

Module `stock`. The bookkeepers keep balances in an Excel workbook in the Qoimeks layout (the one
`GET /api/v1/modules/stock/stock-workbook` writes, REQ-865). The **check** reads such a workbook, compares it with
the stock of one org unit and answers what a load would change. It writes nothing: no record, ledger entry, audit
entry or document number. The load is REQ-885. QA only; no flag, no migration, no new permission.

## Route

`POST /api/v1/modules/stock/stock-workbook/check?org_unit_id=<id>`

- Body: media type `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, 2 MiB at most (the platform's
  one body limit; larger is 413). No hash or file binding.
- Permission `StockRead`, and the caller must read the whole tenant (a reader scoped to some units gets the same 404 as
  an unknown stock path, because the check reads every balance of the items in the file).
- Query: only `org_unit_id`. Missing: 422 `org_unit_required`. Not an active org unit of this tenant (another tenant's
  id included): 422 `org_unit_not_found`. Any other key: 422 `invalid_filter`.
- 422 `xlsx_unreadable` (not a readable workbook, a `<!DOCTYPE`, a missing body), `header_missing` (no cell "Артикул"
  in column A), `workbook_too_large` (more than 10 000 data rows, or a read cell over its byte cap: 256 bytes, 512 for the name, 64 for the quantity, or the read cells over 2 MiB together; checked before any text is normalised; also a sheet whose row and cell references would make the reader fill in more than 20 000 rows or 500 000 cells, counting cells it builds and drops (outside a row, under a nested row), or a row or cell reference, style index, shared-string index or shared-formula index over 10 bytes (a shared-formula index also at or over 500 000), refused before the sheet is read; only columns A..H are turned into text).

Answer 200: `sheet`, `rows_read`, `remarks` (`{row, text}`, sheet order), `changes` (`{row, item_code, item_name,
place_code, book_quantity, file_quantity, difference}`, quantities as decimal strings, `row` null for a place emptied
because the file does not name it; items in file order, places by code), `unchanged_count`, `too_many_changes` (true
above 1000 changes, the line cap REQ-885 refuses).

## Layout

Only the first worksheet is read. Rows before the first row whose cell A is "Артикул" are skipped. After it a row
with A or B empty is skipped without a remark.

| Column | Meaning |
|---|---|
| A | article: the `catalog_item` code (exact match after trimming and collapsing inner spaces) |
| B | name |
| C | quantity |
| D, E, F | zone, rack, shelf; the place code is zone + rack + shelf |
| H | place code, read only when D, E and F are all empty |
| G, I, J | not read |

## Normalising

- Text is trimmed; runs of white space become one space.
- Zone and rack go to upper case; the Cyrillic letters А В С Е Н К М О Р Т Х become the Latin A B C E H K M O P T X;
  a zone or rack "0" becomes the letter O.
- Quantity: white space, `'` and `’` are removed. When both `,` and `.` occur, the one written last is the decimal sign
  and the other is removed; a single `,` or `.` is the decimal sign; several of one sign and none of the other are
  thousands signs. The result must be a decimal of 0 or more with at most 9 decimals.

## What counts as a change

Per article, in file order, the first rule that applies wins: (a) no catalog item with that code (R8); (b) the item is
tracked by lot, serial or expiry (R9); (c) a quantity that is not a quantity (R1); (d) an amount above 0 with no place:
to the location "?" if the tenant has one (R4), otherwise R5; (e) rack or shelf without a zone letter (R3); (f) a place
code that is no location of the tenant (R6); (g) the item holds a non-zero balance that is not a plain key, that is, in
another org unit, with a responsible, with a lot or in another unit (R7). A refused article is left out and its balances
are not changed.

Otherwise the quantities of the article are added up by place; each place's target is that sum, and every plain key of
the item (chosen org unit, no responsible, no lot, base unit) at a place the file does not name for it, that holds a
non-zero balance, has target 0. Items that are not in the file are left alone. A change is a place whose target differs
from its book quantity.

## Remarks

Each is `строка N: ` + the text (N the sheet row). `<a>` is the article. The texts are UAT decisions to be confirmed by
the process owner.

| Id | Text |
|---|---|
| R1 | `<a>: остаток "<raw>" не является количеством. Остатки этого товара в системе не изменяются` |
| R12 | `<a>: отрицательный остаток "<raw>" не загружается, учётный остаток остаётся как есть. Остатки этого товара в системе не изменяются` (a negative quantity, which the export itself writes; never loaded, so the counted stays 0 or more) |
| R2 | `<a>: место <code> указано повторно, остатки сложены: <sum>` |
| R3 | `<a>: в месте "<zone>" "<rack>" "<shelf>" не указана зона. Остатки этого товара в системе не изменяются` |
| R4 | `<a>: остаток <q> без места, записан в место "?"` |
| R5 | `<a>: остаток <q> без места. Остатки этого товара в системе не изменяются` |
| R6 | `<a>: место <code> не найдено. Остатки этого товара в системе не изменяются` |
| R7 | `<a>: остаток ведётся отдельно по подразделениям, ответственным, партиям или единицам. Остатки этого товара в системе не изменяются` |
| R8 | `<a>: артикул не найден, строка пропущена` |
| R9 | `<a>: товар учитывается по партиям или серийным номерам. Остатки этого товара в системе не изменяются` |
| R10 | `<a>: артикул повторяется с другим названием "<name>". Остатки сложены` |
| R11 | `<a>: место "<zone>" "<rack>" <shelf> прочитано как <code>` (a look-alike letter or a zero was changed; a case change alone gives no remark) |

R1, R3, R5, R6, R8 give one remark per row concerned; R7 and R9 one remark at the first row of the article.

## Test seams

App env `:stock_workbook_import_max_rows` and `:stock_workbook_import_max_changes` can only lower the caps (10 000 and
1000).

## Code

`Letflow.Modules.Stock.StockWorkbookImport` (`parse/1` pure, `check/3`); the bytes are read only through
`Letflow.Entities.XlsxImport.read_text_rows/1` (bounded inflate, no DOCTYPE; one parse); the body is taken by
`Letflow.Plugs.XlsxBodyParser`; the route is in `Letflow.Modules.Stock.Router`.

## Load (REQ-885)

The load creates a `stock_quick_count` document and starts the approval process. The check's rules
run again inside the transaction before anything is written.

### Route

`POST /api/v1/modules/stock/stock-workbook/apply?org_unit_id=<id>[&file_name=<text>]`

- Body: same media type and body parser as the check; 2 MiB at most.
- Permission `StockWorkbookApply` (T-2239; held by TENANT_ADMIN and PLATFORM_ADMIN only: the Excel load is an administrator function; STOREKEEPER holds `StockQuickCount` for the quick count but gets 403 here); tenant-wide readers only (a scoped reader gets 404).
- `file_name`: optional, 1 to 255 characters, default `workbook.xlsx`.
- `org_unit_id` and format errors: same as the check.
- 409 `definition_not_active` if the `stock_quick_count` process definition is not active, or its document type
  is absent on an install older than 0.20.0 (reinstall the stock module, QA only; nothing is activated or written).
- 422 `too_many_changes`: the file has more than 1 000 differences; nothing written.
- 422 `count_in_progress` with `held_by` the order number: a count order whose scope covers a
  key in the file is opened; nothing written.
- 200 `applied: false, changes: 0, remarks: [...]`: the file equals the stock; nothing written.
- 201 `document_id, number, lines, remarks, approve_task_id`: document created and issued.

### After load

The document is an issued `stock_quick_count` (kind `quick_count`, prefix `QCT`). Its header
keeps the quick count schema (`org_unit_id`, `reason_code: "other"`, `reason_text: "Записать
остатки из файла"`). The version content carries `workbook_ext` with `source: "workbook"`,
`file_name`, `sheet`, `rows_read` and `remarks_count`; read it with `GET /documents/:id`.

**Difference from `POST /quick-counts`.** The load does not run the REQ-854 location-link check
(`not_linked`): a changed key at a place that is not linked to the org unit is not refused, and
posting does not re-check the link. The load writes only what the REQ-884 check finds, and that
check does not test the link either.

**Four eyes ON (default).** The loader's own completion of the approve task is refused
`separation_of_duties`; a second user completes it. After approval the ledger receives one entry
of cause `count_set` with one leg per change. If a balance changed between the load and the
approval, the whole entry is refused `quick_count_stale`; the task stays pending. The user
cancels the import (see REQ-886) and re-checks.

**Four eyes OFF.** When the tenant has the `stock_quick_count / approve` approval rule set to
`four_eyes: false`, the loader can complete the approve task alone.

## List and cancel (REQ-886)

### List

`GET /api/v1/modules/stock/stock-workbook/imports`

- Permission `StockRead`, tenant-wide only (a scoped reader gets 404).
- No query parameters; any key returns 422 `invalid_filter`.
- Returns up to 50 loads, newest first: `document_id, number, created_at, created_by, file_name,
  sheet, lines, remarks_count, state, reversal_pending`.
- `state` values: `issued` (awaiting approval), `posted` (approved, balances set), `reversed`
  (reversal complete), `cancelled` (cancelled before approval).
- `reversal_pending: true` while a reversal of a posted load has started but its reverse task is
  not yet completed.

### Cancel

`POST /api/v1/modules/stock/stock-workbook/imports/:id/cancel`

- Permission `StockReverse`.
- JSON body `{"reason": "<text>"}`. The reason is required (422 `reason_required`), trimmed
  non-empty, at most 500 characters (422 `reason_too_long`). It is checked before anything changes.
- Errors: 404 for an unknown id, a non-workbook document or a document of another tenant; 403
  when the caller lacks `StockReverse`.

**Before approval (`state: issued`).** The document is cancelled like `POST /documents/:id/cancel`.
Answer `200 {"action": "cancelled", "lines": N}`. The approve task is withdrawn; the document reads
`cancelled`; balances are unchanged.

**After posting (`state: posted`).** A reversal is started like `POST /documents/:id/reverse`
(reason code `other`, reason text the given reason). Answer
`200 {"action": "reverse_pending", "lines": N}`. **Balances do not change at the cancel call.**
The `state` of the load reads `reversal_pending` in the list until the reverse task is completed.

**Completing the reverse task.** After the cancel the load has an open `reverse` task visible in
the user's inbox and on the document screen. Any user holding `StockReverse` may complete it. After
completion the ledger receives one reversal entry that negates every leg of the original posting,
and each balance returns to its value before the load.

**Reversal already running.** A second cancel while the reverse task is open returns
409 `reversal_pending` and nothing is written.

**Already finished.** A cancel of a load already cancelled or reversed returns
422 `import_already_cancelled` and nothing is written. The same applies to a load reversed through
`POST /documents/:id/reverse`.

**Negative-balance guard (gap, row G4, REQ-833).** Qoimeks allows a reversal even when it would
take a balance below zero. Letflow refuses it when the tenant's ledger has the
`negative_balances_allowed: false` setting. The refusal happens at the completion of the reverse
task, not at the cancel call, so `cancel` always answers `reverse_pending` for a posted load; the
reverse task may then refuse `insufficient_balance` / `insufficient_stock` and stay pending until
the gap is resolved (REQ-833, pending).
