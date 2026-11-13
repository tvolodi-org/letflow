# Electronics questionnaire (Russian, XLSX)

`electronics-questionnaire-ru.xlsx` is the client-facing Russian version of Part A of
`docs/design/mes/04-electronics-questionnaire-and-sketch.md` (task T-1833). The owner sends it;
nothing was sent by the team.

## How it was made
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

## Wording choices to review
- Question 16 (decision) keeps the source's three parts (who decides, budget and date, other
  solutions) in neutral words. Remove the budget or other-solutions part before sending if the owner prefers.
- Terms: BOM is kept as "спецификация (BOM)", routing as "маршрут", rework as "доработка / ремонт",
  serial number as "серийный номер", test station as "станция тестирования".
