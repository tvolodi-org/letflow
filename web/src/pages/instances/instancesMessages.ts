/** Empty-list texts of the Instances board, per UI language (T-1553). The kk texts are machine drafts
 *  until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface InstancesMessages {
  empty: string
  emptyHint: string
  title: string
  startInstance: string
  lastRefreshed: string
  notRefreshed: string
  refresh: string
  refreshing: string
  statusActive: string
  statusCompleted: string
  statusCancelled: string
  statusError: string
  definition: string
  definitionPlaceholder: string
  usingActive: string
  colInstanceId: string
  colStatus: string
  colCorrelation: string
  colStarted: string
  colUpdated: string
  definitionName: string
  activeVersion: string
  loadingVersion: string
  correlationKey: string
  initialVariables: string
  cancel: string
  start: string
  starting: string
  invalidDefinition: string
  variablesNotObject: string
  variablesBadJson: string
}

export const instancesMessages: Record<UiLocale, InstancesMessages> = {
  en: {
    empty: 'No process instances yet.',
    emptyHint: 'Start one from a process definition.',
    title: 'Instances',
    startInstance: 'Start Instance',
    lastRefreshed: 'Last refreshed: {time}',
    notRefreshed: 'Not yet refreshed',
    refresh: 'Refresh',
    refreshing: 'Refreshing...',
    statusActive: 'ACTIVE',
    statusCompleted: 'COMPLETED',
    statusCancelled: 'CANCELLED',
    statusError: 'ERROR',
    definition: 'Definition',
    definitionPlaceholder: 'Type definition name',
    usingActive: 'using active version {version}',
    colInstanceId: 'Instance ID',
    colStatus: 'Status',
    colCorrelation: 'Correlation Key',
    colStarted: 'Started',
    colUpdated: 'Last Updated',
    definitionName: 'Definition name',
    activeVersion: 'Active version (auto-selected)',
    loadingVersion: 'Loading active version…',
    correlationKey: 'Correlation key (optional)',
    initialVariables: 'Initial variables (JSON object)',
    cancel: 'Cancel',
    start: 'Start',
    starting: 'Starting…',
    invalidDefinition: 'Select a valid active definition name.',
    variablesNotObject: 'Initial variables must be a JSON object.',
    variablesBadJson: 'Initial variables must be valid JSON.',
  },
  ru: {
    empty: 'Экземпляров процессов пока нет.',
    emptyHint: 'Запустите его из определения процесса.',
    title: 'Экземпляры',
    startInstance: 'Запустить экземпляр',
    lastRefreshed: 'Обновлено: {time}',
    notRefreshed: 'Ещё не обновлялось',
    refresh: 'Обновить',
    refreshing: 'Обновление...',
    statusActive: 'АКТИВНЫЕ',
    statusCompleted: 'ЗАВЕРШЁННЫЕ',
    statusCancelled: 'ОТМЕНЁННЫЕ',
    statusError: 'С ОШИБКОЙ',
    definition: 'Определение',
    definitionPlaceholder: 'Введите название определения',
    usingActive: 'используется активная версия {version}',
    colInstanceId: 'ID экземпляра',
    colStatus: 'Статус',
    colCorrelation: 'Ключ корреляции',
    colStarted: 'Запущен',
    colUpdated: 'Обновлён',
    definitionName: 'Название определения',
    activeVersion: 'Активная версия (выбирается автоматически)',
    loadingVersion: 'Загрузка активной версии…',
    correlationKey: 'Ключ корреляции (необязательно)',
    initialVariables: 'Начальные переменные (объект JSON)',
    cancel: 'Отмена',
    start: 'Запустить',
    starting: 'Запуск…',
    invalidDefinition: 'Выберите действующее название активного определения.',
    variablesNotObject: 'Начальные переменные должны быть объектом JSON.',
    variablesBadJson: 'Начальные переменные должны быть корректным JSON.',
  },
  kk: {
    empty: 'Процесс даналары әзірге жоқ.',
    emptyHint: 'Оны процесс анықтамасынан іске қосыңыз.',
    title: 'Даналар',
    startInstance: 'Данасын іске қосу',
    lastRefreshed: 'Соңғы жаңарту: {time}',
    notRefreshed: 'Әлі жаңартылған жоқ',
    refresh: 'Жаңарту',
    refreshing: 'Жаңартылуда...',
    statusActive: 'БЕЛСЕНДІ',
    statusCompleted: 'АЯҚТАЛҒАН',
    statusCancelled: 'БОЛДЫРМАЛҒАН',
    statusError: 'ҚАТЕМЕН',
    definition: 'Анықтама',
    definitionPlaceholder: 'Анықтама атауын енгізіңіз',
    usingActive: 'белсенді нұсқа қолданылады: {version}',
    colInstanceId: 'Дана ID',
    colStatus: 'Күйі',
    colCorrelation: 'Корреляция кілті',
    colStarted: 'Іске қосылды',
    colUpdated: 'Соңғы жаңартылуы',
    definitionName: 'Анықтама атауы',
    activeVersion: 'Белсенді нұсқа (автоматты таңдалады)',
    loadingVersion: 'Белсенді нұсқа жүктелуде…',
    correlationKey: 'Корреляция кілті (қосымша)',
    initialVariables: 'Бастапқы айнымалылар (JSON нысаны)',
    cancel: 'Болдырмау',
    start: 'Іске қосу',
    starting: 'Іске қосылуда…',
    invalidDefinition: 'Жарамды белсенді анықтама атауын таңдаңыз.',
    variablesNotObject: 'Бастапқы айнымалылар JSON нысаны болуы керек.',
    variablesBadJson: 'Бастапқы айнымалылар жарамды JSON болуы керек.',
  },
}
