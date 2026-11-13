/** moduleRolloutsMessages -- T-1660. Catalog of the module rollout operator screen, en/ru/kk, same id set in each.
 *  The kk texts are machine drafts until the owner's native check (docs/assets/i18n-gaps.md), as elsewhere. */
export const MODULE_ROLLOUTS_LOCALES = ['en', 'ru', 'kk'] as const
export type ModuleRolloutsLocale = (typeof MODULE_ROLLOUTS_LOCALES)[number]

type Triple = readonly [en: string, ru: string, kk: string]

const UI: Record<string, Triple> = {
  'moduleRollouts.eyebrow': ['Platform · Operations', 'Платформа · Эксплуатация', 'Платформа · Пайдалану'],
  'moduleRollouts.title': ['Module rollouts', 'Развёртывание модулей', 'Модульдерді тарату'],
  'moduleRollouts.lede': [
    'Roll a new module version out to the companies, see how each one went, and resume a stopped rollout.',
    'Разверните новую версию модуля по компаниям, посмотрите результат по каждой и продолжите остановленное развёртывание.',
    'Модульдің жаңа нұсқасын компанияларға таратыңыз, әрқайсысының нәтижесін көріңіз және тоқтаған таратуды жалғастырыңыз.',
  ],
  'moduleRollouts.start.label': ['Module id', 'Идентификатор модуля', 'Модуль идентификаторы'],
  'moduleRollouts.start.button': ['Start rollout', 'Начать развёртывание', 'Таратуды бастау'],
  'moduleRollouts.start.unknown': ['Unknown module.', 'Неизвестный модуль.', 'Белгісіз модуль.'],
  'moduleRollouts.start.failed': [
    'The rollout start did not complete. Check the list, and try again if it is not there.',
    'Запуск развёртывания не завершился. Проверьте список и повторите попытку, если его там нет.',
    'Таратуды бастау аяқталмады. Тізімді тексеріңіз, егер ол жоқ болса, қайталап көріңіз.',
  ],
  'moduleRollouts.list.heading': ['Rollouts (latest 50)', 'Развёртывания (последние 50)', 'Таратулар (соңғы 50)'],
  'moduleRollouts.list.pane': ['Rollouts', 'Развёртывания', 'Таратулар'],
  'moduleRollouts.detail.pick': ['Pick a rollout to see its companies.', 'Выберите развёртывание, чтобы увидеть компании.', 'Компанияларды көру үшін таратуды таңдаңыз.'],
  'moduleRollouts.list.empty': ['No rollouts yet', 'Развёртываний пока нет', 'Әзірге тарату жоқ'],
  'moduleRollouts.list.emptyText': [
    'Type a module id above and start the first one.',
    'Введите идентификатор модуля выше и начните первое.',
    'Жоғарыда модуль идентификаторын енгізіп, біріншісін бастаңыз.',
  ],
  'moduleRollouts.col.module': ['Module', 'Модуль', 'Модуль'],
  'moduleRollouts.col.version': ['Version', 'Версия', 'Нұсқа'],
  'moduleRollouts.col.status': ['Status', 'Статус', 'Мәртебе'],
  'moduleRollouts.col.counts': ['Companies', 'Компании', 'Компаниялар'],
  'moduleRollouts.col.started': ['Started', 'Начато', 'Басталды'],
  'moduleRollouts.col.halted': ['Halted', 'Остановлено', 'Тоқтатылды'],
  'moduleRollouts.col.company': ['Company', 'Компания', 'Компания'],
  'moduleRollouts.col.outcome': ['Outcome', 'Результат', 'Нәтиже'],
  'moduleRollouts.col.error': ['Error code', 'Код ошибки', 'Қате коды'],
  'moduleRollouts.col.attempted': ['Attempted', 'Попытка', 'Әрекет'],
  'moduleRollouts.col.completed': ['Completed', 'Завершено', 'Аяқталды'],
  'moduleRollouts.status.running': ['Running', 'Выполняется', 'Орындалуда'],
  'moduleRollouts.status.completed': ['Completed', 'Завершено', 'Аяқталды'],
  'moduleRollouts.status.halted': ['Halted', 'Остановлено', 'Тоқтатылды'],
  'moduleRollouts.outcome.pending': ['Pending', 'Ожидает', 'Күтуде'],
  'moduleRollouts.outcome.running': ['Running', 'Выполняется', 'Орындалуда'],
  'moduleRollouts.outcome.succeeded': ['Succeeded', 'Успешно', 'Сәтті'],
  'moduleRollouts.outcome.failed': ['Failed', 'Ошибка', 'Қате'],
  'moduleRollouts.outcome.skipped': ['Skipped', 'Пропущено', 'Өткізілді'],
  'moduleRollouts.outcome.outside_window': ['Outside window', 'Вне окна', 'Терезеден тыс'],
  'moduleRollouts.outsideWindow.note': [
    "Outside the company's upgrade window; retried by the next Start or Resume.",
    'Вне окна обновления компании; будет повторено при следующем запуске или продолжении.',
    'Компанияның жаңарту терезесінен тыс; келесі бастау немесе жалғастыру кезінде қайталанады.',
  ],
  'moduleRollouts.detail.heading': ['Companies in this rollout', 'Компании в этом развёртывании', 'Осы таратудағы компаниялар'],
  'moduleRollouts.detail.failures': ['Failures in a row: {count} of {limit}', 'Ошибок подряд: {count} из {limit}', 'Қатарынан қате: {count} / {limit}'],
  'moduleRollouts.detail.noCompanies': ['No companies', 'Нет компаний', 'Компаниялар жоқ'],
  'moduleRollouts.halted.title': ['Rollout halted.', 'Развёртывание остановлено.', 'Тарату тоқтатылды.'],
  'moduleRollouts.halted.text': [
    'Stopped after {count} failures in a row. Remaining companies were not touched. Resume retries the failed ones.',
    'Остановлено после {count} ошибок подряд. Остальные компании не затронуты. «Продолжить» повторит неудачные.',
    'Қатарынан {count} қатеден кейін тоқтатылды. Қалған компанияларға тиіспедік. «Жалғастыру» сәтсіздерін қайталайды.',
  ],
  'moduleRollouts.resume.button': ['Resume', 'Продолжить', 'Жалғастыру'],
  'moduleRollouts.resume.superseded': [
    "This rollout's version is no longer the running build; start a new rollout.",
    'Версия этого развёртывания больше не совпадает с работающей сборкой; начните новое развёртывание.',
    'Бұл таратудың нұсқасы енді жұмыс істеп тұрған құрастырма емес; жаңа тарату бастаңыз.',
  ],
  'moduleRollouts.resume.failed': [
    'The rollout could not be resumed. Try again.',
    'Не удалось продолжить развёртывание. Повторите попытку.',
    'Таратуды жалғастыру мүмкін болмады. Қайталап көріңіз.',
  ],
  'moduleRollouts.notFound': ['This rollout was not found.', 'Это развёртывание не найдено.', 'Бұл тарату табылмады.'],
  'moduleRollouts.loadError': ['The rollouts could not be loaded.', 'Не удалось загрузить развёртывания.', 'Таратуларды жүктеу мүмкін болмады.'],
  'moduleRollouts.retry': ['Retry', 'Повторить', 'Қайталау'],
  'moduleRollouts.loading': ['Loading…', 'Загрузка…', 'Жүктелуде…'],
}

function build(index: 0 | 1 | 2): Record<string, string> {
  return Object.fromEntries(Object.entries(UI).map(([id, t]) => [id, t[index]]))
}

export const moduleRolloutsMessages: Record<ModuleRolloutsLocale, Record<string, string>> = {
  en: build(0),
  ru: build(1),
  kk: build(2),
}
