/** usersImportMessages -- T-1633 / REQ-791. Catalog of the users import screen, en/ru/kk, same id set in each.
 *  Reason texts come from one table so a reason cannot miss a language. The kk texts are machine drafts until the
 *  owner's native check (docs/assets/i18n-gaps.md), as in usersMessages.ts. */
export const USERS_IMPORT_LOCALES = ['en', 'ru', 'kk'] as const
export type UsersImportLocale = (typeof USERS_IMPORT_LOCALES)[number]

type Triple = readonly [en: string, ru: string, kk: string]

const UI: Record<string, Triple> = {
  'usersImport.title': ['Import users', 'Импорт пользователей', 'Пайдаланушыларды импорттау'],
  'usersImport.eyebrow': ['Tenant administration · Users', 'Администрирование · Пользователи', 'Тенант әкімшілігі · Пайдаланушылар'],
  'usersImport.lede': [
    'Create several users from an Excel file. The file is checked first; nothing is written until the check is clean.',
    'Создайте несколько пользователей из файла Excel. Сначала файл проверяется; ничего не записывается, пока проверка не пройдёт без ошибок.',
    'Excel файлынан бірнеше пайдаланушы жасаңыз. Файл алдымен тексеріледі; тексеру қатесіз өтпейінше ештеңе жазылмайды.',
  ],
  'usersImport.steps.label': ['Import steps', 'Шаги импорта', 'Импорт қадамдары'],
  'usersImport.steps.file': ['File', 'Файл', 'Файл'],
  'usersImport.steps.check': ['Check', 'Проверка', 'Тексеру'],
  'usersImport.steps.import': ['Import', 'Импорт', 'Импорт'],
  'usersImport.card.file': ['Your file', 'Ваш файл', 'Сіздің файлыңыз'],
  'usersImport.drop.title': ['Drop an .xlsx file here', 'Перетащите файл .xlsx сюда', '.xlsx файлын осында сүйреңіз'],
  'usersImport.drop.invalid': ['Choose an .xlsx file.', 'Выберите файл .xlsx.', '.xlsx файлын таңдаңыз.'],
  'usersImport.template.button': ['Download template', 'Скачать шаблон', 'Үлгіні жүктеу'],
  'usersImport.template.failed': [
    'The template could not be downloaded. Try again.',
    'Не удалось скачать шаблон. Повторите попытку.',
    'Үлгіні жүктеу мүмкін болмады. Қайталап көріңіз.',
  ],
  'usersImport.check': ['Check file', 'Проверить файл', 'Файлды тексеру'],
  'usersImport.busy': ['Working…', 'Выполняется…', 'Орындалуда…'],
  'usersImport.confirm': ['Import users', 'Импортировать', 'Импорттау'],
  'usersImport.back': ['Back to users', 'К списку пользователей', 'Пайдаланушылар тізіміне'],
  'usersImport.counts.label': ['Row counts', 'Количество строк', 'Жолдар саны'],
  'usersImport.counts.wouldCreated': ['Would be created', 'Было бы создано', 'Жасалар еді'],
  'usersImport.outcome.created': ['Created', 'Создано', 'Жасалды'],
  'usersImport.outcome.unchanged': ['Unchanged', 'Без изменений', 'Өзгеріссіз'],
  'usersImport.outcome.refused': ['Refused', 'Отклонено', 'Қабылданбады'],
  'usersImport.outcome.would_created': ['Would create', 'Было бы создано', 'Жасалар еді'],
  'usersImport.col.outcome': ['Outcome', 'Результат', 'Нәтиже'],
  'usersImport.col.line': ['Row', 'Строка', 'Жол'],
  'usersImport.col.column': ['Column', 'Колонка', 'Баған'],
  'usersImport.col.reason': ['Reason', 'Причина', 'Себебі'],
  'usersImport.results.empty': ['The file has no data rows.', 'В файле нет строк данных.', 'Файлда деректер жолдары жоқ.'],
  'usersImport.dryRun.title': ['Check result', 'Результат проверки', 'Тексеру нәтижесі'],
  'usersImport.dryRun.nothingWritten': ['Nothing was written.', 'Ничего не записано.', 'Ештеңе жазылған жоқ.'],
  'usersImport.dryRun.readyPill': ['Ready to import', 'Готово к импорту', 'Импортқа дайын'],
  'usersImport.dryRun.needsFix': ['Needs fixing', 'Нужно исправить', 'Түзету керек'],
  'usersImport.dryRun.ready': [
    'Every row is correct. Press Import users to create them.',
    'Все строки верны. Нажмите «Импортировать», чтобы создать пользователей.',
    'Барлық жол дұрыс. Пайдаланушыларды жасау үшін «Импорттау» түймесін басыңыз.',
  ],
  'usersImport.dryRun.fix': [
    'Fix the refused rows in your file and check it again.',
    'Исправьте отклонённые строки в файле и проверьте его снова.',
    'Қабылданбаған жолдарды файлда түзетіп, қайта тексеріңіз.',
  ],
  'usersImport.dryRun.why': [
    'Import stays off while any row is refused.',
    'Импорт недоступен, пока есть отклонённые строки.',
    'Қабылданбаған жол бар кезде импорт өшірулі тұрады.',
  ],
  'usersImport.summary.title': ['Import result', 'Результат импорта', 'Импорт нәтижесі'],
  'usersImport.summary.done': ['The users were created.', 'Пользователи созданы.', 'Пайдаланушылар жасалды.'],
  'usersImport.summary.toast': ['Users imported', 'Пользователи импортированы', 'Пайдаланушылар импортталды'],
  'usersImport.notApplied': ['Nothing was imported.', 'Ничего не импортировано.', 'Ештеңе импортталған жоқ.'],
  'usersImport.reupload': [
    'Fix the rows in your file and upload it again. Users that already exist with the same data are shown as unchanged.',
    'Исправьте строки в файле и загрузите его снова. Пользователи, которые уже есть с теми же данными, показываются как «без изменений».',
    'Файлдағы жолдарды түзетіп, қайта жүктеңіз. Дәл сондай деректермен бар пайдаланушылар «өзгеріссіз» деп көрсетіледі.',
  ],
  'usersImport.download.refused': ['Download refused rows (CSV)', 'Скачать отклонённые строки (CSV)', 'Қабылданбаған жолдарды жүктеу (CSV)'],
  'usersImport.csv.line': ['Row', 'Строка', 'Жол'],
  'usersImport.csv.column': ['Column', 'Колонка', 'Баған'],
  'usersImport.csv.reason': ['Reason', 'Причина', 'Себебі'],
  'usersImport.help.title': ['About the file', 'О файле', 'Файл туралы'],
  'usersImport.help.columns': [
    'Columns: username, display_name, email. Download the template for the exact names.',
    'Колонки: username, display_name, email. Точные названия — в шаблоне.',
    'Бағандар: username, display_name, email. Нақты атаулар үлгіде.',
  ],
  'usersImport.help.existing': [
    'An existing user is never changed. A row identical to an existing user is shown as unchanged.',
    'Существующий пользователь не меняется. Строка, совпадающая с существующим пользователем, показывается как «без изменений».',
    'Бар пайдаланушы өзгертілмейді. Бар пайдаланушымен бірдей жол «өзгеріссіз» деп көрсетіледі.',
  ],
  'usersImport.help.signin': [
    'Imported users cannot sign in until they are invited or set a password.',
    'Импортированные пользователи не могут войти, пока их не пригласят или они не зададут пароль.',
    'Импортталған пайдаланушылар шақырылғанша немесе құпиясөз орнатқанша кіре алмайды.',
  ],
  'usersImport.limits': [
    'At most 200 data rows and 2 MB per file.',
    'Не более 200 строк данных и 2 МБ на файл.',
    'Бір файлда 200 жолдан және 2 МБ-тан аспауы тиіс.',
  ],
  'usersImport.error.limits': [
    'The file is over the limits: at most 2 MB and 200 data rows.',
    'Файл превышает ограничения: не более 2 МБ и 200 строк данных.',
    'Файл шектеуден асады: 2 МБ және 200 жолдан аспауы тиіс.',
  ],
  'usersImport.error.xlsx_unreadable': ['The file is not a readable xlsx file.', 'Файл не является читаемым xlsx.', 'Файл оқылатын xlsx емес.'],
  'usersImport.error.xlsx_too_large': ['The file is too large when uncompressed.', 'Файл слишком велик в распакованном виде.', 'Файл ашылған күйде тым үлкен.'],
  'usersImport.error.xlsx_header_missing': ['The file has no header row.', 'В файле нет строки заголовков.', 'Файлда тақырып жолы жоқ.'],
  'usersImport.error.xlsx_duplicate_header': ['The header has a duplicate column.', 'В заголовке есть повторяющаяся колонка.', 'Тақырыпта қайталанатын баған бар.'],
  'usersImport.error.xlsx_unknown_header': [
    'The header has a column that is not in the template.',
    'В заголовке есть колонка, которой нет в шаблоне.',
    'Тақырыпта үлгіде жоқ баған бар.',
  ],
  'usersImport.error.xlsx_unknown_header_named': [
    'These columns are not in the template: {headers}. Download the template for the exact column names.',
    'Этих колонок нет в шаблоне: {headers}. Скачайте шаблон, чтобы увидеть точные названия колонок.',
    'Бұл бағандар үлгіде жоқ: {headers}. Бағандардың нақты атауын көру үшін үлгіні жүктеп алыңыз.',
  ],
  'usersImport.error.xlsx_duplicate_header_named': [
    'These columns appear twice: {headers}. Keep one of each.',
    'Эти колонки повторяются: {headers}. Оставьте по одной.',
    'Бұл бағандар екі рет кездеседі: {headers}. Әрқайсысынан біреуін қалдырыңыз.',
  ],
  'usersImport.error.xlsx_missing_header': [
    'The file is missing required columns. Download the template for the exact column names.',
    'В файле нет обязательных колонок. Скачайте шаблон, чтобы увидеть точные названия колонок.',
    'Файлда міндетті бағандар жоқ. Бағандардың нақты атауын көру үшін үлгіні жүктеп алыңыз.',
  ],
  'usersImport.error.xlsx_missing_header_named': [
    'The file is missing these columns: {headers}. Download the template for the exact column names.',
    'В файле нет колонок: {headers}. Скачайте шаблон, чтобы увидеть точные названия колонок.',
    'Файлда бұл бағандар жоқ: {headers}. Бағандардың нақты атауын көру үшін үлгіні жүктеп алыңыз.',
  ],
  'usersImport.error.unprocessable': ['The file was refused. Check it against the template.', 'Файл отклонён. Сверьте его с шаблоном.', 'Файл қабылданбады. Оны үлгімен салыстырыңыз.'],
  'usersImport.error.notAvailable': ['The import is not available.', 'Импорт недоступен.', 'Импорт қолжетімсіз.'],
  'usersImport.error.forbidden': ['This action is not permitted.', 'Это действие не разрешено.', 'Бұл әрекетке рұқсат жоқ.'],
  'usersImport.error.busy': [
    'The server is busy. Try again in a moment.',
    'Сервер занят. Повторите через минуту.',
    'Сервер бос емес. Сәлден соң қайталап көріңіз.',
  ],
  'usersImport.error.other': ['The request failed. Try again.', 'Запрос не выполнен. Повторите попытку.', 'Сұраныс орындалмады. Қайталап көріңіз.'],
  'usersImport.reason.unknown': ['The row was refused ({type}).', 'Строка отклонена ({type}).', 'Жол қабылданбады ({type}).'],
}

/** Seven reason types: five of UserImport and two parser reasons it forwards unchanged. */
export const USERS_IMPORT_REASON_TYPES = [
  'user_field_required',
  'user_field_invalid',
  'user_duplicate_in_file',
  'user_exists_different',
  'internal_error',
  'xlsx_cell_count',
  'csv_invalid_value',
] as const

const REASONS: Record<(typeof USERS_IMPORT_REASON_TYPES)[number], Triple> = {
  user_field_required: ['A required value is empty. Fill it in.', 'Не заполнено обязательное значение. Заполните его.', 'Міндетті мән бос. Толтырыңыз.'],
  user_field_invalid: ['A value is not valid. Check it against the template.', 'Значение недопустимо. Сверьте его с шаблоном.', 'Мән жарамсыз. Оны үлгімен салыстырыңыз.'],
  user_duplicate_in_file: ['This username appears earlier in the file. Keep one row.', 'Это имя пользователя уже есть выше в файле. Оставьте одну строку.', 'Бұл пайдаланушы аты файлда жоғарыда бар. Бір жолды қалдырыңыз.'],
  user_exists_different: [
    'A user with this username already exists with other data. Existing users are not changed; use another username or leave the row out.',
    'Пользователь с таким именем уже есть, но с другими данными. Существующие пользователи не меняются; укажите другое имя или уберите строку.',
    'Мұндай аты бар пайдаланушы басқа деректермен бар. Бар пайдаланушылар өзгертілмейді; басқа ат көрсетіңіз немесе жолды алып тастаңыз.',
  ],
  internal_error: ['An internal error. Upload the file again later.', 'Внутренняя ошибка. Загрузите файл снова позже.', 'Ішкі қате. Файлды кейінірек қайта жүктеңіз.'],
  xlsx_cell_count: [
    'The row has more cells than columns. Remove the extra cell.',
    'В строке больше ячеек, чем колонок. Удалите лишнюю ячейку.',
    'Жолда бағандардан көп ұяшық бар. Артық ұяшықты жойыңыз.',
  ],
  csv_invalid_value: [
    'A cell value cannot be read. Retype it.',
    'Значение ячейки не читается. Введите его заново.',
    'Ұяшық мәнін оқу мүмкін емес. Қайта теріңіз.',
  ],
}

const ALL: Record<string, Triple> = {
  ...UI,
  ...Object.fromEntries(Object.entries(REASONS).map(([k, v]) => [`usersImport.reason.${k}`, v])),
}

function pick(index: 0 | 1 | 2): Record<string, string> {
  return Object.fromEntries(Object.entries(ALL).map(([id, t]) => [id, t[index]]))
}

export const usersImportMessages: Record<UsersImportLocale, Record<string, string>> = {
  en: pick(0),
  ru: pick(1),
  kk: pick(2),
}
