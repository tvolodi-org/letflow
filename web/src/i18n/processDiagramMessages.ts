/** processDiagramMessages — T-1520 (D-114 item 2). Message catalogue of the read-only process diagram and the
 *  Diagram | Editor switch of the definition page, en/ru/kk, same id set in each (one table, so an id cannot miss a
 *  language). Ids are prefixed `processDiagram.`. */
export const PROCESS_DIAGRAM_LOCALES = ['en', 'ru', 'kk'] as const
export type ProcessDiagramLocale = (typeof PROCESS_DIAGRAM_LOCALES)[number]

type Triple = readonly [en: string, ru: string, kk: string]

const UI: Record<string, Triple> = {
  'processDiagram.label': ['Process diagram', 'Схема процесса', 'Процесс сызбасы'],
  'processDiagram.stepsLabel': ['Process steps', 'Шаги процесса', 'Процесс қадамдары'],
  'processDiagram.view.group': ['Definition view', 'Вид определения', 'Анықтама көрінісі'],
  'processDiagram.view.diagram': ['Diagram', 'Схема', 'Сызба'],
  'processDiagram.view.editor': ['Editor', 'Редактор', 'Өңдегіш'],
  'processDiagram.view.unsavedBadge': ['Preview of unsaved changes', 'Предпросмотр несохранённых изменений', 'Сақталмаған өзгерістерді алдын ала қарау'],
  'processDiagram.mode.group': ['Show as', 'Показать как', 'Көрсету түрі'],
  'processDiagram.mode.diagram': ['Diagram', 'Схема', 'Сызба'],
  'processDiagram.mode.steps': ['Steps', 'Шаги', 'Қадамдар'],
  'processDiagram.direction.toLR': ['Left to right', 'Слева направо', 'Солдан оңға'],
  'processDiagram.direction.toTB': ['Top to bottom', 'Сверху вниз', 'Жоғарыдан төменге'],
  'processDiagram.empty.title': ['This definition has no steps yet', 'В этом определении пока нет шагов', 'Бұл анықтамада әзірге қадамдар жоқ'],
  'processDiagram.empty.body': ['Add steps in the editor; the diagram is drawn from them.', 'Добавьте шаги в редакторе; схема строится по ним.', 'Өңдегіште қадамдар қосыңыз; сызба солар бойынша салынады.'],
  'processDiagram.noGraph': ['No graph is available for this instance.', 'Для этого экземпляра нет схемы.', 'Бұл данада сызба жоқ.'],
  'processDiagram.loading': ['Loading the diagram', 'Загрузка схемы', 'Сызба жүктелуде'],
  'processDiagram.large': [
    'This definition is large ({count} steps). The step list is shown instead of the diagram.',
    'Определение большое ({count} шагов). Вместо схемы показан список шагов.',
    'Анықтама үлкен ({count} қадам). Сызбаның орнына қадамдар тізімі көрсетілді.',
  ],
  'processDiagram.droppedEdges': [
    '{count} connections point to missing steps and are not drawn.',
    'Связей, ведущих к отсутствующим шагам, не показано: {count}.',
    'Жоқ қадамдарға апаратын байланыстар көрсетілмеді: {count}.',
  ],
  'processDiagram.note.errorNotAttributed': [
    'The error is not tied to a step: {reason}',
    'Ошибка не привязана к шагу: {reason}',
    'Қате қадамға байланысты емес: {reason}',
  ],
  'processDiagram.note.notReconciled': [
    'The history could not be reconciled with the diagram; uncertain steps are marked.',
    'Историю не удалось сопоставить со схемой; неясные шаги отмечены.',
    'Тарихты сызбамен сәйкестендіру мүмкін болмады; анық емес қадамдар белгіленді.',
  ],
  'processDiagram.note.historyIncomplete': [
    'The history is incomplete; uncertain steps are marked.',
    'История загружена не полностью; неясные шаги отмечены.',
    'Тарих толық жүктелмеді; анық емес қадамдар белгіленді.',
  ],
  'processDiagram.note.cancelled': ['This instance was cancelled.', 'Этот экземпляр отменён.', 'Бұл дана тоқтатылды.'],
  'processDiagram.retry': ['Try again', 'Повторить', 'Қайталау'],
  'processDiagram.type.START': ['Start', 'Начало', 'Басы'],
  'processDiagram.type.END': ['End', 'Конец', 'Соңы'],
  'processDiagram.type.HUMAN_TASK': ['User task', 'Задача пользователя', 'Пайдаланушы тапсырмасы'],
  'processDiagram.type.SERVICE_TASK': ['Service task', 'Сервисная задача', 'Қызмет тапсырмасы'],
  'processDiagram.type.EXCLUSIVE_GATEWAY': ['Decision', 'Решение', 'Шешім'],
  'processDiagram.type.PARALLEL_GATEWAY': ['Parallel', 'Параллельно', 'Қатар'],
  'processDiagram.type.TIMER': ['Timer', 'Таймер', 'Таймер'],
  'processDiagram.type.SUB_PROCESS': ['Sub-process', 'Подпроцесс', 'Ішкі процесс'],
  'processDiagram.type.other': ['Step', 'Шаг', 'Қадам'],
  'processDiagram.state.done': ['Done', 'Выполнено', 'Орындалды'],
  'processDiagram.state.active': ['Active', 'Активно', 'Белсенді'],
  'processDiagram.state.error': ['Error', 'Ошибка', 'Қате'],
  'processDiagram.state.skipped': ['Skipped', 'Пропущено', 'Өткізілді'],
  'processDiagram.state.pending': ['Not reached', 'Не достигнуто', 'Жетпеді'],
  'processDiagram.state.unclear': ['Not certain', 'Неясно', 'Анық емес'],
  'processDiagram.edge.default': ['default', 'по умолчанию', 'әдепкі'],
  'processDiagram.details.title': ['Step details', 'Сведения о шаге', 'Қадам туралы мәлімет'],
  'processDiagram.details.close': ['Close', 'Закрыть', 'Жабу'],
  'processDiagram.details.type': ['Type', 'Тип', 'Түрі'],
  'processDiagram.details.id': ['Id', 'Идентификатор', 'Сәйкестендіргіш'],
  'processDiagram.details.state': ['State', 'Состояние', 'Күйі'],
  'processDiagram.details.role': ['Role', 'Роль', 'Рөл'],
  'processDiagram.details.assignee': ['Assignee', 'Исполнитель', 'Орындаушы'],
  'processDiagram.details.form': ['Form: {count} fields', 'Форма: полей {count}', 'Пішін: {count} өріс'],
  'processDiagram.details.more': ['+{count} more', 'ещё {count}', 'тағы {count}'],
  'processDiagram.details.validation': ['Validation script', 'Скрипт проверки', 'Тексеру скрипті'],
  'processDiagram.details.distinct': ['Must differ from', 'Должен отличаться от', 'Мынадан өзге болуы керек'],
  'processDiagram.details.writes': ['Writes', 'Записывает', 'Жазады'],
  'processDiagram.details.service': ['Service', 'Сервис', 'Қызмет'],
  'processDiagram.details.endpoint': ['Endpoint', 'Адрес', 'Мекенжай'],
  'processDiagram.details.endpointSet': ['endpoint set', 'адрес задан', 'мекенжай берілген'],
  'processDiagram.details.script': ['Script', 'Скрипт', 'Скрипт'],
  'processDiagram.details.scriptVersion': ['Script version', 'Версия скрипта', 'Скрипт нұсқасы'],
  'processDiagram.details.timeout': ['Timeout, ms', 'Тайм-аут, мс', 'Күту уақыты, мс'],
  'processDiagram.details.duration': ['Duration', 'Длительность', 'Ұзақтығы'],
  'processDiagram.details.subDefinition': ['Called definition', 'Вызываемое определение', 'Шақырылатын анықтама'],
  'processDiagram.details.otherAttributes': ['{count} other attributes', 'Других атрибутов: {count}', 'Басқа атрибуттар: {count}'],
  'processDiagram.details.next': ['Next', 'Далее', 'Келесі'],
  // Screen-reader texts of React Flow (ariaLabelConfig), worded for a read-only view.
  'processDiagram.a11y.node': [
    'Press Enter to show the step details.',
    'Нажмите Enter, чтобы открыть сведения о шаге.',
    'Қадам туралы мәліметті ашу үшін Enter пернесін басыңыз.',
  ],
  'processDiagram.a11y.edge': ['Transition between steps.', 'Переход между шагами.', 'Қадамдар арасындағы өту.'],
  'processDiagram.a11y.controls': ['Diagram view controls', 'Управление видом схемы', 'Сызба көрінісін басқару'],
  'processDiagram.a11y.zoomIn': ['Zoom in', 'Увеличить', 'Үлкейту'],
  'processDiagram.a11y.zoomOut': ['Zoom out', 'Уменьшить', 'Кішірейту'],
  'processDiagram.a11y.fitView': ['Show the whole diagram', 'Показать схему целиком', 'Сызбаны толық көрсету'],
  'processDiagram.a11y.interactive': ['Lock the view', 'Закрепить вид', 'Көріністі бекіту'],
  'processDiagram.a11y.minimap': ['Overview map of the diagram', 'Обзорная карта схемы', 'Сызбаның шолу картасы'],
  'processDiagram.a11y.handle': ['Connection point', 'Точка соединения', 'Қосылу нүктесі'],
  'processDiagram.details.ifCondition': ['if {condition}', 'если {condition}', 'егер {condition}'],
}

function pick(i: 0 | 1 | 2): Record<string, string> {
  return Object.fromEntries(Object.entries(UI).map(([k, v]) => [k, v[i]]))
}

export const processDiagramMessages: Record<ProcessDiagramLocale, Record<string, string>> = {
  en: pick(0),
  ru: pick(1),
  kk: pick(2),
}
