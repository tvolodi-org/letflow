# Chemical plant questionnaire (RU + EN)

File: `chemical-questionnaire-ru-en.xlsx`, one workbook for a prospect chemical plant.

## Sheets

| Sheet | Content |
|---|---|
| `Instruction RU`, `Instruction EN` | Purpose, how to fill in (about 45 minutes), unit rule, short glossary (batch, lot, SSCC, PLC, SCADA, historian, QC, ERP) |
| `Вопросы RU`, `Questions EN` | 53 questions, same numbering in both. Columns: number, section, question, answer type, answer, comment |

Twelve sections: products and volumes, sites and lines, tanks and flows, granular batches, bagging and pallets, quality and release, records and authorities, recall, machines and data, ERP and accounting, users and languages, goals.

Layout: wrapped text, set column widths, frozen header row, A4 landscape, fit to one page wide.

## Sources

- The 15 questions of `docs/design/mes/08-owner-decision-paper.md`, section 5.
- Client questions in `docs/design/mes/02-liquid-streams-options.md` section 7 and `docs/design/mes/03-granular-batch-options.md` section 7.
- Physical-data questions added at the owner's request (2026-11-13): density, units (kg, litres, tonnes) and conversions, tank volumes and big-tank/small-tank ratio, package sizes and their conversions (for example big bag = middle bags = 1 tonne).

## How it was made

`make_questionnaire.py` (this folder) writes the workbook with the Python standard library only (`zipfile` and XML strings); no new dependency. Run: `python3 make_questionnaire.py chemical-questionnaire-ru-en.xlsx`. Text lives in the script; edit it and run again.

Checked by reopening the file: four sheet names as above, 54 rows (header plus 53) in both question sheets, 18 rows in both instruction sheets.

## Rules for this file

The file is for the client: no internal labels, no options or recommendations of ours, no price, no dates, no promise. The owner sends it; nothing is sent from the repository. The Russian and English texts were written by the analyst and have not been read by a native speaker of either; a quick read before sending is advised. Not opened in Excel or LibreOffice on this host, only reopened and parsed with the standard library.
