# Print and export check against real paper (T-1555, 2026-11-09)

BA batch 2, item 3. Layout only: no official-form wording, column set, route, permission or
dependency changed. Method: `scripts/print_probe.exs` builds the stock act (90 lines, ru/kk/en),
every official form (ru/kk, PDF and .docx) and a 30-code label sheet with the production
renderers; PDFs are read with `pdftotext -layout`, `pdfinfo`, `pdffonts`; .docx files are
converted with LibreOffice:

    MIX_ENV=test PROBE_OUT=<dir> mix run --no-start scripts/print_probe.exs
    flatpak run --user --filesystem=<dir> org.libreoffice.LibreOffice --headless \
      --convert-to pdf --outdir <dir>/conv <dir>/form-inv18-ru.docx

## Defects found and fixed

| # | Defect (before) | Fix | After |
|---|---|---|---|
| P1 | Table header not repeated on page 2+ (90-line act: page 2 began at row 35 without a header) | `PrintLayout.Flow`: header repeated on each new page of a table | act pages 2 and 3 begin with `№ Номенклатура Партия Ед. изм. Количество` |
| P2 | Signature heading stranded at a page foot; signer table cut across pages; header alone at a page foot | `Flow`: a text block directly before a table moves with it; a table of up to 3 rows is kept whole; header plus first row never separate | tests F4, F4b, F4c |
| P3 | Narrow column broke a header word mid-word; wide official forms cut into portrait A4 | `Flow`: column widths honour the longest header word when all can fit; `A4-landscape` page size, used by `FormPrint.Pdf` for tables over 7 columns | Z-2, Z-5, Inv-10, Inv-18 PDFs are 842 x 595 pt |
| P4 | .docx: header rows not repeated, rows split across pages | `w:tblHeader` on header and number rows, `w:cantSplit` on every row, `w:keepNext` on the signature line, header cells 7 pt, narrower name column | Inv-18 ru in LibreOffice: page 2 begins with the header and the number row |
| P5 | Acts printed ISO times and raw quantities in every language | `CountPaperwork.print_time/4` and `number/2` | ru/kk `01-11-2026 10:00 (UTC+00:00)`, `1 234,500` (no-break space); en `2026-11-01 10:00 (UTC+00:00)`, `1,234.500`; every stored digit kept |
| P6 | .xlsx: no widths, plain header, no frozen header | `Documents.XlsxStyle`: bold header, frozen first row, widths from the content (8 to 60 characters) | asset balances, stock balances/movements, count paperwork |

Page counts after: act 3 pages in ru/kk/en; Inv-18 PDF 6 pages, Inv-18 .docx (LibreOffice) 3 pages (was 4);
labels 30 codes = 2 pages (24 per page).

Fonts: DejaVu Sans is embedded (`pdffonts`: emb yes, uni yes) and draws every Kazakh letter
(`әіңғүұқөһ`, `ЁЙ`).

## Known limits (not fixed here)

- Fixed in T-1612: the Inv-18 .docx header word `Номенклатурный` no longer breaks (column widths follow the
  longest header word); a printed .xlsx repeats its header row on every page (print titles, landscape,
  fit to width, `XlsxStyle.write_to_memory/2`); official form PDFs carry "Страница N из M" / "Бет N / M".
- Asset documents have no print route on main (`lib/letflow/modules/assets/router.ex`): a printable
  asset-document form is a separate feature. The asset side of this check is the balances .xlsx and
  the label sheet.
- "Signature block on every page" is read as: header repeats on every page, signature block printed
  once at the end and never split or stranded.
