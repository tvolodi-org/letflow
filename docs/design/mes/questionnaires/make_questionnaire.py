#!/usr/bin/env python3
"""Build the chemical-plant questionnaire workbook (stdlib only: zipfile + xml)."""
import sys
import zipfile
from xml.sax.saxutils import escape

# (section_ru, section_en, question_ru, question_en, hint_ru, hint_en)
S = {
    1: ("Продукция и объёмы", "Products and volumes"),
    2: ("Площадки и линии", "Sites and lines"),
    3: ("Ёмкости и потоки", "Tanks and flows"),
    4: ("Гранулированные партии", "Granular batches"),
    5: ("Фасовка и паллеты", "Bagging and pallets"),
    6: ("Качество и выпуск", "Quality and release"),
    7: ("Записи и надзорные органы", "Records and authorities"),
    8: ("Отзыв продукции", "Recall"),
    9: ("Оборудование и данные", "Machines and data"),
    10: ("ERP и бухгалтерия", "ERP and accounting"),
    11: ("Пользователи и языки", "Users and languages"),
    12: ("Цели", "Goals"),
}
T_ = ("Текст", "Text")
N_ = ("Число", "Number")
YN = ("Да / нет + пояснение", "Yes / no + note")
LST = ("Список", "List")
Q = [
    # 1 products and volumes
    (1, "Какую продукцию вы выпускаете: жидкую, гранулированную или обе?",
        "Which products do you make: liquid, granular, or both?", ("Выбор + текст", "Choice + text")),
    (1, "Сколько у вас марок (видов) продукции в каждой группе? Назовите основные.",
        "How many grades (types) of product do you have in each group? Name the main ones.", ("Число + список", "Number + list")),
    (1, "Сколько продукции вы выпускаете в месяц (по каждой группе)? Укажите единицу: кг, литры или тонны.",
        "How much product do you make per month (per group)? Please give the unit: kg, litres or tonnes.", ("Число + единица", "Number + unit")),
    (1, "Как часто меняются рецептуры? Кто утверждает новую версию рецептуры?",
        "How often do recipes change? Who approves a new recipe version?", T_),
    (1, "Какие сырьевые материалы поступают от поставщиков партиями (лотами)? Храните ли вы сертификаты и результаты анализов поставщика?",
        "Which raw materials arrive from suppliers in lots? Do you keep the supplier certificates and test results?", T_),
    # physical data (placed in section 1 and 3/5)
    (1, "Какая плотность каждого жидкого продукта (кг/л, при какой температуре)? Есть ли у вас таблица плотностей?",
        "What is the density of each liquid product (kg/l, at which temperature)? Do you have a density table?", ("Число по продуктам", "Numbers per product")),
    (1, "В каких единицах вы считаете: килограммы, литры, тонны? Что используется в заказе, на складе, в документах покупателю? Как вы пересчитываете одно в другое?",
        "Which units do you use: kilograms, litres, tonnes? Which one in the order, in stock, and on documents for the customer? How do you convert one to another?", T_),
    (1, "Вы продаёте по массе или по объёму? Бывают ли исключения для отдельных продуктов или покупателей?",
        "Do you sell by mass or by volume? Are there exceptions for some products or customers?", ("Выбор + текст", "Choice + text")),
    # 2 sites and lines
    (2, "Сколько у вас площадок (заводов, складов) и сколько производственных линий на каждой?",
        "How many sites (plants, warehouses) do you have, and how many production lines on each?", ("Число + список", "Number + list")),
    (2, "Работает ли линия в несколько смен? Сколько смен, как проходит передача смены, кто подписывает?",
        "Does a line work in several shifts? How many shifts, how is the handover done, who signs?", T_),
    (2, "Одна линия делает одну марку или разные? Как происходит переход с марки на марку (промывка, очистка)?",
        "Does one line make one grade or several? How do you switch from one grade to another (washing, cleaning)?", T_),
    # 3 tanks and flows
    (3, "Сколько у вас ёмкостей: для сырья, промежуточных и для готовой продукции?",
        "How many tanks do you have: raw material, intermediate, and finished product?", ("Три числа", "Three numbers")),
    (3, "Какой объём у каждой ёмкости (в литрах или м³)? Если ёмкости разные, перечислите размеры и сколько штук каждого.",
        "What is the volume of each tank (litres or m³)? If the tanks differ, list the sizes and how many of each.", ("Таблица или список", "Table or list")),
    (3, "Сколько литров/кг в большой ёмкости по отношению к малой? Например: одна большая ёмкость = сколько малых?",
        "How does a big tank relate to a small tank in litres/kg? For example: one big tank = how many small tanks?", ("Число + пояснение", "Number + note")),
    (3, "Наполняется ли ёмкость с готовой продукцией и опорожняется ли она одновременно?",
        "Is a finished product tank filled and emptied at the same time?", YN),
    (3, "Как вы делите непрерывный поток на единицу, которую можно продать и проследить: по наполнению ёмкости, по смене или по дню?",
        "How do you cut a continuous flow into a unit you can sell and trace: by tank fill, by shift, or by day?", ("Выбор + текст", "Choice + text")),
    (3, "Чем вы измеряете каждый вход в смесь: расходомер, весы, уровень в ёмкости? Какая примерная точность?",
        "How do you measure each input to a blend: flow meter, scale, tank level? What is the approximate accuracy?", T_),
    (3, "Как вы сейчас считаете баланс масс (бумага, Excel, ERP)? По ёмкости, смене или дню? Какие потери допустимы?",
        "How do you do the mass balance today (paper, Excel, ERP)? Per tank, shift or day? What loss is acceptable?", T_),
    # 4 granular batches
    (4, "Что для вас одна партия (batch) гранулированной продукции: загрузка смесителя, смена или сутки? Какой она величины (в тоннах)?",
        "What is one granular batch for you: one mixer load, one shift, or one day? How big is it (in tonnes)?", ("Выбор + число", "Choice + number")),
    (4, "Процесс одинаковый для всех марок (смешивание, гранулирование, сушка, рассев) или он меняется? Сколько машин участвует в одной партии?",
        "Is the process the same for all grades (mixing, granulating, drying, screening) or does it change? How many machines take part in one batch?", T_),
    (4, "Сколько партий в день вы делаете? Сколько мешков?",
        "How many batches per day do you make? How many bags?", N_),
    (4, "Что происходит с некондиционным по размеру продуктом, пылью и возвратом? Возвращаете ли вы их в следующую партию?",
        "What happens to off-size product, dust and returns? Do you put them back into the next batch?", T_),
    # 5 bagging and pallets
    (5, "Какие размеры упаковки вы используете (мешки, большие мешки, бочки, канистры, навалом)? Укажите массу или объём каждого.",
        "Which package sizes do you use (bags, big bags, drums, canisters, bulk)? Please give the mass or volume of each.", ("Список", "List")),
    (5, "Как упаковки соотносятся друг с другом? Например: один большой мешок = сколько средних мешков = 1 тонна; один паллет = сколько мешков.",
        "How do package sizes relate to each other? For example: one big bag = how many middle bags = 1 tonne; one pallet = how many bags.", ("Числа + пояснение", "Numbers + note")),
    (5, "Фасуете ли вы одну партию в несколько размеров? Есть ли отгрузка в больших мешках или навалом?",
        "Do you pack one batch into several sizes? Do you ship in big bags or in bulk?", YN),
    (5, "Как формируется и маркируется паллет сегодня (мешков на паллете, этикетка, код)?",
        "How is a pallet built and labelled today (bags per pallet, label, code)?", T_),
    (5, "Просят ли покупатели штрихкод или код SSCC (18-значный код логистической единицы, паллета)? Какие именно?",
        "Do customers ask for a barcode or an SSCC (18-digit code of a logistic unit, such as a pallet)? Which ones?", YN),
    # 6 quality and release
    (6, "Какие анализы вы проводите, как часто (на партию, ёмкость, смену)? Какая лаборатория: своя или внешняя?",
        "Which tests do you run, how often (per batch, tank, shift)? Is the lab your own or external?", T_),
    (6, "Кто разрешает выпуск партии или ёмкости: один человек или двое? Укажите должности.",
        "Who releases a batch or a tank: one person or two? Please give the job titles.", T_),
    (6, "Что вы делаете с продукцией вне спецификации (переработка, добавление в другую партию, брак)?",
        "What do you do with product that is out of specification (rework, blend back, reject)?", T_),
    (6, "Выдаёте ли вы покупателю сертификат качества? Какая в нём информация?",
        "Do you give the customer a certificate of quality? What information does it contain?", YN),
    # 7 records and authorities
    (7, "Показываете ли вы записи органу надзора, сертифицирующей организации или покупателю (аудит)? Каким именно?",
        "Do you show records to an authority, a certification body, or a customer audit? To which ones?", YN),
    (7, "Какие правила или стандарты вы выполняете (в какой стране)? Как долго нужно хранить записи?",
        "Which rules or standards do you follow (in which country)? How long must records be kept?", T_),
    (7, "Есть ли экспорт? Если да, в какие страны?",
        "Do you export? If yes, to which countries?", YN),
    # 8 recall
    (8, "Как вы сегодня действуете при жалобе или отзыве продукции?",
        "How do you handle a complaint or a recall today?", T_),
    (8, "За какое время вы должны назвать все затронутые паллеты или партии (в часах)?",
        "How fast must you name all affected pallets or batches (in hours)?", ("Число часов", "Number of hours")),
    (8, "Можете ли вы сегодня по готовой продукции найти сырьевые партии, а по сырьевой партии найти всех покупателей? Сколько это занимает?",
        "Today, can you go from a finished product to its raw material lots, and from a raw material lot to all customers? How long does it take?", YN),
    # 9 machines and data
    (9, "Какие значения (веса, количества, уровни) приходят от машин, а какие записываются вручную?",
        "Which values (weights, counts, levels) come from machines and which are written by hand?", T_),
    (9, "Какая у вас система управления (марка, PLC, SCADA)? Есть ли архив данных (historian)? Какой?",
        "What control system do you have (brand, PLC, SCADA)? Is there a data historian? Which one?", T_),
    (9, "Может ли система выгружать файлы по расписанию? В каком формате и куда?",
        "Can it export files on a schedule? In which format and to where?", T_),
    (9, "Есть ли сервер OPC UA или брокер MQTT? Кто на заводе отвечает за технологическую сеть и может разрешить подключение?",
        "Do you have an OPC UA server or an MQTT broker? Who at the plant is responsible for the plant network and can allow a connection?", T_),
    (9, "Сколько сигналов (тегов) могло бы понадобиться и как часто они меняются?",
        "How many signals (tags) might be needed and how often do they change?", ("Число + частота", "Number + frequency")),
    (9, "Есть ли на производстве стабильный интернет?",
        "Is there stable internet on the production floor?", YN),
    # 10 erp
    (10, "Какая ERP или бухгалтерская система хранит заказы и остатки?",
         "Which ERP or accounting system holds orders and stock?", T_),
    (10, "Какие данные должны передаваться между производственной системой и ERP (в обе стороны)?",
         "Which data must flow between a production system and the ERP (in both directions)?", T_),
    (10, "Кто ведёт учёт остатков и как часто проводится инвентаризация?",
         "Who keeps the stock records and how often is a stock count made?", T_),
    # 11 users and languages
    (11, "Сколько человек будут работать в системе на производстве и в офисе? Назовите роли.",
         "How many people would use the system on the floor and in the office? Please name the roles.", ("Число + роли", "Number + roles")),
    (11, "С каких устройств они работают: телефон, планшет, компьютер?",
         "Which devices do they use: phone, tablet, PC?", LST),
    (11, "На каких языках нужен интерфейс (русский, узбекский, казахский, английский, другой)?",
         "Which languages are needed in the screens (Russian, Uzbek, Kazakh, English, other)?", LST),
    # 12 goals
    (12, "Как вы сегодня записываете производство (бумага, Excel, ERP, другое)?",
         "How do you record production today (paper, Excel, ERP, other)?", T_),
    (12, "Что причиняет больше всего проблем: отзыв, аудит, потерянное время, ошибочная отгрузка, другое?",
         "What hurts most: recall, audit, lost time, wrong shipment, other?", ("Выбор + текст", "Choice + text")),
    (12, "Что для вас будет успехом через 6 месяцев?",
         "What would success look like after 6 months?", T_),
    (12, "Есть ли что-то важное, о чём мы не спросили?",
         "Is there anything important we did not ask?", T_),
]

HDR_RU = ["№", "Раздел", "Вопрос", "Тип ответа", "Ответ", "Комментарий"]
HDR_EN = ["No.", "Section", "Question", "Answer type", "Answer", "Comment"]

INS_RU = [
    ("Анкета для химического предприятия", "h"),
    ("Цель: понять, как устроено ваше производство. Ответы помогут нам это понять.", ""),
    ("Как заполнять", "h"),
    ("1. Откройте лист «Вопросы RU». Пишите ответ в столбце «Ответ», уточнения в столбце «Комментарий».", ""),
    ("2. На заполнение уйдёт примерно 45 минут. Один человек может ответить на всё, но лучше привлечь технолога, лабораторию и склад.", ""),
    ("3. Достаточно коротких ответов и примерных цифр. Если не знаете, напишите «не знаю». Если вопрос не подходит, напишите «не применимо».", ""),
    ("4. Всегда указывайте единицу: кг, литры или тонны. Для упаковки пишите, сколько в одной упаковке.", ""),
    ("5. Не вписывайте пароли и личные данные. Не отправляйте секретные рецептуры, достаточно названий групп.", ""),
    ("6. Английская версия на листе «Questions EN» имеет ту же нумерацию. Отвечать можно на любом языке.", ""),
    ("Термины", "h"),
    ("Партия (batch): количество продукции, сделанное за один производственный цикл и учитываемое как одно целое.", ""),
    ("Лот (lot): определённое количество сырья или продукции с одним номером (например, от одного поставщика, одна поставка).", ""),
    ("SSCC: 18-значный код логистической единицы, например паллета; печатается штрихкодом на этикетке.", ""),
    ("PLC: программируемый контроллер, управляет оборудованием.", ""),
    ("SCADA: система, которая показывает и собирает данные с контроллеров.", ""),
    ("Historian: архив значений сигналов за время.", ""),
    ("QC: контроль качества (лаборатория и проверки).", ""),
    ("ERP: система учёта предприятия (заказы, склад, финансы).", ""),
]
INS_EN = [
    ("Questionnaire for a chemical plant", "h"),
    ("Purpose: to understand how your production works. Your answers help us understand it.", ""),
    ("How to fill it in", "h"),
    ("1. Open the sheet 'Questions EN'. Write your answer in the 'Answer' column and any extra detail in the 'Comment' column.", ""),
    ("2. It takes about 45 minutes. One person can answer everything, but it is better to involve a technologist, the lab and the warehouse.", ""),
    ("3. Short answers and approximate numbers are enough. If you do not know, write 'do not know'. If a question does not apply, write 'not applicable'.", ""),
    ("4. Always give the unit: kg, litres or tonnes. For packages, say how much is in one package.", ""),
    ("5. Please do not enter passwords or personal data. Do not send secret recipes; group names are enough.", ""),
    ("6. The Russian version on the sheet 'Вопросы RU' has the same numbering. You may answer in any language.", ""),
    ("Terms", "h"),
    ("Batch: the quantity of product made in one production cycle and handled as one unit.", ""),
    ("Lot: a defined quantity of raw material or product with one number (for example, one delivery from one supplier).", ""),
    ("SSCC: 18-digit code of a logistic unit, such as a pallet; printed as a barcode on the label.", ""),
    ("PLC: programmable controller that runs the equipment.", ""),
    ("SCADA: a system that shows and collects data from controllers.", ""),
    ("Historian: an archive of signal values over time.", ""),
    ("QC: quality control (the lab and checks).", ""),
    ("ERP: the company's business system (orders, stock, finance).", ""),
]


def col(n):
    return "ABCDEF"[n]


def cell(ref, text, style):
    return '<c r="%s" s="%d" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' % (ref, style, escape(text))


def sheet_xml(rows, widths, freeze, header=True):
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
           '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
           '<sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>',
           '<sheetViews><sheetView workbookViewId="0">']
    if freeze:
        out.append('<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>')
    out.append('</sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>')
    for i, w in enumerate(widths, 1):
        out.append('<col min="%d" max="%d" width="%s" customWidth="1"/>' % (i, i, w))
    out.append('</cols><sheetData>')
    for r, (cells, style) in enumerate(rows, 1):
        out.append('<row r="%d">' % r)
        for c, t in enumerate(cells):
            st = style[c] if isinstance(style, list) else style
            out.append(cell("%s%d" % (col(c), r), t, st))
        out.append('</row>')
    out.append('</sheetData>')
    if header and freeze:
        out.append('<printOptions gridLines="1"/>')
    out.append('<pageMargins left="0.4" right="0.4" top="0.5" bottom="0.5" header="0.3" footer="0.3"/>')
    out.append('<pageSetup paperSize="9" orientation="landscape" fitToWidth="1" fitToHeight="0"/>')
    if freeze:
        out.append('<headerFooter><oddFooter>&amp;P / &amp;N</oddFooter></headerFooter>')
    out.append('</worksheet>')
    return "".join(out)


STYLES = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="14"/><name val="Calibri"/></font></fonts>
<fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFD9E2F3"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF9DB"/></patternFill></fill></fills>
<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FFAAAAAA"/></left><right style="thin"><color rgb="FFAAAAAA"/></right><top style="thin"><color rgb="FFAAAAAA"/></top><bottom style="thin"><color rgb="FFAAAAAA"/></bottom><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="6">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
</cellXfs></styleSheet>'''


def instr_rows(lines):
    rows = []
    for i, (t, k) in enumerate(lines):
        rows.append(([t], 4 if (k == "h" and i == 0) else 5 if k == "h" else 0))
    return rows


def qrows(lang):
    i = 0 if lang == "ru" else 1
    rows = [(HDR_RU if lang == "ru" else HDR_EN, 1)]
    for n, q in enumerate(Q, 1):
        sec, qru, qen, hint = q[0], q[1], q[2], q[3]
        rows.append(([str(n), S[sec][i], qru if lang == "ru" else qen, hint[i], "", ""],
                     [2, 2, 2, 2, 3, 3]))
    return rows


def main(path):
    sheets = [
        ("Instruction RU", sheet_xml(instr_rows(INS_RU), [110], False)),
        ("Instruction EN", sheet_xml(instr_rows(INS_EN), [110], False)),
        ("Вопросы RU", sheet_xml(qrows("ru"), [6, 24, 70, 24, 50, 35], True)),
        ("Questions EN", sheet_xml(qrows("en"), [6, 24, 70, 24, 50, 35], True)),
    ]
    ct = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>']
    for i in range(len(sheets)):
        ct.append('<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' % (i + 1))
    ct.append('</Types>')
    wb = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>']
    rels = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">']
    for i, (name, _) in enumerate(sheets, 1):
        wb.append('<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % (escape(name), i, i))
        rels.append('<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>' % (i, i))
    wb.append('</sheets></workbook>')
    rels.append('<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>' % (len(sheets) + 1))
    root = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", "".join(ct))
        z.writestr("_rels/.rels", root)
        z.writestr("xl/workbook.xml", "".join(wb))
        z.writestr("xl/_rels/workbook.xml.rels", "".join(rels))
        z.writestr("xl/styles.xml", STYLES)
        for i, (_, x) in enumerate(sheets, 1):
            z.writestr("xl/worksheets/sheet%d.xml" % i, x)
    print("questions:", len(Q))


if __name__ == "__main__":
    main(sys.argv[1])
