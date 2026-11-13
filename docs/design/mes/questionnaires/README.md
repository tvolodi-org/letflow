# MES client questionnaires

Two workbooks: the chemical plant one (RU + EN, T-1834) and the electronics one (RU, T-1833).

## Chemical plant questionnaire (RU + EN)

File: `chemical-questionnaire-ru-en.xlsx`, one workbook for a prospect chemical plant.

### Sheets

| Sheet | Content |
|---|---|
| `Instruction RU`, `Instruction EN` | Purpose, how to fill in (about 45 minutes), unit rule, short glossary (batch, lot, SSCC, PLC, SCADA, historian, QC, ERP) |
| `Вопросы RU`, `Questions EN` | 53 questions, same numbering in both. Columns: number, section, question, answer type, answer, comment |

Twelve sections: products and volumes, sites and lines, tanks and flows, granular batches, bagging and pallets, quality and release, records and authorities, recall, machines and data, ERP and accounting, users and languages, goals.

Layout: wrapped text, set column widths, frozen header row, A4 landscape, fit to one page wide.

### Sources

- The 15 questions of `docs/design/mes/08-owner-decision-paper.md`, section 5.
- Client questions in `docs/design/mes/02-liquid-streams-options.md` section 7 and `docs/design/mes/03-granular-batch-options.md` section 7.
- Physical-data questions added at the owner's request (2026-11-13): density, units (kg, litres, tonnes) and conversions, tank volumes and big-tank/small-tank ratio, package sizes and their conversions (for example big bag = middle bags = 1 tonne).

### How it was made

`make_questionnaire.py` (this folder) writes the workbook with the Python standard library only (`zipfile` and XML strings); no new dependency. Run: `python3 make_questionnaire.py chemical-questionnaire-ru-en.xlsx`. Text lives in the script; edit it and run again.

Checked by reopening the file: four sheet names as above, 54 rows (header plus 53) in both question sheets, 18 rows in both instruction sheets.

### Rules for this file

The file is for the client: no internal labels, no options or recommendations of ours, no price, no dates, no promise. The owner sends it; nothing is sent from the repository. The Russian and English texts were written by the analyst and have not been read by a native speaker of either; a quick read before sending is advised. Not opened in Excel or LibreOffice on this host, only reopened and parsed with the standard library.

## Electronics questionnaire (Russian, XLSX)

`electronics-questionnaire-ru.xlsx` is the client-facing Russian version of Part A of
`docs/design/mes/04-electronics-questionnaire-and-sketch.md` (task T-1833). The owner sends it;
nothing was sent by the team.

### How it was made
- Translated by hand from the 16 questions of Part A. Question numbers 1 to 16 are the same as in
  the English source, so answers map back one to one. Multi-part questions stay one row.
- Left out on purpose, because the file is for the client: the "Why we ask" column, the call rules,
  everything from Part B (our sketch, options, guesses), internal labels, the client name, prices, dates.
- Sheets: `Инструкция` (who fills it, why, how, "nothing here is a price or date promise",
  time, confidentiality) and `Вопросы` (columns №, Раздел, Вопрос, Тип ответа, Ответ, Комментарий).
  Text wraps, columns have fixed widths, the header row is frozen and repeats on each printed page,
  page is A4 landscape, fit to one page wide.
- Written with the Python standard library only (`zipfile` and hand-written SpreadsheetML), no new
  dependency and no install. The generator script is not kept in the repository; to change the
  text, edit the file in a spreadsheet program.
- Checked by reopening: every part parses as XML, the workbook lists the two sheets, `Вопросы` has
  one header row and 16 question rows numbered 1 to 16. It was not opened in Excel or LibreOffice
  (neither is on this host), so print layout is not visually checked.

### Wording choices to review
- Question 16 (decision) keeps the source's three parts (who decides, budget and date, other
  solutions) in neutral words. Remove the budget or other-solutions part before sending if the owner prefers.
- Terms: BOM is kept as "спецификация (BOM)", routing as "маршрут", rework as "доработка / ремонт",
  serial number as "серийный номер", test station as "станция тестирования".
