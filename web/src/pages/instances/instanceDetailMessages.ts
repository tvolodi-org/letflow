/** Texts of the Instance detail page, per UI language (T-1753). The kk texts are machine drafts
 *  until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface InstanceDetailMessages {
  title: string
  cancel: string
  lastRefreshed: string
  notRefreshed: string
  refresh: string
  refreshing: string
  cancelFailed: string
  colField: string
  colValue: string
  noDetails: string
  rowDefinition: string
  rowStatus: string
  rowActiveNodes: string
  rowCorrelationKey: string
  rowStartedAt: string
  rowLastUpdated: string
  rowCompletedAt: string
  snapshotHeading: string
  definitionId: string
  source: string
  sourceSnapshot: string
  sourceCurrent: string
  activeTokens: string
  noGraph: string
  variables: string
  activeTasks: string
  noActiveTasks: string
  colTaskId: string
  colNode: string
  colName: string
  colAssignee: string
  colCreated: string
  attachments: string
  dependencyVersions: string
  tabGraph: string
  tabHistory: string
  tabTimeline: string
  graphHeading: string
  historyHeading: string
  timelineHeading: string
  scrubberFailed: string
  timelineFailed: string
}

export const instanceDetailMessages: Record<UiLocale, InstanceDetailMessages> = {
  en: {
    title: 'Instance',
    cancel: 'Cancel',
    lastRefreshed: 'Last refreshed: {time}',
    notRefreshed: 'Not yet refreshed',
    refresh: 'Refresh',
    refreshing: 'Refreshing...',
    cancelFailed: 'Failed to cancel instance. The status has been restored.',
    colField: 'Field',
    colValue: 'Value',
    noDetails: 'No instance details available.',
    rowDefinition: 'Definition',
    rowStatus: 'Status',
    rowActiveNodes: 'Active nodes',
    rowCorrelationKey: 'Correlation key',
    rowStartedAt: 'Started at',
    rowLastUpdated: 'Last updated',
    rowCompletedAt: 'Completed at',
    snapshotHeading: 'Definition Snapshot',
    definitionId: 'Definition ID',
    source: 'Source',
    sourceSnapshot: 'Stored snapshot',
    sourceCurrent: 'Current definition version',
    activeTokens: 'Active tokens',
    noGraph: 'No graph snapshot is available for this instance.',
    variables: 'Variables',
    activeTasks: 'Active Tasks',
    noActiveTasks: 'No active tasks.',
    colTaskId: 'Task ID',
    colNode: 'Node',
    colName: 'Name',
    colAssignee: 'Assignee',
    colCreated: 'Created',
    attachments: 'Attachments',
    dependencyVersions: 'Dependency Versions',
    tabGraph: 'Graph',
    tabHistory: 'History',
    tabTimeline: 'Timeline',
    graphHeading: 'Process Graph with Tokens',
    historyHeading: 'Event history',
    timelineHeading: 'Timeline',
    scrubberFailed: 'Failed to load timeline scrubber.',
    timelineFailed: 'Failed to load timeline.',
  },
  ru: {
    title: 'Экземпляр',
    cancel: 'Отмена',
    lastRefreshed: 'Обновлено: {time}',
    notRefreshed: 'Ещё не обновлялось',
    refresh: 'Обновить',
    refreshing: 'Обновление...',
    cancelFailed: 'Не удалось отменить экземпляр. Статус восстановлен.',
    colField: 'Поле',
    colValue: 'Значение',
    noDetails: 'Сведений об экземпляре нет.',
    rowDefinition: 'Определение',
    rowStatus: 'Статус',
    rowActiveNodes: 'Активные узлы',
    rowCorrelationKey: 'Ключ корреляции',
    rowStartedAt: 'Запущен',
    rowLastUpdated: 'Обновлён',
    rowCompletedAt: 'Завершён',
    snapshotHeading: 'Снимок определения',
    definitionId: 'ID определения',
    source: 'Источник',
    sourceSnapshot: 'Сохранённый снимок',
    sourceCurrent: 'Текущая версия определения',
    activeTokens: 'Активные токены',
    noGraph: 'Для этого экземпляра нет снимка графа.',
    variables: 'Переменные',
    activeTasks: 'Активные задачи',
    noActiveTasks: 'Активных задач нет.',
    colTaskId: 'ID задачи',
    colNode: 'Узел',
    colName: 'Название',
    colAssignee: 'Исполнитель',
    colCreated: 'Создана',
    attachments: 'Вложения',
    dependencyVersions: 'Версии зависимостей',
    tabGraph: 'Граф',
    tabHistory: 'История',
    tabTimeline: 'Хронология',
    graphHeading: 'Граф процесса с токенами',
    historyHeading: 'История событий',
    timelineHeading: 'Хронология',
    scrubberFailed: 'Не удалось загрузить ползунок хронологии.',
    timelineFailed: 'Не удалось загрузить хронологию.',
  },
  kk: {
    title: 'Дана',
    cancel: 'Болдырмау',
    lastRefreshed: 'Соңғы жаңарту: {time}',
    notRefreshed: 'Әлі жаңартылған жоқ',
    refresh: 'Жаңарту',
    refreshing: 'Жаңартылуда...',
    cancelFailed: 'Данасын болдырмау мүмкін болмады. Күйі қалпына келтірілді.',
    colField: 'Өріс',
    colValue: 'Мәні',
    noDetails: 'Дана туралы мәлімет жоқ.',
    rowDefinition: 'Анықтама',
    rowStatus: 'Күйі',
    rowActiveNodes: 'Белсенді түйіндер',
    rowCorrelationKey: 'Корреляция кілті',
    rowStartedAt: 'Іске қосылды',
    rowLastUpdated: 'Соңғы жаңартылуы',
    rowCompletedAt: 'Аяқталды',
    snapshotHeading: 'Анықтама көшірмесі',
    definitionId: 'Анықтама ID',
    source: 'Дереккөз',
    sourceSnapshot: 'Сақталған көшірме',
    sourceCurrent: 'Анықтаманың ағымдағы нұсқасы',
    activeTokens: 'Белсенді токендер',
    noGraph: 'Бұл дана үшін граф көшірмесі жоқ.',
    variables: 'Айнымалылар',
    activeTasks: 'Белсенді тапсырмалар',
    noActiveTasks: 'Белсенді тапсырмалар жоқ.',
    colTaskId: 'Тапсырма ID',
    colNode: 'Түйін',
    colName: 'Атауы',
    colAssignee: 'Орындаушы',
    colCreated: 'Құрылды',
    attachments: 'Тіркемелер',
    dependencyVersions: 'Тәуелділік нұсқалары',
    tabGraph: 'Сызба',
    tabHistory: 'Тарих',
    tabTimeline: 'Уақыт шкаласы',
    graphHeading: 'Токендері бар процесс графы',
    historyHeading: 'Оқиғалар тарихы',
    timelineHeading: 'Уақыт шкаласы',
    scrubberFailed: 'Уақыт шкаласының жүгірткісін жүктеу мүмкін болмады.',
    timelineFailed: 'Уақыт шкаласын жүктеу мүмкін болмады.',
  },
}
