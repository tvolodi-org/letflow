# Official forms audit: stock and asset documents (T-1906, 2026-11-13)

Written by the business analyst for the owner's paperwork walk (PM, 2026-11-13). Docs only: no code, no route, no
screen changed. The decision note for this task is `docs/uat/ba-decisions/T-1906.md`.

## Summary in plain English

Letflow prints **five official forms**, all from the stock module: the issue invoice (З-2), the internal movement
invoice (З-5, for a stock transfer only), the stock card (З-3), and the two count forms (Инв-10 count list, Инв-18
comparison sheet). They come in Russian and Kazakh, as PDF and Word (.docx). There is **no English** official form: an
English screen prints the Russian form. Every other document type has either a plain draft act (not an official form)
or **no printout at all**:

* A **goods receipt has no printout at all**, so the warehouse receipt order (Приходный ордер, form З-1, annex 25) does
  not exist yet. The owner's example is confirmed.
* **Write-off, opening balance, count posting and every asset document print nothing.** The asset screens have no
  print button of any kind; the asset module has no print route.
* Transfer, hand over and return print a plain "act" (Акт перемещения / передачи / возврата) in ru, kk and en, which
  says in its own code that it is a machine draft, not an official form.
* One wrong label: the Kazakh menu calls the Z-2 form **"Ж-2 нысаны"**. The correct Kazakh code is **Қ-2** (the printed
  form itself says Қ-2).
* The **Print templates** admin screen does **not** change any of these forms: it edits overrides that reach only the
  generic document renderer, and the stock and count prints do not use that renderer. A tenant cannot adjust an
  official form today. The screen's page title is in English only.

How this was checked: by reading the code on `origin/main` at commit `a7f2410ba` (2026-11-13). **No click in the QA
app was made in this step** (the BA step has no signed-in QA browser session; see "Verification" below). Every "V" in the
table means verified in the code and file named in section 2; "G" means a proposal or guess, to be confirmed.

| Document type (module) | Official form it needs (ru) | Printout today (backend) | Visible print button (web) | Languages | Format | Defects / gap |
|---|---|---|---|---|---|---|
| Receipt (stock) | **З-1 Приходный ордер запасов** (annex 25) | **none** V | **none** V | none | none | the owner's example: no receipt order; no print at all |
| Issue (stock) | З-2 Накладная на отпуск запасов на сторону (annex 26) | З-2 / Қ-2 official form V; no plain act V | "Официальная форма" menu → "Форма З-2" (issued or posted only) V | ru, kk (en UI prints ru) V | PDF, .docx V | kk menu label "Ж-2" wrong (must be Қ-2) V; price/VAT blank (REQ-778 not built) V; recipient blank (G3) |
| Write-off (stock) | З-6 Акт списания запасов (annex 30) | **none** V | **none** V | none | none | no print; commission of Z-6 not built (REQ-776) V |
| Transfer (stock) | З-5 Накладная на внутреннее перемещение запасов (annex 29) | plain act V and З-5 / Қ-5 V | "Печать (PDF)" button and "Официальная форма" → "Форма З-5" (issued, posted, reversed) V | act ru/kk/en; З-5 ru/kk V | act PDF; З-5 PDF, .docx V | act is a machine draft (moduledoc) V; basis, price, signers blank |
| Hand over to a person (stock) | З-5 proposed (Q19, open) G | plain act only V | "Печать (PDF)" V; no official form V | ru/kk/en V | PDF V | no official form; З-5 refused with `print_not_available` V |
| Return (stock) | З-5 proposed (Q19, open) G | plain act only V | "Печать (PDF)" V; no official form V | ru/kk/en V | PDF V | as hand over |
| Opening balance (stock) | no primary form in order No. 562; nearest is А-1/С-1 Бухгалтерская справка (annex 51) G, to be confirmed by an accountant | **none** V | **none** V | none | none | no print |
| Count order (stock) | no annex in order No. 562: the order (приказ) is the organisation's own free form G, to be confirmed by an accountant | plain PDF V; xlsx V | "Печать приказа (PDF)", "Скачать приказ (xlsx)" on the count screen V | ru/kk/en V | PDF, xlsx V | machine-draft wording (moduledoc) V |
| Count sheet / inventory list (stock) | Инв-10 Инвентаризационная опись запасов (annex 41) | plain PDF V; xlsx V; Инв-10 / Түг-10 V | "Печать ведомости (PDF)", "Скачать ведомость (xlsx)", "Официальная форма" → "Форма Инв-10" (once the sheet is issued) V | plain ru/kk/en; form ru/kk V | PDF, xlsx, .docx V | prices, sums, accounts, actual start/end blank (G5, G6, G12) |
| Differences / matching list (stock) | Инв-18 Сличительная ведомость результатов инвентаризации запасов (annex 49) | plain PDF V; xlsx V; Инв-18 / Түг-18 V | "Печать расхождений (PDF)", "Скачать расхождения (xlsx)", "Официальная форма" → "Форма Инв-18" (once differences are issued) V | plain ru/kk/en; form ru/kk V | PDF, xlsx, .docx V | sums, accounts, regrading blank (G5, G6, G15); PDF splits the 14 columns into two tables V |
| Count posting (stock, type `count.posting`) | no primary form; nearest А-1/С-1 Бухгалтерская справка (annex 51) G, to be confirmed by an accountant | **none** V | **none** V | none | none | no print |
| Count worksheet (new) | not a document type on main | n/a | n/a | n/a | n/a | queued separately by the operator; not repeated here |
| Commission protocol | not a document type on main V; the commission's result is printed on Инв-10 (count), and is asked for on З-6 and ДА-3 (write-offs) | n/a | n/a | n/a | n/a | no separate document; see REQ-776, REQ-777 |
| Stock movements / stock card (stock) | З-3 Карточка учета запасов (annex 27) | З-3 / Қ-3 V; movements and balances xlsx V | "Официальная форма" → "Форма З-3" on the balances screen, enabled once an item and a place are chosen V; "Выгрузить в Excel" xlsx V | form ru/kk; xlsx en-keyed V | PDF, .docx, xlsx V | header is plain lines, not the official multi-cell layout V; counterparty blank |
| Stock balances (stock) | З-7 Ведомость учета остатков запасов на складе (annex 31) | xlsx only V | "Выгрузить в Excel" ("Export to Excel") on the balances screen V | xlsx | xlsx | no З-7 form |
| Commissioning (asset, `commission`) | ДА-1 Акт приемки-передачи долгосрочных активов (annex 16) G (mapping: hand over "and commissioning") | **none** V | **none** V | none | none | no asset print route at all |
| Change of responsible or user (asset, `change`) | ДА-4 Накладная на внутреннее перемещение долгосрочных активов (annex 19) G | **none** V | **none** V | none | none | as above |
| Hand over (asset, `handover`) | ДА-1 (annex 16) between organisations, ДА-4 (annex 19) inside one G (Q21 open) | **none** V | **none** V | none | none | as above |
| Write-off (asset, `writeoff`) | ДА-3 Акт на выбытие (списание) долгосрочных активов (annex 18) | **none** V | **none** V | none | none | commission of ДА-3 not built (REQ-777) V |
| Change of kind (asset, `kind_change`) | no form in order No. 562; nearest А-1/С-1 Бухгалтерская справка (annex 51) G, to be confirmed by an accountant | **none** V | **none** V | none | none | not in the forms mapping before this audit |
| Opening (asset, `opening`) | no primary form; nearest А-1/С-1 Бухгалтерская справка (annex 51) G, to be confirmed by an accountant | **none** V | **none** V | none | none | no print |
| Asset card (asset) | ДА-2 Инвентарная карточка учета долгосрочных активов (annex 17) | **none** V | **none** V | none | none | many card fields missing (G11) |
| Asset movements / balances (asset) | none (reports); the card history belongs on ДА-2 G | balances xlsx V; movements JSON only V | export button (`assets.balances.export`) on the asset balances screen V | xlsx | xlsx | no form |
| Asset count sheet (asset) | Инв-8 Инвентаризационная опись долгосрочных активов (annex 39) | not built (REQ-816 to REQ-822, K6 = REQ-821) V | none | none | none | already registered: not repeated as a slice |
| Asset differences (asset) | Инв-16 Сличительная ведомость ... долгосрочных активов (annex 47) | not built V; not in REQ-816 to REQ-822 (`asset-count.md` section 7) V | none | none | none | no requirement yet |

## 1. Scope and method

* Document types: every `key` in `@document_types` of `lib/letflow/modules/stock/stock.ex` (`stock_receipt`,
  `stock_opening`, `stock_issue`, `stock_writeoff`, `stock_transfer`, `stock_handover`, `stock_return`, `count.order`,
  `count.sheet`, `count.differences`, `count.posting`) and of `lib/letflow/modules/assets/assets.ex` (`assets_commission`,
  `assets_change`, `assets_handover`, `assets_writeoff`, `assets_kind_change`, `assets_opening`). Commands:
  `grep -n 'kind: "' lib/letflow/modules/stock/documents/kinds.ex lib/letflow/modules/assets/documents/kinds.ex` and
  `grep -rln 'number_prefix' lib/letflow/modules` (the only other hit is procurement's purchase request, outside stock
  and assets and held by the owner's 2026-10-31 direction).
* Reports with an official form (stock card, balances, asset card) are rows too, because the forms ask for them.
* The form names, numbers and gap ids (G1 to G17, Q1 to Q22) come from `docs/assets/kz-forms-mapping.md` (sections 2,
  3.1 to 3.7, 8.5). The legal source of every annex is Order of the Minister of Finance of the Republic of Kazakhstan
  No. 562 of 20 December 2012 (forms of primary accounting documents), as that file records. Form numbers added by this
  audit (rows with "nearest А-1/С-1" or "free form") are proposals: **to be confirmed by an accountant**.
* The receipt order (З-1, annex 25) **was already in the mapping** (section 3.4, section 8.5 row 25) but it was never
  built; it was not missing from the mapping, it is missing from the product.

## 2. Evidence per finding (what was read)

| Finding | Source on origin/main |
|---|---|
| Print routes of the stock module: `GET /documents/:id/print` (plain act; with `form=z2` or `form=z5` the official form), `GET /stock-card/print` (З-3), `GET /counts/:id/print/:kind` (plain; with `form=inv10` / `form=inv18` the official form), `GET /counts/:id/paperwork/:kind` (xlsx) | `lib/letflow/modules/stock/router.ex` (route table in the moduledoc; `authz_get` lines) |
| Official forms served: `"z2" => {["issue"], ...}`, `"z5" => {["transfer"], ...}`; another kind is 422 `print_not_available` | `lib/letflow/modules/stock/router.ex`, `@document_forms` |
| Plain act only for `transfer`, `hand_over`, `return`; titles "Акт перемещения", "Акт передачи", "Акт возврата"; "Not an official form ... machine draft" | `lib/letflow/modules/stock/document_print.ex` (`build/3` guard, `@labels`, moduledoc) |
| Count plain prints are a machine draft | `lib/letflow/modules/stock/count_print.ex` moduledoc |
| Layouts of the five official forms | `priv/print_forms/z2.json`, `z3.json`, `z5.json`, `inv10.json`, `inv18.json`, `messages.json` |
| English refused by the official forms (`invalid_lang`) | `docs/assets/kz-forms-mapping.md` 6.1; web `officialFormLang/1` sends kk for a Kazakh UI and ru otherwise (`web/src/modules/stock/forms/officialForms.ts`) |
| Asset module has no print route; only `GET /balances?format=xlsx` | `lib/letflow/modules/assets/router.ex` (`authz_get`/`authz_post` lines, `format/1`) |
| Asset screens have no print button | `grep -rln -i 'print\|Printer' web/src/modules/assets` finds only `useAssetsWrite.ts`, and its hits are the word "fingerprint" |
| Stock document screen: "Печать (PDF)" shown when `documentPrintable` (transfer, hand_over, return in issued, posted, reversed); menu "Официальная форма" with З-2 for an issued or posted issue and З-5 for a printable transfer | `web/src/modules/stock/documents/DocumentsWorkspace.tsx`, `documentsModel.ts` (`PRINT_KINDS`, `PRINT_STATES`, `documentHasZ5`), `forms/officialForms.ts` (`formsForDocument`) |
| Count screen buttons per issued paperwork: xlsx download, plain PDF print, official form menu (Инв-10 needs the sheet, Инв-18 the differences) | `web/src/modules/stock/counts/PaperworkButtons.tsx`, `countsModel.ts` (`paperworkAvailable`), mounted in `CountDetail.tsx` |
| Balances screen: "Export" xlsx and the З-3 menu, disabled until an item and a place are chosen | `web/src/modules/stock/register/BalancesPage.tsx` |
| Labels en / ru / kk: "Print (PDF)" / "Печать (PDF)" / "Басып шығару (PDF)"; "Official form" / "Официальная форма" / "Ресми нысан"; kk "Ж-2 нысаны" | `web/src/modules/stock/documents/documentsMessages.ts`, `web/src/modules/stock/forms/officialFormMessages.ts`, `web/src/modules/stock/counts/countsMessages.ts` |
| The printed Z-2 says "Қ-2 нысаны" in kk | `priv/print_forms/messages.json` (grep `Қ-2`) |
| Print templates: overrides are pinned at issue and rendered only by `Letflow.Documents.attach_artefact/2` through `OverrideRender`; the stock and count prints build their layout in code or from `priv/print_forms` and never read an override; every stock and asset type registers `declared_fields: %{}`, so an override layout has no declared field to show | `lib/letflow/documents.ex` (`issue/2` doc), `lib/letflow/documents/override_render.ex`, `lib/letflow/documents/renderers.ex` (`@renderers []`), `lib/letflow/modules/stock/stock.ex` and `assets/assets.ex` (`declared_fields: %{}`); `grep -rln override lib/letflow/modules/stock lib/letflow/documents/form_print* lib/letflow/modules/assets` prints nothing |
| Print templates screen title is English only: `<PageLayout title="Print templates">` (the left menu entry is translated: "Шаблоны печати" / "Басып шығару үлгілері") | `web/src/pages/admin/PrintTemplatesPage.tsx`, `web/src/components/layout/navMessages.ts` |
| Write-off commission, asset write-off commission and issue price/VAT not built | `lib/letflow/modules/stock/documents/shape.ex` (`@line_extra` only for receipt; no commission field), `git log origin/main --grep` finds no merge for #3997, #3996, #3995 (REQ-776, REQ-777, REQ-778) |
| Asset count and its Inv-8 print are planned, not built | `docs/assets/asset-count.md` (status line, section 7, section 9) |

## 3. Defects found (not fixed here; docs only)

| # | Defect | Where | Severity |
|---|---|---|---|
| D1 | No printout of a stock receipt: the warehouse receipt order З-1 / Қ-1 (annex 25) does not exist | stock print route, receipt screen | major |
| D2 | Kazakh menu label of Z-2 is "Ж-2 нысаны"; the Kazakh code is Қ-2 (section 3.7 of the mapping; the print says Қ-2) | `web/src/modules/stock/forms/officialFormMessages.ts` | minor |
| D3 | No printout of a stock write-off (З-6), opening, or count posting | stock print route, document screen | major (З-6), minor (others) |
| D4 | No print route and no print button for any asset document (commissioning, change, hand over, write-off, change of kind, opening) or the asset card (ДА-2) | `lib/letflow/modules/assets/router.ex`, `web/src/modules/assets` | major |
| D5 | Hand over and return print only the machine-draft act; no official form (Q19 open) | `document_print.ex`, router form map | minor until Q19 is answered |
| D6 | The З-2 menu appears for issued and posted issues but not for reversed ones, while the З-5 menu and the act also appear for reversed documents | `formsForDocument` versus `documentPrintable` | minor (inconsistent) |
| D7 | The Print templates screen cannot change any official form or act (overrides do not reach module prints), and its title is English only | `PrintTemplatesPage.tsx`; override path in `documents.ex` | minor (title); the capability gap is an owner question (section 5) |
| D8 | Unused message ids `stock.balances.cardPdf`, `stock.balances.cardDocx` (en/ru/kk) left after the З-3 button moved into the menu | `web/src/modules/stock/stockMessages.ts` (no `.tsx` reads them) | minor (clean-up) |
| D9 | З-3 header is a list of plain lines, not the official multi-cell header | mapping section 7 | minor |

## 4. Prioritised slice list

Each slice is one form or one screen family: backend print, web button, browser test. "Browser test" means a
Playwright e2e that opens the screen by clicking (no typed URL), presses the button and checks the downloaded file
type and title; a router test with a real token proves the route as the З-2 and З-5 tests do
(`test/letflow/modules/stock/form_z5_router_test.exs`). Blank cells for every gap, never invented values (mapping
section 2 default).

| Order | Slice | Backend | Web | Test | Waits on |
|---|---|---|---|---|---|
| 1 | **З-1 / Қ-1 receipt order** (annex 25) for an issued or posted receipt | `form=z1` on `GET /documents/:id/print`, layout `priv/print_forms/z1.json` (planned, not yet on main), ru from the 2026 draft, kk from the Adilet text; filled: organisation and BIN, number, date (`event_time`, `received_on`), warehouse (`location_id`), supplier (`counterparty_id` name, `tax_id`), accompanying document (`supplier_document_ref`), lines (item, code, unit, quantity, `unit_price`, `line_value`), "Принял" = `responsible_id`; blank: account, payment document, quantity by document, mass, passport, card entry, "Сдал" | "Официальная форма" → "Форма З-1" / "Қ-1 нысаны" / "Z-1 form" on the receipt screen | router test ru/kk pdf/docx; e2e click | none |
| 2 | **Print button on every stock document screen** | plain act for receipt, issue and write-off in `document_print.ex` (ru/kk/en), same issued-version rule | "Печать (PDF)" shown for every stock kind once issued; fix D6 (same states for all menus); fix D2 (Қ-2) | model unit test of the kind/state table; e2e on receipt and write-off | none |
| 3 | **З-6 / Қ-6 stock write-off act** (annex 30) | `form=z6`; commission block blank until REQ-776 is built | menu entry on the write-off screen | router test; e2e | none (commission fills in later with REQ-776) |
| 4 | **Asset document plain act + print button** (commission, change, hand over, write-off) | new `GET /documents/:id/print` in the assets router, permission `AssetsRead`, plain act ru/kk/en | "Печать (PDF)" on the asset document screen | router test with a real token, incl. a cross-tenant negative test (another tenant's document id answers 404, INV-5); e2e | none; needs a security review (new tenant-data read route) |
| 5 | **ДА-1 / ҰМА-1** for asset commissioning and hand over (annex 16) | `form=da1` on the slice 4 route | menu entry | router test; e2e | slice 4; Q21 (inter-organisation) stays blank |
| 6 | **ДА-4 / ҰМА-4** for change of responsible and internal hand over (annex 19) | `form=da4` | menu entry | router test; e2e | slice 4; Q22 (which cost) |
| 7 | **ДА-3 / ҰМА-3** asset write-off act (annex 18) | `form=da3`; commission blank until REQ-777 | menu entry | router test; e2e | slice 4 |
| 8 | **ДА-2 / ҰМА-2** asset card (annex 17) | card print route | button on the asset card screen | router test; e2e | none |
| 9 | **З-7 / Қ-7** stock balances sheet (annex 31) | from the balances read | menu entry on the balances screen | router test; e2e | none |
| 10 | **Print templates screen**: translate the title (ru/kk/en) and say on the screen which documents it affects | none | `PrintTemplatesPage.tsx` | unit test | none; whether tenants may adjust official forms is an owner question (section 5) |
| 11 | **Hand over and return on З-5** | add the kinds to the `z5` entry | menu entry | router test; e2e | owner answer to Q19 |
| 12 | Бухгалтерская справка (annex 51) for openings, count posting and change of kind | one generic form | menu entry | router test; e2e | an accountant confirms the form is the right one |

Not in this list on purpose: the count worksheet (queued separately by the operator), the asset count and its
Инв-8 print (REQ-816 to REQ-822), Инв-16 (asset differences, no requirement yet: add one after REQ-819), the money
columns of every form (Q5, REQ-778 for З-2), and the forms whose Letflow document is "none" (mapping 8.5).

## 5. Open questions for the owner (not decided here)

* Q19 (from the mapping): may hand over and return print on З-5?
* Should a tenant be able to adjust an official form (wording, logo, extra lines) through Print templates? Today it
  cannot (D7); decision 0068 governs overrides of the generic renderer, not the module forms.
* An accountant confirms: З-1 for every receipt (also a receipt with no supplier); Бухгалтерская справка for openings,
  count posting and change of kind; ДА-1 for commissioning; the count order as the organisation's own free form.

## Verification

* Code: read on `origin/main` at `a7f2410ba`, 2026-11-13; the paths are in section 2.
* QA click-through: **not done in this step**. The BA write step has no signed-in QA browser and must not probe routes.
  The button rows above are therefore "V" from the web code, not from a click. A UAT scenario (`uat_design`) can walk
  the screens on QA after slices 1 and 2 land.
