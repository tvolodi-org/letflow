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
  in column A), `workbook_too_large` (more than 10 000 data rows, or a read cell over its byte cap: 256 bytes, 512 for the name, 64 for the quantity, or the read cells over 2 MiB together; checked before any text is normalised; also a sheet whose row and cell references would make the reader fill in more than 20 000 rows or 500 000 cells, refused before the sheet is read; only columns A..H are turned into text).

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
