/** ledgerSettingsMessages — REQ-839. Message catalog of the Negative balances admin screen, en/ru/kk.
 *  The ru/kk wording is a machine draft: a native speaker checks it (same note as navMessages.ts). */
export const LEDGER_SETTINGS_UI_LOCALES = ['en', 'ru', 'kk'] as const
export type LedgerSettingsUiLocale = (typeof LEDGER_SETTINGS_UI_LOCALES)[number]

type Triple = readonly [en: string, ru: string, kk: string]

const UI: Record<string, Triple> = {
  'ledgerSettings.eyebrow': ['Tenant administration', 'Администрирование организации', 'Ұйымды әкімшілендіру'],
  'ledgerSettings.title': ['Negative balances', 'Отрицательные остатки', 'Теріс қалдықтар'],
  'ledgerSettings.lede': [
    'Choose which registers may post a balance below zero. Every change needs a reason.',
    'Выберите, в каких учётах остаток может уходить ниже нуля. Для каждого изменения нужна причина.',
    'Қай есепте қалдық нөлден төмен түсе алатынын таңдаңыз. Әр өзгеріске себеп қажет.',
  ],
  'ledgerSettings.list.label': ['Registers', 'Учёты', 'Есептер'],
  'ledgerSettings.col.registration': ['Register', 'Учёт', 'Есеп'],
  'ledgerSettings.col.value': ['Negative balance', 'Отрицательный остаток', 'Теріс қалдық'],
  'ledgerSettings.col.changed': ['Last change', 'Последнее изменение', 'Соңғы өзгеріс'],
  'ledgerSettings.col.reason': ['Reason', 'Причина', 'Себеп'],
  'ledgerSettings.col.action': ['Action', 'Действие', 'Әрекет'],
  'ledgerSettings.loading': ['Loading registers', 'Загрузка учётов', 'Есептер жүктелуде'],
  'ledgerSettings.retry': ['Try again', 'Повторить', 'Қайталау'],
  'ledgerSettings.pill.allowed': ['Allowed', 'Разрешено', 'Рұқсат етілген'],
  'ledgerSettings.pill.refused': ['Refused', 'Запрещено', 'Тыйым салынған'],
  'ledgerSettings.empty': ['No register can be switched', 'Нет учётов для переключения', 'Ауыстыруға болатын есеп жоқ'],
  'ledgerSettings.emptyText': [
    'Registers appear here when an installed module lets the tenant decide about negative balances (for example stock).',
    'Учёты появятся здесь, когда установленный модуль позволит организации решать вопрос об отрицательных остатках (например, запасы).',
    'Орнатылған модуль ұйымға теріс қалдық туралы шешім қабылдауға мүмкіндік бергенде (мысалы, қорлар), есептер осында пайда болады.',
  ],
  'ledgerSettings.change.never': ['Never changed', 'Не менялось', 'Өзгертілмеген'],
  'ledgerSettings.change.by': ['{name}, {when}', '{name}, {when}', '{name}, {when}'],
  'ledgerSettings.change.unknownUser': ['Unknown user', 'Неизвестный пользователь', 'Белгісіз пайдаланушы'],
  'ledgerSettings.toAllowed': ['Allow', 'Разрешить', 'Рұқсат беру'],
  'ledgerSettings.toRefused': ['Refuse', 'Запретить', 'Тыйым салу'],
  'ledgerSettings.dialog.allowTitle': ['Allow negative balance: {name}', 'Разрешить отрицательный остаток: {name}', 'Теріс қалдыққа рұқсат беру: {name}'],
  'ledgerSettings.dialog.refuseTitle': ['Refuse negative balance: {name}', 'Запретить отрицательный остаток: {name}', 'Теріс қалдыққа тыйым салу: {name}'],
  'ledgerSettings.dialog.warnTitle': ['What changes', 'Что изменится', 'Не өзгереді'],
  'ledgerSettings.dialog.warnAllow': [
    'Issues larger than the balance will then be posted, and the balance will be shown below zero.',
    'После этого расходы больше остатка будут проводиться, а остаток будет показан ниже нуля.',
    'Содан кейін қалдықтан көп шығыстар өткізіледі, ал қалдық нөлден төмен болып көрсетіледі.',
  ],
  'ledgerSettings.dialog.warnRefuse': [
    'Issues larger than the balance will be refused again.',
    'Расходы больше остатка снова будут отклоняться.',
    'Қалдықтан көп шығыстар қайтадан қабылданбайды.',
  ],
  'ledgerSettings.reason.label': ['Reason', 'Причина', 'Себеп'],
  'ledgerSettings.reason.required': ['A reason is required.', 'Укажите причину.', 'Себепті көрсетіңіз.'],
  'ledgerSettings.reason.hint': ['Kept with the change and shown in the audit.', 'Сохраняется вместе с изменением и видна в журнале аудита.', 'Өзгеріспен бірге сақталып, аудит журналында көрсетіледі.'],
  'ledgerSettings.confirm': ['Save', 'Сохранить', 'Сақтау'],
  'ledgerSettings.cancel': ['Cancel', 'Отмена', 'Бас тарту'],
  'ledgerSettings.toast.saved': ['The setting was saved.', 'Настройка сохранена.', 'Параметр сақталды.'],
  'ledgerSettings.error.invalid_reason': [
    'The reason must be 1 to 500 characters of plain text.',
    'Причина должна быть простым текстом от 1 до 500 символов.',
    'Себеп 1-ден 500-ге дейінгі жай мәтін болуы тиіс.',
  ],
  'ledgerSettings.error.not_switchable': [
    'This register cannot be switched. The list was refreshed.',
    'Этот учёт нельзя переключать. Список обновлён.',
    'Бұл есепті ауыстыру мүмкін емес. Тізім жаңартылды.',
  ],
  'ledgerSettings.error.concurrent_change': [
    'Someone else changed this setting. The list was refreshed; check it and try again.',
    'Эту настройку только что изменил другой человек. Список обновлён; проверьте и повторите.',
    'Бұл параметрді басқа адам өзгертті. Тізім жаңартылды; тексеріп, қайталаңыз.',
  ],
  'ledgerSettings.error.forbidden': [
    'You are not allowed to change this setting.',
    'У вас нет права менять эту настройку.',
    'Бұл параметрді өзгертуге рұқсатыңыз жоқ.',
  ],
  'ledgerSettings.error.generic': [
    'The setting could not be saved. Try again.',
    'Не удалось сохранить настройку. Повторите попытку.',
    'Параметрді сақтау мүмкін болмады. Қайталап көріңіз.',
  ],
  // Display names of the registers (the module's name); an unknown registration shows its own name.
  'ledgerSettings.registration.stock': ['Stock', 'Запасы', 'Қорлар'],
}

function build(index: 0 | 1 | 2): Record<string, string> {
  return Object.fromEntries(Object.entries(UI).map(([id, triple]) => [id, triple[index]]))
}

export const ledgerSettingsMessages: Record<LedgerSettingsUiLocale, Record<string, string>> = {
  en: build(0),
  ru: build(1),
  kk: build(2),
}
