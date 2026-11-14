# Official forms vs the Ministry templates (T-1965)

Date: 2026-11-14. Base: `main` at `cbe12af93` (the QA build the samples were made from). QA only; documentation only.
The printers (`FormPrint`, `FormPrint.Docx`, `FormPrint.Pdf`, `priv/print_forms/*`) are **not changed** here: the
operator queues the fixes from the table below.

## Summary in plain words

- **Page shape is wrong on every form.** All ten reference templates are A4 **portrait** with margins 25/15/25/25 mm
  (annexes 25, 27, 29, 30, 41) or 20/15/20/22.5 mm (annexes 16, 18, 19, 26, 49), a page header and a page footer, and
  Times New Roman 12 pt. Everything we print, `.docx` and PDF, is A4 **landscape**, 12.7 mm margins, Times New Roman
  10 pt, no header, no footer.
- **The title block is not arranged like the Ministry form.** In the template the annex line ("Приложение 26 к приказу …"),
  the form code, the organisation / IIN-BIN cells, "Номер документа / Дата составления" and the Z-5, Z-6, DA-x
  "basis / structural unit" lines are small tables, right-aligned for the annex line. We print them as plain
  `label: value` lines, one per line, on the left (the template has 4 to 8 such tables per form, we have 1 to 3 tables
  in the whole document).
- **Quantities print with nine decimals** (`5.000000000`, `1.500000000`) in both `.docx` and PDF. In the PDF the
  total column wraps a digit onto a second line (`21.00000000` / `0` on Inv-10). The templates show no decimals
  rule in their cells (empty rows).
- **The PDF draws only horizontal rules** between rows (no vertical cell borders) and adds "Страница N из M". The
  `.docx` has a full cell grid. The template has a full grid in both.
- **The main table is close to the template**: same columns in the same order, the grouped header ("Количество:
  подлежит отпуску / отпущено", "Результаты инвентаризации …") exists in the `.docx`. Differences are the width
  distribution (the "number" column is 6 % against 7 to 17 %, the "name" column about 19 %), three repeated header
  rows, and in Inv-18 and DA-3 fewer merged header cells than the template.
- **Z-3 is the furthest from its template**: the template has a 15-column header table (kind, brand, grade, profile,
  size, account, nomenclature number, unit, price, shelf life, responsible party in 4 cells) above a 9-column
  movement table; we print the header facts as about 14 `label: value` lines and only the movement table.
- **Kazakh wording**: there is no Kazakh `.docx` template, so kk was checked against the Adilet Kazakh text of the order
  (`adilet-kk-562-text.txt`, outside the repo). Of the kk fixed lines, only the lines in the table (title, annex line,
  few composite lines) were not found as written; most of them are our `label: value` lines versus the table cells of the
  official text, not a different wording. No wrong form code or annex number was found in kk.
- **The owner's downloads** (`ISS-…_Z-2`, `stock-card_…_Z-3`, `TRF-…_Z-5`) are from an older build than the QA samples:
  same text, but no repeated header rows and a different width split (name column 27 % instead of 19 %). The table
  below describes the current build.
- **DA-2 was merged after the QA samples** (`37f1d3389`, #4469), so it has no QA sample: it was built from `da2.json`
  with empty data (`FormPrint.build`, no database) and compared the same way; the row below is from that file only.
- **Not built, not compared**: Z-7 (annex 31, `template_application_ru31.docx` present); `priv/print_forms` has no `z7.json`.
- **Everything not in the table matched**: fixed ru wording of headers and signature lines, column order, the "М.П." mark
  where the template has it, the annex and form-code text (all ten print the right annex number and form code).

## Sources

| Form | Annex | Template file (folder `~/Documents/KZ-MinFin-DocTemplates/`, read only, not copied) | Samples (`state/form-samples/`) |
|---|---|---|---|
| Z-1 / Қ-1 | 25 | `template_application_ru25.docx` ("Форма З-1") | `Z-1_ru/kk .docx/.pdf` |
| Z-2 | 26 | `template_application_ru26.docx` | `Z-2_*` |
| Z-3 | 27 | `template_application_ru27.docx` | `Z-3_*` |
| Z-5 | 29 | `template_application_ru29.docx` | `Z-5_*` |
| Z-6 | 30 | `template_application_ru30.docx` | `Z-6_*` |
| Inv-10 | 41 | `template_application_ru41.docx` | `Inv-10_*` |
| Inv-18 | 49 | `template_application_ru49.docx` | `Inv-18_*` |
| DA-1 | 16 | `template_application_ru16.docx` | `DA-1_*` |
| DA-2 | 17 | `template_application_ru17.docx` | none from QA; built from `da2.json` with empty data |
| DA-3 | 18 | `template_application_ru18.docx` ("Форма № ДА-3") | `DA-3_*` |
| DA-4 | 19 | `template_application_ru19.docx` | `DA-4_*` |
| Z-7 | 31 | `template_application_ru31.docx` | not built |

The annex-51 file is spelled `template_aplication_ru51.docx` (typo in the file name; not used here). Each template was
matched by its annex line and title line (read with the script's `summary`). Kazakh reference text:
`ai-dala-portfolio/inbox/kz-minfin-forms/adilet-kk-562-text.txt`, annex headings found as `NN-қосымша ` (trailing space).
Layout of kk is the same layout file as ru (`priv/print_forms/<form>.json`), so a layout difference is listed once for
`ru, kk`.

## Table of differences

Severity: **blocker** = an accountant or auditor would not accept the paper as that form (wrong or missing annex or form
code line, a required column, signature or stamp place missing, column order differs, kk text not the official wording);
**major** = clearly different arrangement a reader notices (orientation, title block arrangement, grouped header
flattened or missing, wrong number format); **minor** = spacing, margins, font size, widths within a usable range.
Size: **S** = layout JSON or catalog data edit; **M** = renderer change.

| Form | Language | What differs | Severity | Fix idea | Size |
|---|---|---|---|---|---|
| all (not Z-7) | ru, kk | Page: template A4 portrait 210x297 mm; ours A4 landscape 297x210 mm, `.docx` and PDF (script `diff` PAGE; `pdfinfo` 842x595 pt) | major | per-form `orientation` in the layout JSON; `FormPrint.Docx` and `FormPrint.Pdf` honour it; wide tables use the template's narrow columns | M |
| all | ru, kk | Margins: template 25/15/25/25 mm (annex 25, 27, 29, 30, 41) or 20/15/20/22.5 mm (16, 18, 19, 26, 49); ours 12.7 mm on all sides, `.docx` and PDF | minor | margins per form in the layout JSON, same renderers | S |
| all | ru, kk | Font: template Times New Roman 12 pt body (Z-3 mostly 10 pt, headings 14 pt); ours Times New Roman 10 pt body, 14 pt title in `.docx`; PDF embeds DejaVu Sans only (`pdffonts`), not Times New Roman | minor | body size per form; PDF: use a serif face if one is available in the printer's font set | M |
| all | ru, kk | Header and footer: template has a page header and footer part on every form (page number); `.docx` has none; PDF has a "Страница N из M" footer, `.docx` has no page number | minor | add footer part with page field in `FormPrint.Docx` | S |
| all | ru, kk | Quantities and amounts print with nine decimals (`5.000000000`) in `.docx` and PDF; on Inv-10 the PDF total column wraps (`21.00000000` / `0`) | major | format numbers per column (decimals in the layout column or the catalog), no wrap in PDF number cells; guard: no `\d\.\d{9}` in the output | S |
| all | ru, kk | PDF table has horizontal rules only; `.docx` has a full cell grid, the template a full grid | major | draw vertical rules in `FormPrint.Pdf` | M |
| all | ru, kk | Title block: template has the annex line as a right-aligned block ("Приложение к приказу" cell and the annex text) and the organisation / IIN-BIN / number / date as 2 to 3 small bordered tables; ours are `label: value` lines on the left | major | new layout block kind "boxed pairs" (cell with label above, value below) and a right-aligned text block, both renderers | M |
| all | ru, kk | Row heights: the template sets `w:trHeight` on its rows (30 twips on Z-2); ours sets none (0 `trHeight` in Z-2); we mark 2 to 3 header rows as repeating (`tblHeader`), the template marks none | minor | optional min-height for blank rows in the layout | S |
| Z-1 | ru, kk | Table (11 columns): template widths 13/15/9/9/5/9/5/8/7/9/11 %, ours 6/19/8/9/8/9/8/8/8/8/9 %; merged header cells: template 4 `gridSpan`, ours 2; template has a 3-column "Организация / склад" table and a 7-column signature table (принял / сдал), ours has signature lines as text | major | widths per column in the layout JSON; signature table block | M |
| Z-2 | ru, kk | Template: 4 tables for the title block, the 5-column "sender / receiver / responsible / transport / TTN" table (2 rows) and a 4-column signature table (разрешил, по доверенности, получил); ours: lines `Организация - отправитель: …` etc. and signature lines as text; the data table is the same 9 columns (ours 6/19/13/11/10/10/10/10/10 %, no width difference above 5 points was reported for the main table) | major | boxed-pairs block for the 5 facts; signature table block | M |
| Z-3 | ru, kk | Template has a 15-column header table (merged cells, 4 rows) with kind, brand, grade, profile, size, account, nomenclature number, unit, price, shelf life and a 4-cell "responsible party" group, then "Наименование запаса ____", then the 9-column movement table, then "Сведения о наличии драгоценных материалов" (2 columns). Ours: 13 lines `Вид производства: …` and only the movement table; widths template 8/10/9/11/23/9/8/9/13 %, ours 6/19/10/11/11/10/10/10/11 %; two header rows, template none repeated | major | add the 15-column header table block to `z3.json` and the precious-metals table; widths | M |
| Z-5 | ru, kk | Template has an 8-column x 3-row facts table (organisation, structural unit sender / receiver, basis, responsible, document name, number, date) and a 2-column signature table; ours prints 7 label lines and 4 signature lines (отпуск разрешил, проверил, отпустил, получил) as text; kk: the labels `Негіздеме (құжаттың атауы, нөмірі, күні)` and `сомаға (жазумен), теңгемен` are our composites, the sub-words are in the official text | major | facts table block; signature table block | M |
| Z-6 | ru, kk | Template has 5 tables; ours 2. Missing as tables: header facts (5 columns x 3 rows), "основание" row; the 10-column table has 1 `gridSpan` in the template, none in ours; widths template 7/13/15/12/7/9/11/8/7/8 %, ours 6/19/12/11/8/9/11/8/8/8 %; the second table has 2 `gridSpan` / 12 `vMerge` in the template, 1 / 12 in ours | major | facts table block; merged header cell in the layout | M |
| Inv-10 | ru, kk | Template: boxed title block (organisation, IIN-BIN, document number, date), then the inventory text; ours: text lines. The text paragraphs ("На основании приказа …", "Инвентаризация начата …") are present, but as `label: value` lines, and the data table starts on page 1 with nine-decimal quantities; PDF total wraps | major | boxed pairs; no-decimals quantities | M |
| Inv-18 | ru, kk | Table 1 (14 columns): template has 8 merged header cells over "Результаты инвентаризации" (излишек / недостача) and 12 `vMerge`; ours has 4 merged header cells and 8 `vMerge`, header cells "Результаты инвентаризации", "излишек", "недостача" are not found in ours; table 2 ("Пересортица" 5 merged cells in the template, 4 in ours); the second grouped header differs; widths template 7/12/13/8/8/5/8/5/8/5/3/8/5/3 %, ours 6/19/9/6/7/5/7/5/7/5/5/7/5/5 %; 5 tables in the template, 2 in ours; kk: `Салыстыру нәтижелерімен келісемін (-міз):` is our text | major | grouped header per template (labels in the catalog keys, more levels in the layout); guard: merged-cell counts equal the template's | M |
| DA-1 | ru, kk | Template 8 tables (annex text, boxed facts, signature tables), ours 2; widths of the 7-column table template 15/11/5/18/16/20/16 %, ours 6/19/12/16/15/17/15 %; kk: sentences "Қабылдау (беру) сәтінде …", "Қажетті техникалық-экономикалық … талаптарға", "Пысықтау талап етілмейді …" are longer than the lines found in the official text | major | boxed facts and signature table blocks; check the three kk sentences against the order text | M |
| DA-3 | ru, kk | Template 7 tables, ours 3; table 1 (10 columns) header cell "инвентарный номер" not found in ours; table 3 (9 columns) has 3 `gridSpan` in the template, 2 in ours and the header cells "Запасы", "наименование", "номенклатурный номер" are not found in ours; widths template 8/14/9/9/10/15/10/11/7/6 %, ours 6/19/9/11/10/11/10/8/8/9 % | major | grouped header with the "Запасы" group; widths | M |
| DA-4 | ru, kk | Template 4 tables (annex cell, boxed facts, 3-column table, 10-column table), ours 1; widths template 7/14/13/12/9/10/8/7/8/11 %, ours 6/19/13/9/8/10/8/9/8/9 % | major | boxed facts block; widths | M |
| Z-1, Z-2, Z-3, Z-5, Z-6, Inv-10, Inv-18, DA-1, DA-3, DA-4 | kk | kk wording check (`text`): form codes and annex numbers equal the official text; reported lines are composites (`label: value`) or our own sentence order. Annex line: ours is a one-sentence line `Қазақстан … бұйрығына 25-қосымша`; the Adilet text has the number in the heading `25-қосымша` | minor | none needed until a kk .docx reference exists; ask the owner for one | S |
| Z-1 ... DA-4 | ru, kk | Signature blocks and stamp place: the template puts position / signature / name in a table row with a ruled line; ours prints `должность / подпись / расшифровка подписи` as text under `____ / ____` lines, "М.П." is printed where the template has it | minor | signature table block (same block as above) | M |
| DA-2 | ru, kk | Same page, margin, font, header/footer differences as `all`. Template 10 top-level tables, ours 6; the 6-column x 2-row signature/commission table has 3 columns in ours (header cells "4", "5", "6" not found); widths of the 10-column table template 13/14/12/11/11/8/7/12/9/4 %, ours 6/19/10/10/10/9/8/10/9/8 %; of the 8-column table 11/13/18/17/8/9/11/12 %, ours 6/19/14/12/12/12/12/12 %; two tables of ours have no equal in the template (3 and 5 columns x 2 rows) | major | boxed facts block, widths, 6-column table in `da2.json` | M |
| Z-7 | ru, kk | Not built: no `z7.json`; template `template_application_ru31.docx` exists (A4 portrait, 2 pages) | blocker | build the form from annex 31 | M |

## Method

Everything below can be re-run; raw outputs of this run are in the task folder `cmp/` (outside the repo), driven by `cmp/run.sh`.

1. `scripts/forms_compare.py` (`python3 -I -B`, stdlib only, tested by `test/scripts/forms_compare_test.exs`):
   - `summary FILE.docx` for page setup, margins, fonts and sizes, tables with grid widths, merged cells, header rows;
   - `diff REF.docx GEN.docx` per form: ref = `template_application_ru<annex>.docx`, gen = `<Form>_ru.docx` and `<Form>_kk.docx`;
   - `text GEN.docx adilet-kk-562-text.txt --from "<N>-қосымша " --to "<N+1>-қосымша "` for kk wording.
2. PDF facts of the generated PDFs: `pdfinfo` (page size, pages), `pdffonts`, `pdftotext -layout`. Reference templates and
   generated PDFs were rendered to PNG with the LibreOffice flatpak already installed on the host
   (`--headless --convert-to pdf`) and `pdftoppm -r 50`; Z-3, Inv-10 (and the first pages of the others) were opened and
   compared by eye.
3. The three owner downloads were compared with the QA samples with `diff`.
4. Nothing was installed and no template was copied: the folder was mounted read only into the flatpak sandbox and
   the PDFs and PNGs were written to the task folder.

## Limits

- kk has no layout reference, only the Adilet text; kk layout is assumed equal to ru (one layout file).
- LibreOffice renders `.docx` differently from Word; pixel positions were not compared, structure was.
- Data values (names, numbers, dates of the QA sample) are ignored; the report quotes none.
- The PDF page counts of the ten samples (3 forms one page, 7 forms two pages) are driven by the footer and the 9-decimal
  wrap; they were not compared with the templates' page counts (1 to 3 pages) beyond the above.
- Z-2 and Z-3 and Inv-10 were compared page by page with the PNGs; the others from the script output and text of the PDFs.
- Widths are compared as shares of the table width, the template tables being portrait-width.
