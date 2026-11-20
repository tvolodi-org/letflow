/** approvalRulesMessages — T-1989. Message catalog of the Approval rules admin screen, en/ru/kk.
 *  The ru/kk wording is a machine draft: a native speaker checks it (same note as navMessages.ts). */
export const APPROVAL_RULES_UI_LOCALES = ['en', 'ru', 'kk'] as const
export type ApprovalRulesUiLocale = (typeof APPROVAL_RULES_UI_LOCALES)[number]

type Triple = readonly [en: string, ru: string, kk: string]

const UI: Record<string, Triple> = {
  'approvalRules.eyebrow': ['Tenant administration', 'Администрирование организации', 'Ұйымды әкімшілендіру'],
  'approvalRules.title': ['Approval rules', 'Правила утверждения', 'Бекіту ережелері'],
  'approvalRules.lede': [
    'Choose where a document must be approved by a different person than the one who issued it.',
    'Выберите, где документ должен утверждать другой человек, не тот, кто его оформил.',
    'Құжатты ресімдеген адамнан басқа адам бекітуі тиіс жерді таңдаңыз.',
  ],
  'approvalRules.list.label': ['Approval steps', 'Шаги утверждения', 'Бекіту қадамдары'],
  'approvalRules.col.process': ['Document type', 'Тип документа', 'Құжат түрі'],
  'approvalRules.col.step': ['Step', 'Шаг', 'Қадам'],
  'approvalRules.col.rule': ['Different person', 'Другой человек', 'Басқа адам'],
  'approvalRules.loading': ['Loading approval rules', 'Загрузка правил утверждения', 'Бекіту ережелері жүктелуде'],
  'approvalRules.retry': ['Try again', 'Повторить', 'Қайталау'],
  'approvalRules.pill.on': ['On', 'Включено', 'Қосулы'],
  'approvalRules.pill.off': ['Off', 'Выключено', 'Өшірулі'],
  'approvalRules.empty': ['No approval needs a second person', 'Нет утверждений, требующих второго человека', 'Екінші адамды қажет ететін бекіту жоқ'],
  'approvalRules.emptyText': [
    'Approval steps appear here when a module or process with an approval by a different person is installed (for example asset or stock opening).',
    'Шаги утверждения появятся здесь, когда будет установлен модуль или процесс с утверждением другим человеком (например, ввод остатков активов или запасов).',
    'Басқа адам бекітетін модуль немесе процесс орнатылғанда (мысалы, активтер немесе қорлар қалдықтарын енгізу), бекіту қадамдары осында пайда болады.',
  ],
  'approvalRules.pick': ['Pick a step to see and change its rule.', 'Выберите шаг, чтобы увидеть и изменить его правило.', 'Ережені көру және өзгерту үшін қадамды таңдаңыз.'],
  'approvalRules.close': ['Close', 'Закрыть', 'Жабу'],
  'approvalRules.detail.process': ['Document type', 'Тип документа', 'Құжат түрі'],
  'approvalRules.detail.step': ['Step', 'Шаг', 'Қадам'],
  'approvalRules.detail.rule': ['Rule', 'Правило', 'Ереже'],
  'approvalRules.detail.lastChange': ['Last change', 'Последнее изменение', 'Соңғы өзгеріс'],
  'approvalRules.rule.on': [
    'A different person than the issuer must approve.',
    'Утверждать должен другой человек, не тот, кто оформил документ.',
    'Құжатты ресімдеген адам емес, басқа адам бекітуі тиіс.',
  ],
  'approvalRules.rule.off': [
    "The issuer may approve their own document. Every such approval is recorded in the audit log as 'self-approved, four-eyes off'.",
    'Оформивший документ может утвердить его сам. Каждое такое утверждение записывается в журнал аудита как «самоутверждение, правило двух человек выключено».',
    "Құжатты ресімдеген адам оны өзі бекіте алады. Мұндай әрбір бекіту аудит журналына «өзі бекітті, екі адам ережесі өшірулі» деп жазылады.",
  ],
  'approvalRules.change.never': ['Never changed (default: on)', 'Не менялось (по умолчанию: включено)', 'Өзгертілмеген (әдепкі: қосулы)'],
  'approvalRules.change.never.off': ['Never changed (default: off)', 'Не менялось (по умолчанию: выключено)', 'Өзгертілмеген (әдепкі: өшірулі)'],
  'approvalRules.change.by': ['{name}, {when}', '{name}, {when}', '{name}, {when}'],
  'approvalRules.change.unknownUser': ['Unknown user', 'Неизвестный пользователь', 'Белгісіз пайдаланушы'],
  'approvalRules.change.reason': ['Reason: {reason}', 'Причина: {reason}', 'Себебі: {reason}'],
  'approvalRules.orphan': [
    'This step is no longer in an active version of the process. The setting still applies to documents of older versions that are still open.',
    'Этого шага больше нет в активной версии процесса. Настройка по-прежнему действует для открытых документов старых версий.',
    'Бұл қадам процестің белсенді нұсқасында жоқ. Баптау ескі нұсқалардағы ашық құжаттарға әлі де қолданылады.',
  ],
  'approvalRules.switch.label': ['Require a different person to approve', 'Требовать утверждения другим человеком', 'Басқа адамның бекітуін талап ету'],
  'approvalRules.switch.locked': [
    'Cannot be switched off: the step is no longer in an active process.',
    'Нельзя выключить: шага больше нет в активном процессе.',
    'Өшіруге болмайды: қадам белсенді процесте жоқ.',
  ],
  'approvalRules.warn.title': ['One person will be able to issue and approve', 'Один человек сможет оформлять и утверждать', 'Бір адам ресімдеп те, бекітіп те алады'],
  'approvalRules.warn.text': [
    'The person who issued a document may approve it. Every such approval is recorded in the audit log. Integrations and service users still need a second person.',
    'Тот, кто оформил документ, сможет его утвердить. Каждое такое утверждение записывается в журнал аудита. Интеграциям и служебным пользователям по-прежнему нужен второй человек.',
    'Құжатты ресімдеген адам оны бекіте алады. Мұндай әрбір бекіту аудит журналына жазылады. Интеграциялар мен қызметтік пайдаланушыларға екінші адам әлі де қажет.',
  ],
  'approvalRules.reason.label': ['Reason', 'Причина', 'Себебі'],
  'approvalRules.reason.hint': ['Kept in the audit log with your name.', 'Сохраняется в журнале аудита вместе с вашим именем.', 'Аудит журналында сіздің атыңызбен сақталады.'],
  'approvalRules.reason.required': ['Enter a reason to save.', 'Укажите причину, чтобы сохранить.', 'Сақтау үшін себебін көрсетіңіз.'],
  'approvalRules.save': ['Save', 'Сохранить', 'Сақтау'],
  'approvalRules.cancel': ['Cancel', 'Отмена', 'Бас тарту'],
  'approvalRules.toast.saved': ['Approval rule saved', 'Правило утверждения сохранено', 'Бекіту ережесі сақталды'],
  'approvalRules.error.invalid_reason': [
    'The reason must be 1 to 500 characters of plain text.',
    'Причина должна быть простым текстом от 1 до 500 символов.',
    'Себеп 1-ден 500-ге дейінгі жай мәтін болуы тиіс.',
  ],
  'approvalRules.error.concurrent_change': [
    'Someone else changed this rule. The list was refreshed; check it and try again.',
    'Это правило только что изменил другой человек. Список обновлён; проверьте и повторите.',
    'Бұл ережені басқа адам өзгертті. Тізім жаңартылды; тексеріп, қайталаңыз.',
  ],
  'approvalRules.error.not_a_four_eyes_step': [
    'This step no longer needs approval by a different person. The list was refreshed.',
    'Этому шагу больше не нужно утверждение другим человеком. Список обновлён.',
    'Бұл қадамға енді басқа адамның бекітуі қажет емес. Тізім жаңартылды.',
  ],
  'approvalRules.error.forbidden': [
    'You are not allowed to change approval rules.',
    'У вас нет права менять правила утверждения.',
    'Бекіту ережелерін өзгертуге рұқсатыңыз жоқ.',
  ],
  'approvalRules.error.generic': [
    'The rule could not be saved. Try again.',
    'Не удалось сохранить правило. Повторите попытку.',
    'Ережені сақтау мүмкін болмады. Қайталап көріңіз.',
  ],
  // Display names of the processes and steps shipped with four-eyes rules.
  'approvalRules.process.assets_opening': ['Asset opening', 'Ввод остатков активов', 'Активтердің бастапқы қалдықтарын енгізу'],
  'approvalRules.process.stock_opening': ['Stock opening balances', 'Ввод начальных остатков запасов', 'Қорлардың бастапқы қалдықтарын енгізу'],
  'approvalRules.step.approve': ['Approval', 'Утверждение', 'Бекіту'],
}

function build(index: 0 | 1 | 2): Record<string, string> {
  return Object.fromEntries(Object.entries(UI).map(([id, triple]) => [id, triple[index]]))
}

export const approvalRulesMessages: Record<ApprovalRulesUiLocale, Record<string, string>> = {
  en: build(0),
  ru: build(1),
  kk: build(2),
}
