# KZ Ministry of Finance forms: mapping to Letflow documents and data

Status: analysis, not built (assets phase E item E5a, owner decision D-104). Docs only: no code, no migration, no
definition JSON, no print template, no route, no screen. A later build of any official form is a later requirement
written from this file after the owner has answered the questions in section 4.

## 0. Sources and caveats

* Layout source (owner D-104): the 2026 **draft** forms of the Ministry of Finance of the Republic of Kazakhstan,
  the annexes to order No. 562 of 20 December 2012 as the draft amending order has them. The folder is
  `/home/tvolodi/Documents/KZ-MinFin-DocTemplates/` (read only; the files are not copied into this repository).
  The catalog is `ai-dala-portfolio/inbox/kz-minfin-forms/CATALOG.md` (with `forms.json`).
* The files are **Russian only**. The Kazakh versions of the annexes are not in the folder, so no Kazakh wording of
  any form is known. The draft is not final: dates in the draft package are blank. **If the final order text
  differs from these drafts, this file must be redone; ask the operator.**
* Method: every form was opened with a script (python3, `zipfile` and `xml.etree`, standard library only, read only)
  and its header block, table columns (with the column numbers printed in the form), free-text blanks and signature
  lines were listed. The titles below are read from the files; the catalog has no title for Z-1, Z-4, Z-6 and Z-7,
  the files give them (section 3.4).
* Letflow facts come from `docs/assets/stock-workflow-documents.md`, `docs/assets/asset-workflow-documents.md`,
  `docs/assets/asset-register.md`, `docs/assets/government-lists.md`, the entity definitions under
  `priv/modules/*/entity_definitions/`, and the print code of E1a/E1b
  (`lib/letflow/modules/stock/count_print.ex`, `document_print.ex`, `document_print_source.ex`).
* Marks: **proposal** = the business analyst's proposal; **default** = what the print does until the owner answers
  (always: leave the field blank, never invent a value). No answer is given here to any owner question.
* The forms are shown by their Russian names (Z = "З", Inv = "Инв", DA = "ДА"), as the catalog does.

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
| Asset card | `assets_card` | `inventory_number`, `name`, `kind`, `org_unit_id`, `acquisition_date`, `currency`, `acquisition_cost`, `accumulated_depreciation`, `book_value`, `depreciation_as_of`, `valid_until`, `active` |
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
| G16 | **Kazakh wording**: the Kazakh versions of the annexes are not in the folder | Q16 Where is the official Kazakh text of each annex? | a form prints in Russian and English only until it is supplied (the existing prints are Russian, Kazakh and English machine drafts, not official) |
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
| Table cols 5, 7 | Излишек: количество | `counted_quantity - book_quantity` when positive | have (computed) |
| Table cols 6, 8 | Излишек / недостача: сумма, в теңге | no price on count lines | **missing** (G5) |
| Table cols 9, 11 | Недостача: количество | `book_quantity - counted_quantity` when positive | have (computed) |
| Table cols 10 | Недостача: сумма | none | **missing** (G5) |
| Table cols 12 to 14 | Отрегулировано за счет корректировок в бухгалтерском учете: счет, количество, сумма | none | **missing** (G6, G15) |
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

## 4. Summary table

Form: the Russian form. Document: the Letflow document it prints. "Have": fields filled from data. "Missing": gap ids
of section 2 with the owner question.

| Form | Document | Fields we have | Fields missing | Owner question |
|---|---|---|---|---|
| Z-2 | issue | number, date, organisation name, BIN, responsible, item, unit, quantity | recipient, IIN, transport, TTN, "to release" quantity, price, VAT, sums, words, signers, power of attorney | Q1, Q3, Q4, Q5, Q7 to Q10 |
| Z-5 | transfer (proposal: also hand over, return) | number, date, both units, responsible persons, item, unit, quantity | basis, "to release" quantity, price, sums, words, approver and checker | Q1, Q4, Q5, Q7, Q9, Q10, Q19 |
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
Q22 (asset cost on DA-4: `book_value` or `acquisition_cost`).

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
