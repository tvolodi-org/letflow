# KZ Ministry of Finance forms: mapping to Letflow documents and data

Status: analysis, not built (assets phase E item E5a, owner decision D-104). Docs only: no code, no migration, no
definition JSON, no print template, no route, no screen. A later build of any official form is a later requirement
written from this file after the owner has answered the questions in section 4.

## 0. Sources and caveats

* Layout source (owner D-104): the 2026 **draft** forms of the Ministry of Finance of the Republic of Kazakhstan,
  the annexes to order No. 562 of 20 December 2012 as the draft amending order has them. The folder is
  `/home/tvolodi/Documents/KZ-MinFin-DocTemplates/` (read only; the files are not copied into this repository).
  The catalog is `ai-dala-portfolio/inbox/kz-minfin-forms/CATALOG.md` (with `forms.json`).
* The files in the folder are **Russian only** (41 of the 51 annexes). The official Kazakh text is known since
  2026-11-06: the owner saved the current edition of order No. 562 in Kazakh from Adilet (adilet.zan.kz/kaz/docs/V1200008265)
  with all 51 annexes; its plain-text extract is `ai-dala-portfolio/inbox/kz-minfin-forms/adilet-kk-562-text.txt` (read
  only, not copied here; see "Kazakh versions FOUND" in the catalog). Section 3.7 gives the Kazakh code and title of
  every form, section 3.8 the differences between the Russian 2026 drafts and the current Kazakh edition. The draft is
  not final: dates in the draft package are blank. **If the final order text differs from these drafts, this file must
  be redone; ask the operator.**
* The Kazakh wording for printing (labels, layout, signer lines) is taken **only from the official text**, never from
  machine translation. The existing E1a/E1b prints are machine drafts and are not that wording.
* Method: every form was opened with a script (python3, `zipfile` and `xml.etree`, standard library only, read only)
  and its header block, table columns (with the column numbers printed in the form), free-text blanks and signature
  lines were listed. The titles below are read from the files; the catalog has no title for Z-1, Z-4, Z-6 and Z-7,
  the files give them (section 3.4).
* Letflow facts come from `docs/assets/stock-workflow-documents.md`, `docs/assets/asset-workflow-documents.md`,
  `docs/assets/asset-register.md`, `docs/assets/government-lists.md`, the entity definitions under
  `priv/modules/*/entity_definitions/`, and the print code of E1a/E1b
  (`lib/letflow/modules/stock/count_print.ex`, `document_print.ex`, `document_print_source.ex`).
* Section 8 (T-1453, owner decisions of 2026-11-07) gives every one of the 51 forms its checked ru/kk code pair, its
  BIN/IIN source, its signer rule and its VAT rule, or the requirement registered for the gap (REQ-776 to REQ-778);
  it settles G1 for printing and the signer and VAT parts of G4 and G5 that decisions (b) to (d) cover.
* Marks: **proposal** = the business analyst's proposal; **default** = what the print does until the owner answers
  (always: leave the field blank, never invent a value). No answer is given here to any owner question.
* The forms are shown by their Russian names (Z = "З", Inv = "Инв", DA = "ДА"), as the catalog does. The Kazakh code
  of each form is in section 3.7: Z = Қ, Inv = Түг, DA = ҰМА, Т = Е, ОС = НҚ; КО, А, БА, С keep their letters;
  annex numbers are equal in ru and kk.

## 1. What Letflow has today (the data a form can be filled from)

| Need | Where it is | Column |
|---|---|---|
| Document number | the versioned document (`Letflow.Documents`) that `document_id` names; gap-free per type, assigned at issue | not a record column |
| Document date | stock header `event_time` (datetime, shown in the tenant time zone, default Asia/Almaty); receipt also `received_on`; count order `issued_at` | `stock_*.event_time` |
| Organisation unit and its legal entity | `org_unit` with `legal_entity_id` pointing to `org_legal_entity` | `org_legal_entity.name`, `org_legal_entity.bin` |
| Counterparty | `catalog_counterparty` | `code`, `name`, `kind`, `tax_id` |
| Employee, position | `org_employee` and `org_position` | `org_employee.full_name`, `code` (personnel code), `position_id`; `org_position.name` |
| Item, unit, lot | `catalog_item`, `catalog_uom`, `catalog_lot` | `catalog_item.code`, `name`, `base_uom_id`; `catalog_uom.code`, `name`; `catalog_lot.code`, `producer`, `mark`, `expiry_date` |
| Location | location tree (`location_node`) | name and code |
| Stock document header (receipt, issue, transfer, hand over, return, write off) | `stock_<kind>` records | `org_unit_id`, `location_id` or `from_/to_location_id`, `responsible_id` or `from_/to_responsible_id`, `to_org_unit_id`, `note`, `reason_code`, `reason_text`; receipt also `counterparty_id`, `supplier_document_ref`, `received_on` |
| Stock document line | `stock_<kind>_line` | `line_no`, `catalog_item_id`, `catalog_uom_id`, `catalog_lot_id`, `quantity`; receipt line also `unit_price`, `line_value` |
| Count | `count_order`, `count_commission_member`, `count_sheet_line`, `count_entry`, `count_signature` | order: `number`, `issued_at`, `planned_start`, `planned_end`, `cut_off_at`, `chair_employee_id`; line: `location_id`, `responsible_employee_id`, `catalog_item_id`, `catalog_lot_id`, `unit_ref`, `book_quantity`, `counted_quantity` |
| Asset card | `assets_card` | `inventory_number`, `name`, `kind`, `org_unit_id`, `acquisition_date`, `currency`, `acquisition_cost`, `accumulated_depreciation`, `book_value`, `depreciation_as_of`, `depreciation_method`, `depreciation_rate`, `valid_until`, `active` |
| Asset documents | commission, change of responsible or user, hand over, write off (specified in `asset-workflow-documents.md`) | `material_responsible_id`, `actual_user_id`, `from_/to_` pairs, `location_id`, `reason_code`, `reason_text` |

Print code today (E1a/E1b): a PDF in ru, kk and en for the count order, count sheet and differences sheet
(`CountPrint`), and for transfer, hand over and return (`DocumentPrint`, the issued version only). Both say in their
moduledocs that they are **not official forms** (machine-draft wording, decision 0068 D6). There is **no print**
for receipt, issue, write off, the stock card, or any asset document. Neither print shows a BIN, a position, a price
or an account number.

## 2. The gaps (common to many forms), with the question for the owner

Each gap has an id, used in section 3. The default is the same for all: **leave a blank line or cell for the value
(for a signer: a blank line), do not invent a value, do not print a wrong one.**

| Id | What the forms ask and Letflow does not have | Owner question (Q) | Default |
|---|---|---|---|
| G1 | **IIN** of an individual entrepreneur. The BIN exists (`org_legal_entity.bin`) but the print does not use it, and there is no IIN field; a tenant with several BIN has one per legal entity (D-062) | Q1 Is an individual entrepreneur a customer case (then an IIN field)? Which legal entity's BIN prints when a unit has none? | print `bin` of the unit's legal entity; blank if empty |
| G2 | **Name and details of the organisation** beyond `org_legal_entity.name`: address, bank details | Q2 Do the forms need the address? (none of the forms checked has an address field; the forms ask for the name and BIN/IIN only) | print the legal entity name; no address |
| G3 | **Recipient of an issue to a third party** (Z-2 "организация-получатель"): the issue document has no counterparty field (only receipt has `counterparty_id`) | Q3 Add a counterparty to the issue document? | blank cell |
| G4 | **Signers and their positions** ("Отпуск разрешил", "Главный бухгалтер", "Проверил", "Принял", "Утверждаю: руководитель"): a document holds the responsible employee(s) only; there is no chief accountant, approver or manager slot. A position is reachable through `org_employee.position_id` | Q4 Which roles sign each document, and are they chosen on the document or fixed per organisation? | the responsible employee is printed where the form asks for the person who hands over or receives (name and position from the employee); every other signer is a blank line |
| G5 | **Price, VAT and sums**: price only on the receipt line (`unit_price`, `line_value`); none on issue, transfer, hand over, return, write off, count lines, and no VAT field anywhere (money questions of `stock-workflow-documents.md` section 4) | Q5 Do the printed stock forms carry price and VAT, and where do they come from (last receipt, average, by lot)? Is VAT per line? | price, sum and VAT columns blank; "Итого" quantity only |
| G6 | **Account numbers** (счет, корреспондирующий счет, debit and credit) | Q6 Does the customer keep accounts in Letflow, or does the accountant write them on the paper? | blank cell |
| G7 | **Basis document** (name, number, date) of a movement or write off, and **supporting document numbers** (payment document, accompanying document, power of attorney, waybill / ТТН) | Q7 Which of these are fields on the document? Today: `supplier_document_ref` (receipt only), `note` (all) | basis printed from `note` if filled, else blank; the rest blank |
| G8 | **Transport**: transport organisation, vehicle, ТТН number and date (Z-2) | Q8 Does the customer issue goods to third parties by road with these forms? | blank |
| G9 | **Quantity "to release" and "released"** (Z-2, Z-5 columns 5 and 6): one `quantity` per line | Q9 Is there a planned quantity different from the issued one? | print `quantity` in "released" only; "to release" blank (proposal: same value in both is also possible) |
| G10 | **Amounts in words** (quantity and sum in words, in Russian and in Kazakh): not stored; a print-time computation | Q10 Are words required, and who checks the Kazakh wording? | blank "прописью" line; quantity digits in the totals row |
| G11 | **Fixed-asset attributes** that the asset card does not hold: factory (serial) number, passport / registration number, year of manufacture or construction, manufacturer, useful life, liquidation value, impairment loss, ownership sign (own or leased), precious materials, repairs, completion / modernisation history, revaluation history, internal movement history, characteristic elements and accessories, actual service life, date of the act of commissioning, debit and credit accounts | Q11 Which of these does the customer need on the card and on the acts? (the card has the inventory number and five money and date fields only; the model is not widened by a form, `government-lists.md` preamble) | blank |
| G12 | **Count attributes** not stored: actual start and end of the count (only `planned_start`, `planned_end`, `cut_off_at`), the number and date of the order shown inside the count form (the order number is `count_order.number`, date `issued_at`), the balance-sheet account the count covers, "from No. to No." of the sheet lines, goods in transit data (shipment and arrival dates, supplier, route, carriage number), shipped goods data (buyer, payment due date, measures taken), custody data (supplier, storage place, supporting document, reason) | Q12 Which count kinds are in scope (stock in transit, shipped, custody)? Is the actual start and end entered? | blank, or planned values where the form's field is "начата" and "окончена" (see 3.2) |
| G13 | **Stock card attributes** (Z-3): kind of production, brand (марка), sort, profile, size, shelf life, responsible for supply, structural unit, shop, executor, precious materials; the lot holds `producer`, `mark`, `expiry_date` | Q13 Which of these does the customer keep on the item? | `mark` from the lot, shelf life from `expiry_date`; the rest blank |
| G14 | **Write-off attributes** (Z-6): date of acquisition and service life per line, reason per line (the header has one `reason_code`), amounts written off at the cost of guilty persons and of the organisation, scrap (утиль) lines with a receipt order number, commission decision | Q14 Does the customer write off with a commission and scrap? | header `reason_code` and `reason_text` for every line; the rest blank |
| G15 | **Reconciliation of counts** (Inv-18): sums of surplus and shortage, accounting corrections (account, quantity, sum), regrading (пересортица: offsetting a surplus of one item against a shortage of another), final surplus and shortage | Q15 Does the customer need regrading and the accounting columns? | surplus and shortage **quantity** from `counted_quantity - book_quantity`; sums, accounts and regrading blank |
| G16 | **Kazakh wording of a printed form**: the official Kazakh text of all 51 annexes is now known (section 3.7, source `adilet-kk-562-text.txt`), but no print uses it yet; the existing prints are machine drafts, not official | Q16 Is the Adilet edition of order No. 562 (current) the wording to print, or the final text of the 2026 amending order once it is registered? Who checks a Kazakh print against the official text? | until a build copies the labels from the official text, a form prints in Russian and English only; Kazakh labels come from the official text, never from machine translation |
| G17 | **Stamp** ("М.П.") and **date next to each signature** | Q17 Are stamp and date lines kept on the paper? | printed as a blank mark |

Not a gap: **the number** of an item (nomenclature number) is proposed as `catalog_item.code`; **the unit** as
`catalog_uom.name`; **the signer name** as `org_employee.full_name`. The reading of "nomenclature number" is a
proposal (Q18: is the item code the nomenclature number the accountant expects?).

## 3. The forms

### 3.1 Z-2: issue invoice to a third party (annex 26) — complete

Title in the file: "Накладная на отпуск запасов на сторону", form Z-2. Letflow document: the **issue**
(`stock_issue` and `stock_issue_line`, `stock-workflow-documents.md` section 3). Not printed today.

| Block | Field on the form | Source in Letflow | Result |
|---|---|---|---|
| Top | Организация (индивидуальный предприниматель) | `org_unit_id` → `org_unit.legal_entity_id` → `org_legal_entity.name` | have |
| Top | ИИН / БИН | `org_legal_entity.bin`; IIN not stored | BIN have, IIN missing (G1) |
| Top | Номер документа | number of the versioned document | have |
| Top | Дата составления | header `event_time` in the tenant time zone | have |
| Parties | Организация - отправитель | same legal entity as the top; name of the org unit also available | have |
| Parties | Организация - получатель | no counterparty on the issue | **missing** (G3) |
| Parties | Ответственный за поставку (Ф.И.О.) | header `responsible_id` → `org_employee.full_name` | have |
| Parties | Транспортная организация | none | **missing** (G8) |
| Parties | Товарно-транспортная накладная (номер, дата) | none | **missing** (G8, G7) |
| Table col 1 | Номер по порядку | line `line_no` | have |
| Table col 2 | Наименование, характеристика | `catalog_item.name` (characteristic: lot `mark` / `code` only) | name have, characteristic partly |
| Table col 3 | Номенклатурный номер | `catalog_item.code` (proposal, Q18) | have |
| Table col 4 | Единица измерения | `catalog_uom.name` through line `catalog_uom_id` | have |
| Table col 5 | Количество, подлежит отпуску | none apart from `quantity` | **missing** (G9) |
| Table col 6 | Количество, отпущено | line `quantity` (decimal text unchanged) | have |
| Table col 7 | Цена за единицу, в теңге | not on the issue line | **missing** (G5) |
| Table col 8 | Сумма с НДС, в теңге | none | **missing** (G5) |
| Table col 9 | Сумма НДС, в теңге | none | **missing** (G5) |
| Table | Итого (quantity, sums) | quantity sum computed at print time; sums none | quantity have, sums missing (G5) |
| Words | Всего отпущено количество запасов (прописью), на сумму (прописью) | computed at print time | **missing** (G10, G5) |
| Signers | Отпуск разрешил (position, signature, name) | none | **missing** (G4); blank line |
| Signers | Главный бухгалтер (signature, name), М.П. | none | **missing** (G4, G17); blank line |
| Signers | Отпустил (signature, name) | header `responsible_id` (name, position) | have (name), signature by hand |
| Signers | По доверенности № … от … выданной … | none | **missing** (G7); blank |
| Signers | Запасы получил (signature, name) | none (receiver unknown, G3) | **missing**; blank line |

Not on the form but on our document: location (`location_id`), `reason_text`, lot code. The layout may show them
as a note; whether they belong on the official sheet is Q14b (owner: print the location? default: no).

### 3.2 Z-5: internal movement invoice (annex 29) — complete

Title: "Накладная на внутреннее перемещение запасов", form Z-5. Letflow document: the **transfer**
(`stock_transfer`, `stock_transfer_line`, section 5 of the stock spec). Proposal: the **hand over** (to a person)
and the **return** also print on Z-5, because the folder has no other movement form for stock: the receiving
unit is `to_org_unit_id` and the receiver is the employee in `to_responsible_id` (Q19: confirm). E1b prints these
three as an "act" today, not as Z-5.

| Block | Field on the form | Source in Letflow | Result |
|---|---|---|---|
| Top | Организация, ИИН / БИН | as Z-2 | name and BIN have, IIN missing (G1) |
| Header | Номер документа, Дата составления | versioned document number; `event_time` | have |
| Header | Структурное подразделение отправитель | `org_unit_id` → `org_unit.name` (with `from_location_id`) | have |
| Header | Структурное подразделение получатель | `to_org_unit_id` → `org_unit.name` (with `to_location_id`) | have |
| Header | Основание: наименование, номер, дата документа | none; `note` only | **missing** (G7) |
| Header | Ответственный за поставку (Ф.И.О.) | `from_responsible_id` → `full_name` | have |
| Table col 1 | Номер по порядку | `line_no` | have |
| Table col 2 | Наименование запасов, сорт, марка, размер | `catalog_item.name`; lot `mark`; sort and size none | name and mark have, sort and size missing (G13) |
| Table col 3 | Номенклатурный номер | `catalog_item.code` (Q18) | have |
| Table col 4 | Единица измерения | `catalog_uom.name` | have |
| Table col 5 | Количество, подлежит отпуску | none | **missing** (G9) |
| Table col 6 | Количество, отпущено | `quantity` | have |
| Table col 7 | Цена за единицу, в теңге | none on a transfer line | **missing** (G5) |
| Table col 8 | Сумма, в теңге | none | **missing** (G5) |
| Table | Итого | quantity computed at print time | quantity have, sum missing |
| Words | Всего отпущено количество (прописью), на сумму (прописью) | print-time | **missing** (G10, G5) |
| Signers | Отпуск разрешил (position, signature, name) | none | **missing** (G4) |
| Signers | Проверил (position, signature, name) | none | **missing** (G4) |
| Signers | Отпустил | `from_responsible_id` (name, position) | have |
| Signers | Получил | `to_responsible_id` (name, position) | have |

### 3.3 Inv-18: reconciliation sheet of stock count results (annex 49) — complete

Title: "Сличительная ведомость результатов инвентаризации запасов", form Inv-18. Letflow document: the **differences
sheet** of a count (`CountPrint` kind `differences`, built from `count_order`, `count_sheet_line`; E1a). The print
of E1a is not this form: it lists SKU, location, book and counted quantity and the signer set.

| Block | Field on the form | Source in Letflow | Result |
|---|---|---|---|
| Top | Организация, ИИН / БИН | as Z-2 | name and BIN have, IIN missing (G1) |
| Header | Номер документа | `count_order.differences_number` | have |
| Header | Дата составления | `count_order.differences_issued_at` | have |
| Title | "на «__» ___ 20__ года" (date of the count) | `count_order.cut_off_at` | have |
| Text | На основании приказа (распоряжения) от «__» ___ 20__ года | `count_order.number` and `issued_at` (the form asks date only) | have |
| Text | произведена инвентаризация фактического наличия запасов, находящихся на ответственном хранении (position, signature, name) | the responsible employee of the lines (`responsible_employee_id`); position through `position_id`; signature by hand | have (name, position) |
| Table col 1 | Номер по порядку | `line_no` | have |
| Table col 2 | Наименование, краткая характеристика | `catalog_item.name` | have |
| Table col 3 | Номенклатурный номер | `catalog_item.code` (Q18) | have |
| Table col 4 | Единица измерения | `unit_ref` → unit name | have |
| Table col 5 | Результаты инвентаризации, излишек: количество | `counted_quantity - book_quantity` when positive (`direction` surplus) | have (computed) |
| Table col 6 | Излишек: сумма, в теңге | no price on count lines | **missing** (G5) |
| Table col 7 | Недостача: количество | `book_quantity - counted_quantity` when positive (`direction` shortage) | have (computed) |
| Table col 8 | Недостача: сумма | none | **missing** (G5) |
| Table cols 9 to 14 | Отрегулировано за счет корректировок в бухгалтерском учете: излишек (количество, сумма, счет), недостача (количество, сумма, счет) | none | **missing** (G6, G15) |
| Table | Итого | quantities computed at print time; sums none | quantity have, sums missing |
| Back side cols 15 to 26 | Пересортица (offsetting), окончательные излишки и недостачи (quantity, sum, account) | none | **missing** (G15) |
| Signers | Бухгалтер (signature, name) | none | **missing** (G4) |
| Signers | Материально-ответственное лицо (position, signature, name), "с результатами сличения ознакомлен" | the responsible employee; or `count_signature` rows (`document_kind`, `signer_role`, `employee_id`, `marked_at`) | have (name, position) |

Note: the form's columns 5 to 14 are two column groups (surplus, shortage) of quantity and sum. The quantity half is
derivable; the money half is blocked by Q5. The form has no commission block: the count commission (`chair_employee_id`
and `count_commission_member`) belongs to the sheet Inv-10 (3.5).

### 3.4 Other stock forms (Z-1, Z-3, Z-4, Z-6, Z-7): title and field list

| Form | Title in the file | Letflow document | Fields the form asks (blank fields, columns) | We have | Missing |
|---|---|---|---|---|---|
| Z-1 (annex 25) | Приходный ордер ЗАПАСОВ | receipt (`stock_receipt`, `_line`) | org and BIN/IIN, warehouse; number, date, kind of operation, supplier name, corresponding account, accompanying document number, payment document number; lines: name, sort, size, brand; nomenclature number; unit; by document: quantity, mass; accepted: quantity, mass; price; sum; passport number (precious metals); card entry number; total; signers "Принял" and "Сдал" | number, date (`event_time`, `received_on`), warehouse (`location_id`), supplier (`counterparty_id` → name, `tax_id`), accompanying document (`supplier_document_ref`), item, unit, quantity, price (`unit_price`), sum (`line_value`), accepting employee (`responsible_id`) | corresponding account (G6), payment document number (G7), kind of operation, quantity by document versus accepted, mass, passport number, card entry number (G13), IIN (G1), "Сдал" signer (G4) |
| Z-3 (annex 27) | Карточка учета запасов | the stock balance and movements per item (ledger read, B2/B6); nothing printed today | header: unit, kind of production, brand, sort, profile, size, account, nomenclature number, unit, price, shelf life, responsible for supply; lines: date, document number, line number, from whom received or to whom issued, accounting unit of output, income, expense, balance, control (signature, date); precious materials | item code and name, unit, lot (`mark`, `expiry_date`), balance and movements by date (ledger entries with document references), counterparty for receipts | account, price (G5), kind of production, sort, profile, size (G13), accounting unit of output, control signature (G4), precious materials |
| Z-4 (annex 28) | Акт об оприходовании запасов, полученных при разборке и демонтаже основных средств | none: no stock document of this kind; nearest is a receipt with a reason | approver; number, date; unit, shop, section; number and date of the fixed-asset write-off act; lines: account, item, nomenclature number, unit, quantity received, quantity passed to the contractor (name, quantity, price, sum); owner and contractor signers | receipt-like lines (item, unit, quantity), unit, employee | the whole process (dismantling, link to a write-off act of an asset, contractor), account, price, signers (G4, G6, G5); Q20: is this form in scope at all? |
| Z-6 (annex 30) | АКТ списания запасов | write off (`stock_writeoff`, `_line`) | approver; number, date, unit, basis, responsible person; lines: name, sort, size; nomenclature number; date of acquisition; service life; unit; quantity to write off; price; sum; reason; back side: totals at the cost of guilty persons and of the organisation, commission decision, scrap lines with receipt order number, commission chair and members, responsible person | number, date, unit (`org_unit_id`), responsible person (`responsible_id`), item, unit, quantity, header reason (`reason_code`, `reason_text`) | approver, basis (G7), date of acquisition, service life, price, sum (G5), reason per line, guilty-person split, scrap lines, commission (G14, G4); commission members exist only for counts |
| Z-7 (annex 31) | Ведомость учета остатков запасов на складе | stock balances per warehouse and period (ledger balances; xlsx export REQ-728 exists, no print) | org, warehouse, shop; responsible person; number, date, reporting period, unit, shop, warehouse, pantry; lines: name, nomenclature number, unit, quantity, price, stock norm, balance at start (quantity, sum), income, expense, balance at end | balances by item, location, lot; income and expense quantity by period (ledger entries); warehouse; responsible person | price and sums (G5), stock norm (no field), accountant check signature (G4), reporting period as a filter (a read, not a field) |

### 3.5 Count forms (Inv-1, Inv-3, Inv-7, Inv-10): title and field list

The count paperwork of E1a (order, sheet, differences) is the nearest Letflow output to Inv-10 and Inv-18. Inv-1,
Inv-3 and Inv-7 describe count kinds that Letflow does not have.

| Form | Title in the file | Letflow document | Fields the form asks | We have | Missing |
|---|---|---|---|---|---|
| Inv-1 (annex 32) | Акт инвентаризации запасов, находящихся в пути | none (count kind not in the product) | org, BIN/IIN; number, date; order date and number; date of the count; lines: name, nomenclature number, account, unit, shipment date, arrival date, supplier, departure point and transport kind, actual presence (wagon or barge number, quantity, cost), measures taken; total; commission chair, members, responsible person | order number and date, count date (`cut_off_at`), commission (`chair_employee_id`, `count_commission_member`), item, unit, supplier name | goods-in-transit data: shipment and arrival dates, route, wagon number, cost, measures (G12), account (G6), IIN (G1); Q12: in scope? |
| Inv-3 (annex 34) | Акт инвентаризации отгруженных запасов | none | org, BIN/IIN; number, date; lines: buyer (name, details), name, nomenclature number, account, shipment date, payment due, measures; by buyers' documents (date, number, quantity, cost); by accounting (quantity, cost); total in words; commission chair and members | commission, item, unit, issue documents of the stock register (shipped quantity) | buyer on the issue (G3), payment terms, measures, cost (G5, G12), account (G6) |
| Inv-7 (annex 38) | Инвентаризационная опись запасов, принятых (сданных) на ответственное хранение | none (custody stock is not a separate register) | org, BIN/IIN; number, date; receipt by the responsible persons; order, count dates (start and end); balance account; lines: supplier, item, nomenclature number, account, date of acceptance, storage place, supporting document (name, number, date), unit, actual and accounting quantity and cost, reason for custody; totals; commission; responsible person's statement | commission, responsible persons (employees), storage place (`location_id`), item, unit, book and counted quantity (`count_sheet_line`), count dates (planned) | custody concept, supplier, supporting document (G7), costs (G5), account (G6), actual start and end (G12), reason for custody; Q12 |
| Inv-10 (annex 41) | Инвентаризационная опись запасов | count sheet (`CountPrint` kind `sheet`, E1a) | org, BIN/IIN; number, date; kind of stock; receipt of the responsible persons; order number and date; balance account; start and end of the count; lines: name, account, nomenclature number, unit, price, actual quantity and sum, accounting quantity and sum; totals (serial numbers, quantity, sum, in words); commission chair and members; responsible person's statement and date | number (`count_order.number`, sheet document), order, count date, commission, responsible persons (`responsible_employee_id`), item, unit, `book_quantity`, `counted_quantity`, signatures marks (`count_signature`), planned start and end | price, sums (G5), account (G6), kind of stock, actual start and end (G12), words (G10), IIN (G1), positions of the commission members (reachable through `position_id`, not printed today) |

### 3.6 Asset forms (DA-1 to DA-4, Inv-8, Inv-16): title and field list

Asset documents are specified (`asset-workflow-documents.md`); the asset module has the card only, no documents
and no print yet.

| Form | Title in the file | Letflow document | Fields the form asks | We have | Missing |
|---|---|---|---|---|---|
| DA-1 (annex 16) | Акт приемки-передачи долгосрочных активов | asset hand over (and commissioning) | transferor and receiver (name, BIN/IIN); approvals of both heads; basis (document, number, date); responsible person of the transferor; name, characteristic; date of acquisition, release, construction, registration; initial cost; useful life; accumulated depreciation; book value; inventory and factory number; debit and credit accounts; passport number; sale price with VAT; inspection by order (date, number); location; transferor, receiver, power of attorney, custody; accounting notes (chief accountant) | card name, `inventory_number`, `acquisition_date`, `acquisition_cost`, `accumulated_depreciation`, `book_value`; hand over header (`from_/to_material_responsible_id`, `to_org_unit_id`, `to_location_id`, `reason`); legal entities with BIN | transferor and receiver as separate organisations when it is a transfer between legal entities (the stock/asset document is inside one tenant), useful life, factory number, passport, accounts, sale price and VAT (G5, G6, G11), basis and power of attorney (G7), approvals and chief accountant (G4); Q21: is inter-organisation transfer in scope? |
| DA-2 (annex 17) | Инвентарная карточка учета долгосрочных активов | the asset card (`assets_card`) with its register rows | org, unit, responsible person, BIN/IIN; number, date; full name and purpose; manufacturer; kind, model, brand; cost; act of commissioning (date, number); year of release; inventory, factory, passport number; date and document of acquisition; useful life; accumulated depreciation; liquidation value; impairment; ownership sign; disposal (document, reason, income); book value; precious materials; repairs, modernisation (entries); revaluation; internal movement; characteristic elements; filled in by | name, `inventory_number`, `kind`, `acquisition_date`, `acquisition_cost`, `accumulated_depreciation`, `book_value`, `depreciation_as_of`, unit, responsible person (register), movement history (the register entries) | manufacturer, model, factory and passport numbers, year of release, useful life, liquidation value, impairment, ownership sign, precious materials, repair and revaluation history, characteristics, filled-in-by signer (G11, G4), disposal income (G5) |
| DA-3 (annex 18) | Акт на выбытие (списание) долгосрочных активов | asset write off | approver; number, date; lines: name, characteristic, release and acquisition dates, actual service life, initial cost, accumulated depreciation, book value, factory and inventory number; accessories; precious materials; commission order, inspection result, reason; commission; accounting notes | card fields as above, `reason_code`, `reason_text` of the write-off document, responsible person | actual service life, accessories, precious materials, commission and inspection result, approver (G11, G14, G4) |
| DA-4 (annex 19) | Накладная на внутреннее перемещение долгосрочных активов | asset hand over (internal) / change of responsible | org, BIN/IIN; sender and receiver unit; responsible person; basis; number, date; lines: name, characteristic, acquisition date, inventory, factory, passport number, unit, quantity, price, cost; totals, words; notes; handed over (position, signature, name, date); received; accounting mark in the card | sender and receiver unit (`org_unit_id`, `to_org_unit_id`), locations, responsible persons (`from_/to_material_responsible_id`), card name, inventory number, acquisition date, quantity (register), cost (`book_value` or `acquisition_cost`, Q22) | factory and passport numbers (G11), price (the card has cost, Q22), basis (G7), words (G10), accountant mark (G4) |
| Inv-8 (annex 39) | Инвентаризационная опись долгосрочных активов | asset count sheet (count of the asset register; count paperwork is specified for stock only) | org, BIN/IIN; number, date; object kind, location; receipt of responsible persons; order; accounts; start, end; lines: name, account, release date, acquisition date, inventory, factory, passport number, actual quantity and cost, accounting quantity and cost, note; totals; commission; statement; checker | the count mechanism (order, commission, signatures) is generic; card fields; location | counts of assets are not built for the asset register (phase C/D scope); factory and passport numbers, accounts, actual cost (G11, G6, G5), actual start and end (G12) |
| Inv-16 (annex 47) | Сличительная ведомость результатов инвентаризации долгосрочных активов | asset differences sheet | org, BIN/IIN; number, date; count date; order; responsible person; start, end; lines: name, characteristic, release date, acquisition date, inventory, factory, passport number, surplus and shortage (quantity, cost); totals; accountant; responsible persons' agreement | as Inv-18: surplus and shortage quantity derived from book and counted quantity, responsible person, card fields | cost of surplus and shortage (G5), factory and passport numbers (G11), accountant (G4), actual start and end (G12) |

### 3.7 Kazakh codes and titles (official text, order No. 562, current Kazakh edition)

Source: `adilet-kk-562-text.txt` (the owner's saved Adilet page, 2026-11-06). Codes in the order's own list of annexes;
titles as printed on the form (capitals kept, a footnote star dropped). Letter codes: З = **Қ-**, Инв = **Түг-**,
ДА = **ҰМА-**, Т = **Е-**, ОС = **НҚ-**; КО-, А-, БА-, С- unchanged. The annex number is the key: the Kazakh code
**А-1 is used twice** (annex 11 and annex 51) and **С-1 twice in meaning** (annex 6 in the Kazakh edition, annex 51 in
the Russian draft folder). The Kazakh edition has the 10 annexes the Russian folder lacks (4, 6, 7, 14, 23, 36, 43,
44, 46, 50). Where the extract found no title line, the table says so; open the annex in the official text.

| Annex | Russian code | Kazakh code | Kazakh title (official text, as printed) | Form in this file |
|---|---|---|---|---|
| 1 | КО-1 | КО-1 | КІРІС КАССА ОРДЕРІ |  |
| 2 | КО-2 | КО-2 | ШЫҒЫС КАССА ОРДЕРІ |  |
| 3 | КО-3 | КО-3 | КІРІС ЖӘНЕ ШЫҒЫС КАССА ҚҰЖАТТАРЫН ТІРКЕУ ЖУРНАЛЫ |  |
| 4 | КО-4 | КО-4 | КАССА КІТАБЫ |  |
| 5 | КО-5 | КО-5 | КАССИР ҚАБЫЛДАҒАН ЖӘНЕ БЕРГЕН АҚШАНЫ ЖӘНЕ ОНЫҢ БАЛАМАЛАРЫН ЕСЕПКЕ АЛУ (КІТАБЫ) |  |
| 6 | Д-1 | С-1 | СЕНІМХАТ |  |
| 7 | Д-2 | С-2 | БЕРІЛГЕН СЕНІМХАТТАРДЫ ЕСЕПКЕ АЛУ ЖУРНАЛЫ |  |
| 8 | Т-1 | Е-1 | ЕСЕП АЙЫРЫСУ ВЕДОМОСТІ (КІТАБЫ) |  |
| 9 | Т-2 | Е-2 | (title line not detected by the text extract; open annex 9) |  |
| 10 | Т-3 | Е-3 | АВАНСТЫҚ ЕСЕП |  |
| 11 | А-1 | А-1 | АКТИВТЕРДі ҚАБЫЛДАУ ТУРАЛЫ АКТІ |  |
| 12 | А-2 | А-2 | ОРНАТУ ҮШІН АКТИВТІ ҚАБЫЛДАП АЛУ АКТІ |  |
| 13 | А-3 | А-3 | АКТИВТІ МОНТАЖДАУҒА ҚАБЫЛДАП АЛУ-БЕРУ АКТІСІ |  |
| 14 | А-4 | А-4 | АКТИВТІҢ АНЫҚТАЛҒАН АҚАУЛАРЫ ТУРАЛЫ АКТІ |  |
| 15 | А-5 | А-5 | (title line not detected by the text extract; open annex 15) |  |
| 16 | ДА-1 | ҰМА-1 | ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ҚАБЫЛДАП АЛУ-БЕРУ АКТІСІ | DA-1 |
| 17 | ДА-2 | ҰМА-2 | ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ЕСЕПКЕ АЛУДЫҢ ТҮГЕНДЕУ КАРТОЧКАСЫ | DA-2 |
| 18 | ДА-3 | ҰМА-3 | ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ІСТЕН ШЫҒАРУ (ЕСЕПТЕН ШЫҒАРУ) АКТІСІ | DA-3 |
| 19 | ДА-4 | ҰМА-4 | ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ІШКІ ӨТКІЗУГЕ БЕРІЛЕТІН ЖҮКҚҰЖАТ | DA-4 |
| 20 | БА-1 | БА-1 | БИОЛОГИЯЛЫҚ АКТИВТЕРДІ ҚАБЫЛДАП АЛУ-БЕРУ АКТІСІ |  |
| 21 | БА-2 | БА-2 | БИОЛОГИЯЛЫҚ АКТИВТЕРДІ ЕСЕПКЕ АЛУДЫ ТҮГЕНДЕУ КАРТОЧКАСЫ |  |
| 22 | БА-3 | БА-3 | БИОЛОГИЯЛЫҚ АКТИВТЕРДІ ЕСЕПТЕН ШЫҒАРУ АКТІСІ |  |
| 23 | ОС-1 | НҚ-1 | ЖАЛҒА АЛЫНҒАН (ҰЗАҚ МЕРЗІМДІ ЖАЛҒА АЛЫНҒАН) НЕГІЗГІ ҚҰРАЛДАРДЫ ЕСЕПКЕ АЛУ КАРТОЧКАСЫ |  |
| 24 | ОС-2 | НҚ-2 | АВТОКӨЛІК ҚҰРАЛДАРЫН ЕСЕПТЕН ШЫҒАРУҒА АРНАЛҒАН АКТІ |  |
| 25 | З-1 | Қ-1 | Қорлардың КІРІС ОРДЕРІ | Z-1 |
| 26 | З-2 | Қ-2 | ҚОРЛАРДЫ ШЕТКЕ БЕРУГЕ АРНАЛҒАН ЖҮКҚҰЖАТ | Z-2 (3.1) |
| 27 | З-3 | Қ-3 | ҚОРЛАРДЫ ЕСЕПКЕ АЛУ КАРТОЧКАСЫ | Z-3 |
| 28 | З-4 | Қ-4 | НЕГІЗГІ ҚҰРАЛДАРДЫ БҰЗУ МЕН БӨЛШЕКТЕУ КЕЗІНДЕ АЛЫНҒАН ҚОРЛАРДЫ КІРІСКЕ АЛУ ТУРАЛЫ АКТІ | Z-4 |
| 29 | З-5 | Қ-5 | ҚОРЛАРДЫ ІШКІ АУЫСТЫРУҒА АРНАЛҒАН ЖҮКҚҰЖАТ | Z-5 (3.2) |
| 30 | З-6 | Қ-6 | ҚОРЛАРДЫ ЕСЕПТЕН ШЫҒАРУ АКТІСІ | Z-6 |
| 31 | З-7 | Қ-7 | ҚОЙМАДАҒЫ ҚОРЛАРДЫҢ ҚАЛДЫҚТАРЫН ЕСЕПКЕ АЛУ ТІЗІМДЕМЕСІ | Z-7 |
| 32 | Инв-1 | Түг-1 | ЖОЛДАҒЫ ҚОРЛАРДЫ ТҮГЕНДЕУ АКТІСІ | Inv-1 |
| 33 | Инв-2 | Түг-2 | ИНВЕСТИЦИЯЛАРДЫ ТҮГЕНДЕУ АКТІСІ |  |
| 34 | Инв-3 | Түг-3 | ТИЕЛГЕН ҚОРЛАРДЫ ТҮГЕНДЕУ АКТІСІ | Inv-3 |
| 35 | Инв-4 | Түг-4 | ДЕБИТОРЛЫҚ ЖӘНЕ КРЕДИТОРЛЫҚ БЕРЕШЕКТІ ТҮГЕНДЕУ АКТІСІ |  |
| 36 | Инв-5 | Түг-5 | БАҒАЛЫ МЕТАЛДАРДЫ ЖӘНЕ ОЛАРДАН ЖАСАЛҒАН БҰЙЫМДАРДЫ ТҮГЕНДЕУ АКТІСІ |  |
| 37 | Инв-6 | Түг-6 | АҚША ҚАРАЖАТТАРЫ МЕН АҚША ҚАРАЖАТТАРЫНЫҢ БАЛАМАЛАРЫН ТҮГЕНДЕУ АКТІСІ |  |
| 38 | Инв-7 | Түг-7 | ЖАУАПТЫ САҚТАУҒА ҚАБЫЛДАНҒАН (ТАПСЫРЫЛҒАН) ҚОРЛАРДЫҢ ТҮГЕНДЕУ ТІЗІМДЕМЕСІ | Inv-7 |
| 39 | Инв-8 | Түг-8 | ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ТҮГЕНДЕУ ТІЗІМДЕМЕСІ | Inv-8 |
| 40 | Инв-9 | Түг-9 | БИОЛОГИЯЛЫҚ АКТИВТЕРДІ ТҮГЕНДЕУ ТІЗІМДЕМЕСІ |  |
| 41 | Инв-10 | Түг-10 | ҚОРЛАРДЫ ТҮГЕНДЕУ ТІЗІМДЕМЕСІ | Inv-10 |
| 42 | Инв-11 | Түг-11 | ИНВЕСТИЦИЯЛАРДЫ ТҮГЕНДЕУ ТІЗІМДЕМЕСІ |  |
| 43 | Инв-12 | Түг-12 | ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ТҮГЕНДЕУ ТІЗІМІ |  |
| 44 | Инв-13 | Түг-13 | ҚОРЛАРДЫ ТҮГЕНДЕУ БЕЛГІСІ |  |
| 45 | Инв-14 | Түг-14 | ҚАТАҢ ЕСЕПТІЛІК БЛАНКІЛЕРІНІҢ ТҮГЕНДЕУ ТІЗІМДЕМЕСІ |  |
| 46 | Инв-15 | Түг-15 | БИОЛОГИЯЛЫҚ АКТИВТЕРДІ ЕСЕПКЕ АЛУ ЖӨНІНДЕГІ ТҮГЕНДЕУ КАРТОЧКАЛАРЫНЫҢ ТІЗІМДЕМЕСІ |  |
| 47 | Инв-16 | Түг-16 | ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ТҮГЕНДЕУ НӘТИЖЕЛЕРІНІҢ САЛЫСТЫРМАЛЫ ВЕДОМОСІ | Inv-16 |
| 48 | Инв-17 | Түг-17 | БИОЛОГИЯЛЫҚ АКТИВТЕРДІ ТҮГЕНДЕУ НӘТИЖЕЛЕРІНІҢ САЛЫСТЫРУ ТІЗІМДЕМЕСІ |  |
| 49 | Инв-18 | Түг-18 | ҚОРЛАРДЫ ТҮГЕНДЕУ НӘТИЖЕЛЕРІНІҢ САЛЫСТЫРУ ВЕДОМОСІ | Inv-18 (3.3) |
| 50 | Р-1 | Ж-1 | ОРЫНДАЛҒАН ЖҰМЫСТАРДЫҢ (КӨРСЕТІЛГЕН ҚЫЗМЕТТЕРДІҢ) АКТІЛЕРІ |  |
| 51 | С-1 | А-1 | БУХГАЛТЕРЛІК АНЫҚТАМА |  |

Kazakh terms the stock and count forms use, as printed (for the later build; no translation is made here):
`Ұйым (жеке кәсіпкер)` organisation (individual entrepreneur), `ЖСН/БСН` IIN/BIN, `Құжат нөмірі` document number,
`Жасалған күні` date of compilation, `Ретімен нөмірі` serial number, `Номенклатуралық нөмірі` nomenclature number,
`Өлшем бірлігі` unit, `Саны` quantity, `беруге жатады` / `берілгені` to release / released, `Бірлігінің бағасы, теңгемен`
price per unit in tenge, `ҚҚС-пен сомасы` / `ҚҚС сомасы` sum with VAT / VAT sum, `Жиыны` total, `Беруге рұқсат еткен`
release authorised by, `Берген` released by, `Тексерді` checked by, `Алды` received by, `Бас бухгалтер` chief accountant,
`лауазымы қолы қолды таратып жазу` position, signature, name, `М.П.` seal place (Қ-2).
Field labels checked against the Kazakh text for the three starting forms: Қ-2 (= Z-2, annex 26), Қ-5 (= Z-5,
annex 29), Түг-18 (= Inv-18, annex 49). Their column groups equal the Russian ones listed in 3.1 to 3.3
(Қ-2: nine columns, quantity split into `беруге жатады` / `берілгені`; Қ-5: eight columns; Түг-18: fourteen front
columns in surplus `артығы` / shortage `кемі` groups with quantity `саны` and sum `сомасы, теңгемен`, the accounting
correction `шоты` columns, and a back side headed `Қайта сұрыптау` = regrading). The mapping tables 3.1 to 3.3 therefore stand for the Kazakh forms; only the labels
differ. A check of every other form's columns against the Kazakh text is not done here.

### 3.8 Differences: Russian 2026 drafts versus the current Kazakh edition

Read from the Kazakh text and from the catalog (`CATALOG.md`, "Kazakh versions FOUND"). The catalog says the 2026 draft
changes mostly wording; the points below are what is known, none is a decision.

| # | Point | Russian 2026 draft folder | Current Kazakh edition (Adilet) | Effect on a build |
|---|---|---|---|---|
| D1 | **Annex 51** | form **С-1**, "Бухгалтерская справка" | form **А-1**, `БУХГАЛТЕРЛІК АНЫҚТАМА` (added to the order 2015, in force from 2016-01-01); in the Kazakh edition **С-1 is annex 6** (`СЕНІМХАТ`, power of attorney) | key forms by annex number, not by code; confirm the final code of annex 51 when the amending order is registered |
| D2 | **IIN / BIN** | `ИИН / БИН` | `ЖСН/БСН` on every form with a header (58 places); Kazakh edition has no separate IIN-only field | same as gap G1: one printed identifier, the label follows the language |
| D3 | **Currency** | "в теңге" (column headers) | `теңгемен` / `теңге`; four headers spell `тенгемен` (Түг-8 and Түг-16, columns of cost), a typo of the official text | print `теңгемен` as in the form; do not copy the typo |
| D4 | **Seal place** | "Место печати" wording in the draft (catalog) | `М.П.` on Қ-2 (next to the chief accountant); `Мөрдың орны (бар болса)` on ҰМА-1 (seal place, if any); Түг-4 notes that the signature and seal are on the second side | gap G17: print the mark as the form has it; the wording differs by form |
| D5 | **Entrepreneur wording** | `индивидуальный предприниматель` | `Ұйым (жеке кәсіпкер)` on most forms but `Ұйым (дара кәсіпкер)` on Түг-13, Түг-15, Түг-18 (and others, 9 places) | two Kazakh spellings of "individual entrepreneur" in the official text; copy each form's own |
| D6 | **Form titles in Kazakh** | stock count lists are `опись`, comparison `сличительная ведомость`, internal movement `внутреннее перемещение` | `ТІЗІМДЕМЕСІ` (list), `САЛЫСТЫРУ ВЕДОМОСІ` (Түг-18) but `САЛЫСТЫРМАЛЫ ВЕДОМОСІ` (Түг-16), `ІШКІ АУЫСТЫРУҒА АРНАЛҒАН ЖҮКҚҰЖАТ` (Қ-5, stock) but `ІШКІ ӨТКІЗУГЕ БЕРІЛЕТІН ЖҮКҚҰЖАТ` (ҰМА-4, assets); the inventory card of assets is `ТҮГЕНДЕУ КАРТОЧКАСЫ` (ҰМА-2) | the term differs between forms of one kind; take the title from section 3.7 per form |
| D7 | **Titles missing in the Russian catalog** | Z-1, Z-4, Z-6, Z-7 untitled in the catalog (the files give them, 3.4) | Қ-1 `Қорлардың КІРІС ОРДЕРІ`, Қ-4 `…БҰЗУ МЕН БӨЛШЕКТЕУ КЕЗІНДЕ АЛЫНҒАН ҚОРЛАРДЫ КІРІСКЕ АЛУ ТУРАЛЫ АКТІ`, Қ-6 `ҚОРЛАРДЫ ЕСЕПТЕН ШЫҒАРУ АКТІСІ`, Қ-7 `…ҚАЛДЫҚТАРЫН ЕСЕПКЕ АЛУ ТІЗІМДЕМЕСІ` (a list, not a `ведомость`) | titles agree in meaning with section 3.4 |
| D8 | **Coverage** | 41 of 51 annexes | all 51 | annexes 4, 6, 7, 14, 23, 36, 43, 44, 46, 50 have a Kazakh text but no Russian draft in the folder; none is in scope here |
| D9 | **Edition** | 2026 draft of an amending order (dates blank, public discussion ended 2026-06-17, no registered order found up to 2026-07) | the order as in force, with amendments up to the Adilet page date (for example annexes 6, 8, 10, 18, 19, 26, 29 re-issued by order No. 402 of 2013-08-19, annexes 16 by No. 411 of 2018-03-28) | layout and field lists in 3.1 to 3.6 come from the draft; if the amending order is registered, redo them (section 0) |

Points not checked: whether every column and label of the other forms agrees between the draft and the Kazakh edition.
The comparison above for Қ-2, Қ-5 and Түг-18 found no difference in the column groups; the differences found are those
in the table. The Russian text of the current edition was not in the folder for a line-by-line comparison.

## 4. Summary table

Form: the Russian form. Document: the Letflow document it prints. "Have": fields filled from data. "Missing": gap ids
of section 2 with the owner question.

| Form | Document | Fields we have | Fields missing | Owner question |
|---|---|---|---|---|
| Z-2 | issue | number, date, organisation name, BIN, responsible, item, unit, quantity | recipient, IIN, transport, TTN, "to release" quantity, price, VAT, sums, words, signers, power of attorney | Q1, Q3, Q4, Q5, Q7 to Q10 |
| Z-5 | transfer, hand over, return (Q19 yes, T-1959) | number, date, both units, responsible persons, item, unit, quantity | basis, "to release" quantity, price, sums, words, approver and checker | Q1, Q4, Q5, Q7, Q9, Q10, Q19 |
| Inv-18 | count differences sheet | number, dates, order, item, unit, surplus and shortage quantity, responsible person | sums, accounting corrections, regrading, accountant, IIN | Q1, Q4, Q5, Q6, Q15 |
| Z-1 | receipt | number, date, supplier, accompanying document, items, quantity, price, sum, accepting employee | account, payment document, quantity by document versus accepted, mass, passport, card entry, "Сдал" | Q4, Q6, Q7, Q13 |
| Z-3 | stock card (ledger read) | item, unit, lot, movements, balance | account, price, kind, sort, profile, size, control signature | Q5, Q6, Q13 |
| Z-4 | none | receipt-like lines | the dismantling process and link to an asset write-off | Q20 |
| Z-6 | write off | number, date, unit, responsible, items, quantity, header reason | approver, basis, price, sum, per-line reason, scrap, commission | Q4, Q5, Q7, Q14 |
| Z-7 | stock balances (ledger read) | balances, income, expense, location, responsible | price, sums, stock norm, accountant check | Q4, Q5, Q13 |
| Inv-1 | none (count kind) | commission, count date | goods-in-transit data, account | Q6, Q12 |
| Inv-3 | none (count kind) | commission, item | buyer, terms, cost, account | Q3, Q5, Q6, Q12 |
| Inv-7 | none (count kind) | commission, storage place, book and counted quantity | custody data, supplier, document, cost | Q5, Q7, Q12 |
| Inv-10 | count sheet | number, order, count date, commission, responsible persons, item, unit, book and counted quantity | price, sums, account, kind of stock, actual start and end, words | Q1, Q5, Q6, Q10, Q12 |
| DA-1 | asset hand over | card cost, depreciation, book value, inventory number, handing-over persons | useful life, factory and passport number, accounts, sale price, basis, approvals | Q4 to Q7, Q11, Q21 |
| DA-2 | asset card | name, inventory number, kind, acquisition date and cost, depreciation, book value | manufacturer, model, numbers, useful life, impairment, ownership, repairs, revaluation, characteristics | Q4, Q11 |
| DA-3 | asset write off | card fields, reason | actual service life, accessories, commission, approver | Q4, Q11, Q14 |
| DA-4 | asset hand over (internal) | units, locations, responsible persons, name, inventory number, acquisition date | factory and passport numbers, price, basis, words, accountant mark | Q5, Q7, Q10, Q11, Q22 |
| Inv-8 | asset count sheet | card fields, location | the asset count itself, numbers, accounts, actual cost | Q5, Q6, Q11, Q12 |
| Inv-16 | asset differences sheet | derived surplus and shortage quantity, responsible person | cost, numbers, accountant | Q4, Q5, Q11 |

Extra owner questions raised in sections 3.1 to 3.6: Q14b (print the location on Z-2), Q18 (item code as the
nomenclature number), Q19 (hand over and return on Z-5), Q20 (Z-4 in scope), Q21 (inter-organisation transfer on DA-1),
Q22 (asset cost on DA-4: `book_value` or `acquisition_cost`). Q16 is reworded in G16 (which edition to print).

## 5. Reading this file

* The three starting forms (Z-2, Z-5, Inv-18) are mapped field by field in 3.1 to 3.3. The others are at the level of
  title, document, field list, what we have and what is missing.
* The first thing a build would need is not a form but the owner's answers to Q4 and Q5 (signers and money), since
  they block the totals and the signature blocks of almost every stock form.
* The "have" column is a proposal until a build proves it against the code; names of columns are those of the entity
  definitions and print code at the time of writing.
* Out of scope here (Z-2 is built in section 6): any other print template or code, the cash, labour, biological and general forms of the
  folder (КО, Т, БА, С, А, ОС), the draft package files (the order, the explanatory note, the comparison table), and
  the electronic exchange of any of these forms.

## 6. Kazakh official text and the print engine (E5b, T-1416)

* **Built:** the print engine (`Letflow.Documents.FormPrint`, layouts and the ru/kk message catalog in
  `priv/print_forms/`) and one form on it, Z-2 (ru) / Q-2 (kk), annex 26, for an issued `issue` document:
  `GET /documents/:id/print?form=z2&format=pdf|docx&lang=ru|kk` (permission `StockRead`). The ru layout and words
  follow the 2026 draft file of annex 26; the kk layout and words are copied from the current Adilet edition (Q-2
  nysany, annex 26), not machine translated. All Z-2 catalog entries are `kk_status: official`; a future form whose
  kk text is a machine draft gets a draft notice line in the kk output. If the final order text differs from the
  draft, the ru side is changed in the catalog and layout, and the operator is asked first.
* **Filled from Letflow:** organisation name and BIN (legal entity of the document's org unit), number, date,
  responsible person (also the "released by" name), line number, item name and code, unit, issued quantity, total of
  issued quantity. **Blank lines for the signer:** receiver, transport, transport invoice, planned quantity, price,
  VAT amounts, amounts in words, the other signers, the power of attorney (gaps G3, G4, G5, G8, G9, G10 stay open);
  the IIN is never stored (G1). Nothing is invented.
* **G16 (Kazakh wording) is answered** for every form the Adilet text covers (all 51 annexes): the kk labels of a form
  are taken from the official text. Annex numbers are the same in both languages. Kazakh form codes: Q- = Z- (stock),
  Tug- = Inv- (counts), UMA- = DA- (assets), E- = T- (labour), NQ- = OS-.
* **Differences between the current Kazakh edition and the Russian 2026 drafts** (read again from the two sources for
  annexes 26 and 51, not extended from memory):
  * Annex 51 is form **A-1** (Бухгалтерлік анықтама) in the kk edition and **S-1** (БУХГАЛТЕРСКАЯ СПРАВКА) in the ru
    draft folder.
  * Annex 26 wording: the ru draft spells out "Индивидуальный идентификационный номер/Бизнес идентификационный номер"
    where the kk edition has "ЖСН/БСН"; the ru draft heads the annex "к приказу Министра финансов ... от 20 декабря
    2012 года № 562"; the ru column heading uses "теңге" (Kazakh spelling) inside Russian text; the kk edition has
    "теңгемен". The stamp mark is "М.П." in both annex 26 texts, so the "place of the seal" wording change named in
    the catalog note was not seen on Z-2 and is to be checked on the forms where it occurs.
  * The Russian folder has 41 of the 51 annexes; the kk page has all 51 (annexes 4, 6, 7, 14, 23, 36, 43, 44, 46 and
    50 exist only in kk here).
* The proof is done in both languages and both formats by `test/letflow/modules/stock/form_z2_router_test.exs`
  (real router, real token) and `test/letflow/documents/form_print_test.exs` (kk title, kk labels, PDF non-empty).

### 6.1 Count forms Inv-18 and Inv-10 (E5d, T-1418)

* **Built:** `GET /counts/:id/print/differences?form=inv18` (annex 49, Tug-18) and
  `GET /counts/:id/print/sheet?form=inv10` (annex 41, Tug-10), each with `format=pdf|docx&lang=ru|kk` (default pdf, ru;
  `en` is refused with `invalid_lang`, a wrong pairing with `invalid_form`), permission `StockRead`, same read path and scope
  rules as the E1a print. Buttons: next to the count paperwork buttons on the count screen (the Kazakh UI asks kk, any other
  UI asks ru). Layouts `priv/print_forms/inv18.json` and `inv10.json`, kk wording from the Adilet text
  (`kk_status: official`), ru wording from the 2026 drafts. If the final order text differs, ask the operator first.
* **Filled from Letflow:** organisation name and BIN, number and date of the document, count date, order number and date,
  line number, item name and code, unit. Inv-18: quantity of the surplus or shortage of each line (absolute value, totals
  per column), the responsible persons of the lines (name, position). Inv-10: actual (counted) and accounting (book)
  quantity, number of rows and total counted quantity, the responsible persons of the lines, the commission chair and members
  with positions. A person the caller's scope hides has neither name nor position (INV-2).
* **Left blank, never invented:** all sums and prices (G5), accounts (G6), the regrading table on the back of Inv-18 (G15),
  the accountant, every signature, the IIN (G1), kind of stock, balance account, the amounts in words (G10), the actual start and
  end of an Inv-10 count (the planned times are not the actual ones, G12), the responsible persons' statement.
* **PDF shape:** the PDF engine allows 12 columns per table, so the 14-column front table of Inv-18 is printed as two tables
  (columns 1 to 12, then column 1 with 13 and 14; header numbers stay the official ones); the `.docx` keeps all 14. A PDF
  holds at most 999 lines (the totals row is the 1000th row): more is `422 print_too_large`, the `.docx` has no cap.
* **Not built, no data:** Inv-1 (goods in transit: the count kind is not in the product), Inv-3 (shipped stock: buyer, terms and
  cost are not on the issue document), Inv-7 (custody stock: there is no custody register; printing a sheet as Inv-7 would state
  a fact Letflow does not hold).
* **Proof:** `test/letflow/modules/stock/form_count_router_test.exs` (real router, real token, both formats, both languages,
  scope, row cap), `form_count_test.exs` (mappers), `test/letflow/documents/form_print_wide_test.exs` (engine).

## 7. Z-3 and Z-5 on the print engine (E5c, T-1417)

* **Built:** Z-5 (ru) / Q-5 (kk), annex 29, for an issued `transfer`, `hand_over` or `return` (Q19 answered yes, T-1959): `GET /documents/:id/print?form=z5&format=pdf|docx&lang=ru|kk`
  (permission `StockRead`; another kind answers 422 `print_not_available`). Z-3 (ru) / Q-3 (kk), annex 27, the stock card of one item at one place:
  `GET /modules/stock/stock-card/print?sku&location[&lot]&format=pdf|docx&lang=ru|kk` (permission `StockRead`).
  Buttons: "Form Z-5" PDF/Word next to the print button of a transfer, hand over and return; "Stock card Z-3" PDF/Word on the balances screen,
  enabled once an item and a location are chosen. The English screen prints the Russian form (the forms exist in ru and kk).
  All new catalog entries are `kk_status: official` (kk text copied from the Adilet edition).
* **Z-5 filled from Letflow:** organisation name and BIN of the sending unit's legal entity, number, date, sending and
  receiving structural unit (with the location name after a slash), responsible person (also the releaser), the
  receiver's name on the "received" line, line number, item name and code, unit, issued quantity and its total.
  **Blank:** basis (G7), planned quantity (G9), price and amount (G5), amounts in words (G10), "allowed by" and "checked
  by", every signer position (G4), sort, brand and size (G13).
* **Z-3 filled from Letflow** (built from the ledger movements the caller may read: income is a positive leg quantity,
  expense a negative one, balance is the running sum; a scoped reader's masked legs are skipped): organisation name and
  BIN, structural unit, item name and code, unit of measure, the lot's mark and expiry date when a lot is asked for, and
  per movement the date (tenant zone), document number, line number, income, expense, balance. **Blank:** counterparty
  ("from whom received or to whom issued"; available for receipts in principle, left out of this slice), accounting unit of
  finished output, kind of production, sort, profile, size, account, price, person responsible, shop, executor, the control
  signature and the precious-materials note. A card of more than 1000 entries answers 422 `card_too_long`; no visible
  movement answers 404. The header is a list of plain lines, not the multi-cell arrangement of the official sheet.
* **Differences found while reading annexes 27 and 29** (ru 2026 draft against the kk edition): the kk edition of Z-3 has
  a "Қойма" (warehouse) line that the ru draft lacks (not printed); Z-5 signers are listed "allowed, checked, released,
  received" in the ru draft and "allowed, released, checked, received" in the kk edition (one layout per form: the ru order
  is used in both languages); the kk text of the "total quantity in words" line reads "саны атауы" and is kept as printed;
  the annex 29 note in the kk edition says the annex was restated by order No. 402 of 19.08.2013.
* The proof is `test/letflow/modules/stock/form_z5_router_test.exs` and `stock_card_router_test.exs` (real router, real
  token, ru and kk, pdf and docx), with the pure mappers in `form_z5_test.exs` and `stock_card_source_test.exs`.

## 8. All 51 forms: code pair, BIN/IIN source, signer rule, VAT rule (E2/E5, T-1453)

Owner decisions relayed by the PM on 2026-11-07: (a) the team checks the Kazakh code pairs itself; (b) the BIN/IIN
comes from the attribute of the org unit, legal entity, counterparty or employee record that the form needs, and a
missing attribute is registered as a requirement; (c) the signers are the members of the commission appointed by the
head's order, plus the persons by whom the assets are counted or who are accountable for them, per form; (d) the VAT
rule depends on the form and on the rates of the Tax Code. A gap that this section does not close has a requirement
id; no gap blocks phase E.

### 8.1 Sources and how the code pairs were checked

* Russian codes: (1) the 41 draft files, the code line ("Форма З-2", "Форма № ДА-3") read from each file by a script
  (python3 standard library, read only); (2) the list of annexes of the **current Russian edition** of order No. 562
  ("1) форму КО-1 согласно приложению 1; ..."), read on 2026-11-07 from the mirror cdb.kz
  (cdb.kz/sistema/pravovaya-baza/ob-utverzhdenii-form-pervichnykh-uchetnykh-dokumentov/), because the Russian page of
  adilet.zan.kz is rendered by script and returns no text to a plain download. For the 41 annexes in the folder the
  two Russian sources agree on every code (script compare, no difference).
* Kazakh codes: the list of annexes of the current Kazakh edition ("1) осы бұйрыққа 1-қосымшаға сәйкес КО-1
  нысаны; ...", lines 78 to 178 of `adilet-kk-562-text.txt`) and the code line above each annex; they agree.
* **Corrections to section 3.7** found by this check (the table is corrected in place): annex 6 is **Д-1** in Russian
  (доверенность; kk С-1 СЕНІМХАТ), annex 7 is **Д-2** in Russian (kk С-2), annex 50 is **Р-1** in Russian (акт
  выполненных работ; kk Ж-1), and annex 51 is **С-1** in the current Russian edition too, not only in the 2026 draft
  folder (kk А-1). So the code letters do not convert one to one: Д- = С- for annexes 6 and 7, Р- = Ж- for annex 50,
  С- = А- for annex 51, and the kk letter С- names annexes 6 and 7, not 51. The key of a form stays its annex number.
* The 2026 amending order (draft): its explanatory note says the change is editorial (the word "тенге" becomes
  "теңге" after the 2026 Constitution) and its order text says it enters into force on 2026-07-01. A registered
  amending order was not found in this run (the uchet.kz question service also reports none up to 2026-07-07). The
  draft keeps every code of the current Russian edition. If a registered text differs, section 0 applies.

### 8.2 BIN/IIN source (decision (b))

* Every one of the 51 forms has **one combined field** "ИИН/БИН" (ru, in the 2026 draft spelled out "Индивидуальный
  идентификационный номер/Бизнес идентификационный номер") / "ЖСН/БСН" (kk) for the organisation or individual
  entrepreneur that keeps the form. The only exception is the Russian draft of З-3 (annex 27), which has no such
  field; its Kazakh form Қ-3 has `ЖСН/БСН` (print it in kk only, as each language's own form has it).
* **Own organisation** (code **LE** in 8.5): `org_legal_entity.bin` of the legal entity of the document's org unit
  (`org_unit.legal_entity_id`), as the built prints Z-2, Z-5, Z-3, Inv-10 and Inv-18 already do. Both identifiers are 12
  digits and the form has one field, so an individual entrepreneur is entered as a legal entity whose `bin` holds the
  IIN (UAT assumption, to be confirmed by the process owner). This closes gap G1 for printing: no separate IIN field
  is needed, and the text "IIN never stored (G1)" in the moduledocs of the prints means only that the field is named
  `bin`.
* **Other party** (code **CP**): `catalog_counterparty.tax_id` of the counterparty (optional, format not checked,
  REQ-604). Forms with a second identifier: С-1 / Д-1 (annex 6: the receiver and the payer), А-2 (annex 12: the
  sender and the consignor), Түг-4 / Инв-4 (annex 35: each debtor and creditor). For ҰМА-1 / ДА-1 (annex 16) between two
  legal entities of one tenant (Q21), the receiver's identifier is the other legal entity's `bin`.
* **Employee**: no form of the 51 asks for the IIN of a person (every ИИН/БИН field belongs to an organisation or an
  entrepreneur; the labour forms Т-1 to Т-3 identify a person by the personnel number, which is `org_employee.code`).
  No employee attribute is needed, so no requirement is registered for it.
* Org unit: no form asks for an identifier of a structural unit; the unit prints by name (`org_unit.name`).

### 8.3 Signer rule (decision (c))

Signer kinds used in the table of 8.5, with where Letflow takes each from:

| Code | Signer on the form | Letflow source |
|---|---|---|
| C | commission: chair and members ("Председатель комиссии", "Члены комиссии" / `Комиссия төрағасы`, `Комиссия мүшелері`), appointed by the head's order | count: `count_order.chair_employee_id` and `count_commission_member` (the count order is the order; its `number` and `issued_at`); stock write-off: REQ-776; asset write-off: REQ-777; any other form: no Letflow document |
| M | materially responsible person(s) ("Материально-ответственное лицо", "лицо, ответственное за сохранность" / `Материалдық жауапты тұлға`): the person by whom the assets are counted or who is accountable | count: `count_sheet_line.responsible_employee_id` of the lines; stock document: `responsible_id`; asset card and asset documents: `material_responsible_id` |
| P | the persons who hand over and receive ("Сдал" / "Принял", "Отпустил" / "Получил", "Запасы получил") | `from_responsible_id` and `to_responsible_id` of a transfer, hand over or return; `responsible_id` of a receipt ("Принял") or issue ("Отпустил"); a receiver outside the organisation (Z-2) is not stored (G3): blank line |
| H | head of the organisation ("УТВЕРЖДАЮ Руководитель", "Отпуск разрешил", "Руководитель") | not in decision (c) and no slot in Letflow: a blank line, signed by hand (default of G4) |
| A | chief accountant or accountant ("Главный бухгалтер", "Бухгалтер", "Проверил", "Указанные данные проверил") | as H: a blank line, signed by hand |
| K | cashier ("Кассир", "Получил кассир") | as H; the cash forms have no Letflow document |
| X | another party: customer and contractor or installer representative, executor, the person to whom a power of attorney is issued, "Ответственный за поставку" where it is not the responsible employee | a blank line, signed by hand |

The name and position of a person printed from Letflow are `org_employee.full_name` and `org_position.name` through
`position_id` (as the built prints do); the signature itself is always by hand. A person the caller's scope hides
prints neither name nor position (INV-2, section 6.1).

### 8.4 VAT rule (decision (d))

* Tax Code of the Republic of Kazakhstan of 18 July 2025 No. 214-VIII (in force since 2026-01-01), article 503 "Ставки
  налога на добавленную стоимость" (text read on 2026-11-07 from kodeksy-kz.com and buhgpt.kz, both giving the Adilet
  text): **item 1** 16 percent, the basic rate on the taxable turnover and taxable import; **item 2** 5 percent from
  2026-01-01 and 10 percent from 2027-01-01 for medicines, medical devices and their components, technical
  rehabilitation aids (list set by the Government) and licensed medical services; **item 3** 10 percent for domestic
  periodical printed media; **item 4** 0 percent for the turnovers of chapter 47 (for example export); **item 5** at
  deregistration from VAT, stock at the rate of the deregistration date, fixed and biological assets at the rate of
  their acquisition date. Exempt turnovers (no VAT) are listed in other articles of the Code and are not mapped here
  item by item: the user chooses "none" for them.
* Only **two** of the 51 forms have a VAT field (script search for "НДС" in the 41 Russian files and for "ҚҚС" in the
  Kazakh text found hits in annexes 16 and 26 only):
  * **З-2 / Қ-2** (annex 26), columns 8 "Сумма с НДС" and 9 "Сумма НДС": a sale of stock to a third party is a
    taxable turnover; the rate is the one of article 503 that applies to the goods (16, 5 or 10, 0) or none. Letflow
    has no price or rate on the issue: **REQ-778** (price without VAT and rate per issue line, columns 7 to 9 and their
    totals; rounding is a UAT assumption to be confirmed by the process owner).
  * **ҰМА-1 / ДА-1** (annex 16), "Стоимость реализации с НДС": filled only when the transfer is a sale to another
    organisation, at the rate of item 1 unless the asset falls under item 2, 3 or 4 or is exempt. An asset hand over
    inside one tenant is not a sale, so the cell stays blank; a sale between organisations is open question Q21 and
    is not registered here, because no asset document of that kind exists or is planned in phase E.
* Every other form (49 of 51): **no VAT field; nothing about VAT is printed.** A price or sum column on such a form
  (for example З-1 price and sum, Инв-10 sums) prints the stored value as entered, without a VAT split.

### 8.5 The table

Letflow document: "none" means the form has no document in Letflow and is outside the assets and stock counting
application of phase A to F (owner decisions D-060 to D-063); its rules are still given so a later build starts from
them. Signer codes from 8.3 in the order of the form; a code in brackets is a blank line signed by hand.

| Annex | ru | kk | Form (short) | Letflow document | BIN/IIN source | Signer rule | VAT rule |
|---|---|---|---|---|---|---|---|
| 1 | КО-1 | КО-1 | cash receipt order | none | LE | (A), (K) | no VAT field |
| 2 | КО-2 | КО-2 | cash payment order | none | LE | (H), (A), receiver (X), (K) | no VAT field |
| 3 | КО-3 | КО-3 | journal of cash documents | none | LE | no signer line | no VAT field |
| 4 | КО-4 | КО-4 | cash book (kk only here) | none | LE | (A), (K) | no VAT field |
| 5 | КО-5 | КО-5 | book of cash given to and taken from the cashier | none | LE | cashier receipts in the table (K) | no VAT field |
| 6 | Д-1 | С-1 | power of attorney (kk only here) | none | LE; receiver and payer: CP | (H), (A), the person receiving it (X) | no VAT field |
| 7 | Д-2 | С-2 | journal of powers of attorney (kk only here) | none | LE | the person receiving it, in the table (X) | no VAT field |
| 8 | Т-1 | Е-1 | payroll sheet (book) | none | LE | no signer line (person by personnel number) | no VAT field |
| 9 | Т-2 | Е-2 | payroll payment sheet | none | LE | (H), (A), compiled by and checked by (A) | no VAT field |
| 10 | Т-3 | Е-3 | advance report | none | LE | (H), (A) | no VAT field |
| 11 | А-1 | А-1 | act of acceptance of assets | none | LE | (H), (X) | no VAT field |
| 12 | А-2 | А-2 | act of acceptance of an asset for installation | none | LE; sender and consignor: CP | (H), C, M | no VAT field |
| 13 | А-3 | А-3 | act of handing an asset over for installation | none | LE | customer and installer (X), M | no VAT field |
| 14 | А-4 | А-4 | act of defects found in an asset (kk only here) | none | LE | M, executor's representative (X) | no VAT field |
| 15 | А-5 | А-5 | act of acceptance of repaired or modernised assets | none | LE | (H), M, C, P, (A) | no VAT field |
| 16 | ДА-1 | ҰМА-1 | act of acceptance and transfer of long-term assets | asset hand over (REQ-753) | LE; receiver: CP or the other legal entity's `bin` | (H) of both parties, M, P | sale value with VAT: rate of art. 503 when it is a sale; internal hand over: blank (8.4) |
| 17 | ДА-2 | ҰМА-2 | inventory card of long-term assets | asset card | LE | M, filled in by (A) | no VAT field |
| 18 | ДА-3 | ҰМА-3 | act of disposal (write-off) of long-term assets | asset write-off (REQ-753) | LE | (H), C (REQ-777), M, (A) | no VAT field |
| 19 | ДА-4 | ҰМА-4 | internal movement invoice of long-term assets | asset hand over or change of responsible (REQ-753) | LE | P, (A) | no VAT field |
| 20 | БА-1 | БА-1 | act of acceptance and transfer of biological assets | none | LE | (H) of both parties, M, P, (A) | no VAT field |
| 21 | БА-2 | БА-2 | inventory card of biological assets | none | LE | M | no VAT field |
| 22 | БА-3 | БА-3 | act of write-off of biological assets | none | LE | (H), C, M, (A) | no VAT field |
| 23 | ОС-1 | НҚ-1 | card of leased fixed assets (kk only here) | none | LE | no signer line | no VAT field |
| 24 | ОС-2 | НҚ-2 | act of write-off of vehicles | none | LE | (H), C, M, (A) | no VAT field |
| 25 | З-1 | Қ-1 | receipt order of stock | receipt | LE | P: "Принял" `responsible_id`, "Сдал" (X) | no VAT field |
| 26 | З-2 | Қ-2 | invoice for issue of stock to a third party | issue (built, section 6) | LE | (H), (A), P: "Отпустил" `responsible_id`, "Запасы получил" blank (G3) | columns 8 and 9: rate of art. 503 per line, REQ-778 |
| 27 | З-3 | Қ-3 | stock card | ledger read (built, section 7) | ru draft: no field; kk: LE | control signature (A) | no VAT field |
| 28 | З-4 | Қ-4 | act of receipt of stock from dismantled fixed assets | none (Q20) | LE | (H), customer and contractor (X) | no VAT field |
| 29 | З-5 | Қ-5 | internal movement invoice of stock | transfer (built, section 7) | LE (sending unit) | (H), (A) "Проверил", P from and to responsible | no VAT field |
| 30 | З-6 | Қ-6 | act of write-off of stock | write-off | LE | (H), C (REQ-776), M `responsible_id` | no VAT field |
| 31 | З-7 | Қ-7 | sheet of stock balances in a warehouse | ledger read | LE | M, (A) | no VAT field |
| 32 | Инв-1 | Түг-1 | count act of stock in transit | none (count kind not built, Q12) | LE | C, M | no VAT field |
| 33 | Инв-2 | Түг-2 | count act of investments | none | LE | M | no VAT field |
| 34 | Инв-3 | Түг-3 | count act of shipped stock | none (Q12) | LE | C | no VAT field |
| 35 | Инв-4 | Түг-4 | count act of receivables and payables | none | LE; each debtor and creditor: CP | C, (A) | no VAT field |
| 36 | Инв-5 | Түг-5 | count act of precious metals (kk only here) | none | LE | M, C | no VAT field |
| 37 | Инв-6 | Түг-6 | count act of cash | none | LE | M, C | no VAT field |
| 38 | Инв-7 | Түг-7 | count list of stock in custody | none (Q12) | LE | M, C | no VAT field |
| 39 | Инв-8 | Түг-8 | count list of long-term assets | asset count (not built) | LE | M, C, checked by (A) | no VAT field |
| 40 | Инв-9 | Түг-9 | count list of biological assets | none | LE | M, C | no VAT field |
| 41 | Инв-10 | Түг-10 | count list of stock | count sheet (built, section 6.1) | LE | M line responsibles, C count order | no VAT field |
| 42 | Инв-11 | Түг-11 | count list of investments | none | LE | M, C, checked by (A) | no VAT field |
| 43 | Инв-12 | Түг-12 | list of long-term assets for a count (kk only here) | none | LE | M | no VAT field |
| 44 | Инв-13 | Түг-13 | count label of stock (kk only here) | none | LE | M, a commission member (C) | no VAT field |
| 45 | Инв-14 | Түг-14 | count list of strict-accounting forms | none | LE | M, C, checked by (A) | no VAT field |
| 46 | Инв-15 | Түг-15 | list of inventory cards of biological assets (kk only here) | none | LE | no signer line | no VAT field |
| 47 | Инв-16 | Түг-16 | comparison sheet of a count of long-term assets | asset differences (not built) | LE | (A), M | no VAT field |
| 48 | Инв-17 | Түг-17 | comparison sheet of a count of biological assets | none | LE | (A), M | no VAT field |
| 49 | Инв-18 | Түг-18 | comparison sheet of a count of stock | count differences (built, section 6.1) | LE | (A), M line responsibles | no VAT field |
| 50 | Р-1 | Ж-1 | act of completed works (services) (kk only here) | none | LE (the form's one ЖСН/БСН) | executor and customer (X) | no VAT field |
| 51 | С-1 | А-1 | accounting certificate | none | LE | (H), (A) (first and second signature) | no VAT field |

"(kk only here)": the Russian draft folder has no file for the annex; its Russian code is from the current Russian
edition (8.1) and its signers are read from the Kazakh text.

### 8.6 What is registered for the gaps

| Gap | Forms | Requirement |
|---|---|---|
| commission of a stock write-off | З-6 / Қ-6 | REQ-776 |
| commission of an asset write-off | ДА-3 / ҰМА-3 | REQ-777 (after REQ-753) |
| price and VAT rate on an issue line, Z-2 columns 7 to 9 | З-2 / Қ-2 | REQ-778 |

Not registered, with the reason: the IIN (8.2: covered by the existing `bin` and `tax_id`); the head, accountant
and cashier lines (8.3: outside decision (c), blank lines by hand); VAT on ДА-1 (8.4: no inter-organisation sale in
phase E, Q21); and every form whose Letflow document is "none" (outside the application of phases A to F). None of
these blocks phase E.

### 7.1 Z-1 on the print engine (T-1912)

`GET /documents/:id/print?form=z1&format=pdf|docx&lang=ru|kk` prints the issued or posted receipt on form Z-1 (ru)
/ Қ-1 (kk), annex 25 of order No. 562 "warehouse receipt order".

**What is filled:** organisation name and BIN, warehouse (location name), document number, date (from `event_time`,
DD.MM.YYYY), supplier name and tax_id (joined with " / "), accompanying document reference (`supplier_document_ref`),
"Принял" / "Қабылдаған" (responsible employee), and per line: item name, nomenclature code, unit, quantity,
unit price, amount.

**What is blank (gap ids from section 2):** kind of operation (G6), account (G6), payment document (G7),
"Сдал" (G4), and per line: qty_doc, mass_doc, mass, passport number, card number (G13). The IIN is not stored (G1).
`received_on` is not printed (the form has no arrival-date cell). Quantities and prices print as the stored
9-decimal text.

**Ru/kk differences between sources (kept as printed):** the kk column 1 header says "Операция түрінің коды"
(code of the kind of operation) where the ru says "Вид операции"; the kk price column header says "Бағасы,
теңгемен" (not "per unit") while the ru says "Цена за единицу, в теңге". Both differences are from the official
texts.

**Proof:** `test/letflow/modules/stock/form_z1_test.exs`, `test/letflow/modules/stock/form_z1_router_test.exs`.

**To be confirmed by an accountant: Z-1 is the form for every receipt, also a receipt with no supplier (audit
section 5).**

### 7.2 Z-6 on the print engine (T-1914)

`GET /documents/:id/print?form=z6&format=pdf|docx&lang=ru|kk` prints the issued, posted or reversed write-off on form
Z-6 (ru) / Қ-6 (kk), annex 30 of order No. 562 "act of writing off stock". Same route, permission (`StockRead`) and
read path as 7.1.

**What is filled:** organisation name and BIN, structural unit (org unit and location name joined with " / "),
document number, date (from `event_time`, DD.MM.YYYY), the responsible person (header field and the signature
line), and per line: item name, nomenclature code, unit, quantity as the stored text, and the reason of the
write-off. A write-off has one reason for the whole document (`reason_code`, plus `reason_text` when given), so
every line prints that stored reason in the form language.

**What is blank (gap ids from section 2):** approver and approval date (G4), basis (G7), date of acquisition and
service life per line (G13), price and sum (G5: a write-off line stores no price), every "in words" line of the back
side (G10), commission decision, scrap rows, commission chair and members (G14, REQ-776 not built), position of the
responsible person (G4).

**Ru/kk differences between sources (kept as printed):** the kk title of the number cell is "Құжаттың нөмірі"
(not the Z-2 wording), so the message key `z6.number` is its own; in the kk text the back-side heading follows the
"in words" lines, the layout keeps the ru order.

**Proof:** `test/letflow/modules/stock/form_z6_test.exs`, `test/letflow/modules/stock/form_z6_router_test.exs`, the
P3 step of `web/tests/e2e/gate-b-stock-print.e2e.spec.ts`.


### 7.3 ДА-1 / ҰМА-1 on the print engine (T-1921)

`GET /api/v1/modules/assets/documents/:id/print?form=da1&format=pdf|docx&lang=ru|kk` prints an issued, posted or
reversed **commission** or **hand over** on form ДА-1 (ru) / ҰМА-1 (kk), annex 16 of order No. 562 "act of acceptance
and transfer of long-term assets". Same route and permission (`AssetsRead`) as the plain act (T-1915); no `form` key
keeps the plain act. Other kinds answer 422 `print_not_available`, a draft `document_not_issued`, a bad `form`,
`format` or `lang` (`en` is refused: the form has no English) 422 `invalid_form`, `invalid_format`, `invalid_lang`.
The screen offers it in the "Official form" menu next to Print. Layout `priv/print_forms/da1.json`, mapper
`Letflow.Modules.Assets.FormDa1`, read `DocumentPrintSource.read/4` (`form: true`).

**Filled in (stored facts only):** BIN and name of the legal entity of the unit (receiving side on a commissioning;
giving and receiving side on a hand over), the location (`location_id`, on a hand over `to_location_id`; empty prints
blank, no fallback), "Сдал" / "Принял" with name and position, column 4 (the giving side's materially responsible
person, hand over only), per card name, inventory number, acquisition date, and the money columns 7, 9 and 10.

**Money rules:** the headers say "в теңге", so the values print only when the card currency is KZT. Depreciation and
book value print only when the card's `depreciation_as_of` is empty or not later than the act's local date. The card
values are the live card values at print time.

**Blank (gaps):** basis columns 1-3 and the basis of the move (G7), useful life (col 8), factory and passport numbers
(cols 12 and 15, G11), debit and credit accounts (G6), sale value with VAT (col 16), both head approvals (G4), the
inspection order, brief characteristic, precious materials, conformity, rework, tests, conclusion and document list,
the commission chair and members, the power of attorney, custody and both chief accountant marks. A commissioning has no
giving side (the supplier is not stored): giving organisation, "Сдал" and column 4 are blank.

**Q21 (inter-organisation transfer) stays open:** the receiver BIN, both approvals, the sale value with VAT and the
power of attorney print blank. The receiving organisation's name is printed from the legal entity of the receiving
unit, because that is a stored fact.

**To be confirmed by accountant (PM decision 2026-11-14, not blocking):** that ДА-1 is the right form for commissioning,
and that ДА-1 is printed on an in-tenant hand over (the audit names ДА-4 for internal moves; both are offered on a hand
over since T-1922).

**Proof:** `test/letflow/modules/assets/form_da1_test.exs`, `test/letflow/modules/assets/form_da1_router_test.exs`
(real tokens, cross-tenant 404 both ways), `web/src/modules/assets/__tests__/AssetFormMenu.test.tsx`, E6 and E7 of
`web/tests/e2e/gate-b-assets-print.e2e.spec.ts`.

### 7.4 ДА-4 / ҰМА-4 on the print engine (T-1922)

**Route:** `GET /api/v1/modules/assets/documents/:id/print?form=da4&format=pdf|docx&lang=ru|kk` (permission
`AssetsRead`, same route as ДА-1). Kinds: `change` and `handover`, in issued, posted and reversed state. Layout
`priv/print_forms/da4.json` (annex 19), data `Letflow.Modules.Assets.FormDa4`. Web: the "Official form" menu of the
document screen; a change offers ДА-4 only, a hand over offers ДА-1 and ДА-4.

**Filled, from stored facts:** name and BIN of the giving unit's legal entity, sender and receiver unit and location,
the giving materially responsible person ("Ответственный за поставку"), the document's own number and date, the note,
"Сдал" and "Принял" with positions, and per card the name, acquisition date, inventory number and the quantity.

**Blank (never invented):** price and cost (**Q22**, which cost goes there, is open; the total row shows the quantity
and `х` under the price), factory and passport numbers, unit of measure (the card has none), the basis, the amounts in
words and the chief accountant mark. A hand over between two legal entities (Q21) prints the giving unit's
organisation; the form has no field for the receiving one.

**To be confirmed by accountant (PM decision 2026-11-14, not blocking):** that ДА-4 is the right form for a change of
responsible and for an in-tenant hand over; that the number and date under "Основание" are the invoice's own (the Z-5
precedent); that "Ответственный за поставку" is the giving materially responsible person.

**Proof:** `test/letflow/modules/assets/form_da4_test.exs`, `test/letflow/modules/assets/form_da4_router_test.exs`
(real tokens, cross-tenant 404 both ways), `web/src/modules/assets/__tests__/AssetFormMenu.test.tsx`, E8 and E9 of
`web/tests/e2e/gate-b-assets-print.e2e.spec.ts`.

### 7.5 ДА-3 / ҰМА-3 on the print engine (T-1923)

**Route:** `GET /api/v1/modules/assets/documents/:id/print?form=da3&format=pdf|docx&lang=ru|kk` (permission
`AssetsRead`, same route as ДА-1). Kind: `writeoff`, in issued, posted and reversed state. Layout
`priv/print_forms/da3.json` (annex 18), data `Letflow.Modules.Assets.FormDa3`. Web: the "Official form" menu of the
document screen; a write-off offers ДА-3 only.

**Filled, from stored facts:** name and BIN of the unit's legal entity, the document's own number and date, the
write-off reason in the form language (label, then the free text), the materially responsible person with position,
and per card the name, acquisition date, inventory number, original cost, accumulated depreciation and book value
(the ДА-1 rule: KZT cards only; depreciation and book value only when `depreciation_as_of` is not after the act date).

**Blank (never invented):** the whole commission block (order, chair, members, inspection, asset state, conclusion)
until **REQ-777** stores it; the approver and date, release date, actual service life (the commissioning date is not
stored), factory number, accessories and precious materials, repairs, the attached document list, the costs and income
of the write-off and the chief accountant mark. Layout limits: the engine has one header level, so the nested header
"Запасы" of the costs/income table is folded into its column labels, and the "Итого" row of that table is left out
(it has no data).

**To be confirmed by accountant (PM decision 2026-11-14, not blocking):** that ДА-3 is the right form for an asset
write-off; that the stored write-off reason goes in "Причина списания"; that the live card money is printed (not a
value as of the act date).

**Proof:** `test/letflow/modules/assets/form_da3_test.exs`, `test/letflow/modules/assets/form_da3_router_test.exs`
(real tokens, cross-tenant 404 both ways), `web/src/modules/assets/__tests__/AssetFormMenu.test.tsx`, E10 and E11 of
`web/tests/e2e/gate-b-assets-print.e2e.spec.ts`.
