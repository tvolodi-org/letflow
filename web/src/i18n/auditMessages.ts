/** auditMessages -- T-1557 (B2 #5). Message catalog of the Audit log page, en/ru/kk (D-062), same id set
 *  in each. Action labels are in the same table; an action without a label is shown as its raw code. */
export const AUDIT_UI_LOCALES = ['en', 'ru', 'kk'] as const
export type AuditUiLocale = (typeof AUDIT_UI_LOCALES)[number]

type Triple = readonly [en: string, ru: string, kk: string]

const UI: Record<string, Triple> = {
  'audit.title': ['Audit log', 'Журнал аудита', 'Аудит журналы'],
  'audit.refreshing': ['Refreshing…', 'Обновление…', 'Жаңартылуда…'],
  'audit.filter.user': ['User', 'Пользователь', 'Пайдаланушы'],
  'audit.filter.anyUser': ['Any user', 'Любой пользователь', 'Кез келген пайдаланушы'],
  'audit.filter.type': ['Object type', 'Тип объекта', 'Объект түрі'],
  'audit.filter.anyType': ['Any object', 'Любой объект', 'Кез келген объект'],
  'audit.filter.objectId': ['Object id', 'Id объекта', 'Объект id'],
  'audit.filter.from': ['From (ISO8601)', 'С (ISO8601)', 'Бастап (ISO8601)'],
  'audit.filter.to': ['To (ISO8601)', 'По (ISO8601)', 'Дейін (ISO8601)'],
  'audit.filter.pageSize': ['{n} / page', '{n} на странице', 'Бетте {n}'],
  'audit.filter.invalid': [
    'Please enter valid ISO8601 date filters and ensure from ≤ to.',
    'Введите корректные даты ISO8601; «с» не должно быть позже «по».',
    'ISO8601 күндерін дұрыс енгізіңіз; «бастап» «дейін» мәнінен кеш болмауы керек.',
  ],
  'audit.empty': [
    'No audit entries matched the selected filters.',
    'Нет записей аудита по выбранным фильтрам.',
    'Таңдалған сүзгілер бойынша аудит жазбалары жоқ.',
  ],
  'audit.col.time': ['Time', 'Время', 'Уақыт'],
  'audit.col.actor': ['User', 'Пользователь', 'Пайдаланушы'],
  'audit.col.action': ['Action', 'Действие', 'Әрекет'],
  'audit.col.object': ['Object', 'Объект', 'Нысан'],
  'audit.col.ip': ['IP', 'IP', 'IP'],
  'audit.export': ['Export CSV', 'Экспорт в CSV', 'CSV экспорттау'],
  'audit.exporting': ['Exporting…', 'Экспорт…', 'Экспортталуда…'],
  'audit.export.failed': [
    'The export failed. Try again.',
    'Не удалось выполнить экспорт. Повторите попытку.',
    'Экспорт орындалмады. Қайталап көріңіз.',
  ],
  'audit.export.truncated': [
    'Only the first 10 000 rows were exported. Narrow the filters to get the rest.',
    'Выгружены только первые 10 000 строк. Сузьте фильтры, чтобы получить остальные.',
    'Тек алғашқы 10 000 жол экспортталды. Қалғанын алу үшін сүзгілерді тарылтыңыз.',
  ],
  'audit.action.document.posted': ['Document posted', 'Документ проведён', 'Құжат өткізілді'],
  'audit.action.document.reversed': ['Document reversed', 'Документ сторнирован', 'Құжат сторнеленді'],
  'audit.action.document.written_off': ['Document written off', 'Документ списан', 'Құжат есептен шығарылды'],
  'audit.action.document.issued': ['Document issued', 'Документ выпущен', 'Құжат шығарылды'],
  'audit.action.group.delete': ['Group deleted', 'Группа удалена', 'Топ жойылды'],
  'audit.action.group_member.added': ['Member added to group', 'Участник добавлен в группу', 'Топқа мүше қосылды'],
  'audit.action.group_member.removed': ['Member removed from group', 'Участник удалён из группы', 'Топтан мүше шығарылды'],
  'audit.action.role.rebound': ['Role binding changed', 'Привязка роли изменена', 'Рөл байланысы өзгерді'],
  'audit.action.token.create': ['Token created', 'Токен создан', 'Токен жасалды'],
  'audit.action.token.revoke': ['Token revoked', 'Токен отозван', 'Токен кері қайтарылды'],
  'audit.action.audit.exported': ['Audit log exported', 'Журнал аудита выгружен', 'Аудит журналы экспортталды'],
}

function build(index: 0 | 1 | 2): Record<string, string> {
  return Object.fromEntries(Object.entries(UI).map(([id, triple]) => [id, triple[index]]))
}

export const auditMessages: Record<AuditUiLocale, Record<string, string>> = {
  en: build(0),
  ru: build(1),
  kk: build(2),
}
