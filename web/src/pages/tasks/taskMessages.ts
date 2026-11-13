/** Messages of the task inbox (T-1380 / GATE B R3): en / ru / kk. The action words (Post, Approve, Reverse) name the node of
 *  a stock flow; any other node keeps its own name. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface TaskMessages {
  title: string
  close: string
  eyebrow: string
  lede: string
  listPane: string
  filterMe: string
  filterGroup: string
  filterAll: string
  searchPlaceholder: string
  newest: string
  oldest: string
  emptyTitle: string
  emptyText: string
  pickTask: string
  colTask: string
  colDocument: string
    issuedBy: string
  linesOne: string
  linesMany: string
  moreLines: string
  claim: string
  claiming: string
  complete: string
  completing: string
  actions: Record<string, string>
  done: Record<string, string>
  claimed: string
  claimedHint: string
  noPermission: string
  loadingTask: string
  taskNotFound: string
  documentHeading: string
  documentUnavailable: string
  linesHeading: string
  colItem: string
  colUnit: string
  colLot: string
  colQuantity: string
  definition: string
  correlation: string
  created: string
  number: string
  kind: string
  state: string
  states: Record<string, string>
  orgUnit: string
  location: string
  from: string
  to: string
  note: string
  plannedPeriod: string
  taskForm: string
  reviewedOne: string
  reviewedMany: string
  /** Separation-of-duties refusal, per action kind. */
  sod: Record<string, string>
  sodHint: Record<string, string>
  errAlreadyTaken: string
  errNotHeld: string
  errNotPending: string
  errInsufficientStock: string
  errLocationFrozen: string
  errGeneric: string
}

export const TASK_MESSAGES: Record<UiLocale, TaskMessages> = {
  en: {
    title: 'My Tasks', close: 'Close', eyebrow: 'Work', lede: 'Documents waiting for you to post, approve or reverse them.', listPane: 'Tasks',
    filterMe: 'My Tasks', filterGroup: 'Group Tasks', filterAll: 'All Tasks',
    searchPlaceholder: 'Search tasks…', newest: 'Newest first', oldest: 'Oldest first',
    emptyTitle: 'No pending tasks', emptyText: 'Nothing is waiting for you in this view.', pickTask: 'Select a task to see its document.',
    colTask: 'Task', colDocument: 'Document', issuedBy: 'Issued by',
    linesOne: '1 line', linesMany: '{n} lines', moreLines: '+{n} more',
    claim: 'Claim', claiming: 'Claiming…', complete: 'Complete', completing: 'Working…',
    actions: { post: 'Post', approve: 'Approve', reverse: 'Reverse' },
    done: { post: 'Posted', approve: 'Approved', reverse: 'Reversed', other: 'Task completed' },
    claimed: 'Task claimed', claimedHint: 'The task is yours now.',
    noPermission: 'You can view this task but not act on it.',
    loadingTask: 'Loading task…', taskNotFound: 'Task not found',
    documentHeading: 'Document', documentUnavailable: 'Document not available', linesHeading: 'Lines',
    colItem: 'Item', colUnit: 'Unit', colLot: 'Lot', colQuantity: 'Quantity',
    definition: 'Process', correlation: 'Correlation key', created: 'Created', number: 'Number', kind: 'Kind', state: 'State', states: { draft: 'Draft', posted: 'Posted', reversed: 'Reversed', cancelled: 'Cancelled' },
    orgUnit: 'Org unit', location: 'Location', from: 'From', to: 'To', note: 'Note', plannedPeriod: 'Planned period',
    taskForm: 'Task form', reviewedOne: 'Reviewed document: ', reviewedMany: 'Reviewed documents: ',
    sod: {
      approve: 'A different person must approve this document.',
      post: 'A different person must post this document.',
      reverse: 'A different person must reverse this document.',
      other: 'A different person must do this step.',
    },
    sodHint: {
      approve: 'You issued this document; a different person must approve it.',
      post: 'You issued this document; a different person must post it.',
      reverse: 'You issued this document; a different person must reverse it.',
      other: 'You issued this document; a different person must do this step.',
    },
    errAlreadyTaken: 'Someone else has already taken this task.',
    errNotHeld: 'You do not hold the role this task is for.',
    errNotPending: 'This task is no longer pending.',
    errInsufficientStock: 'Not enough stock to post this document.',
    errLocationFrozen: 'A stock count has frozen these locations. Complete this task after the count ends or is cancelled.',
    errGeneric: 'The action failed. Try again.',
  },
  ru: {
    title: 'Мои задачи', close: 'Закрыть', eyebrow: 'Работа', lede: 'Документы, которые ждут проведения, утверждения или сторнирования.', listPane: 'Задачи',
    filterMe: 'Мои задачи', filterGroup: 'Задачи группы', filterAll: 'Все задачи',
    searchPlaceholder: 'Поиск задач…', newest: 'Сначала новые', oldest: 'Сначала старые',
    emptyTitle: 'Нет задач в ожидании', emptyText: 'В этом списке для вас ничего нет.', pickTask: 'Выберите задачу, чтобы увидеть документ.',
    colTask: 'Задача', colDocument: 'Документ', issuedBy: 'Оформил',
    linesOne: '1 строка', linesMany: 'Строк: {n}', moreLines: 'ещё {n}',
    claim: 'Взять в работу', claiming: 'Беру…', complete: 'Выполнить', completing: 'Выполняется…',
    actions: { post: 'Провести', approve: 'Утвердить', reverse: 'Сторнировать' },
    done: { post: 'Проведено', approve: 'Утверждено', reverse: 'Сторнировано', other: 'Задача выполнена' },
    claimed: 'Задача взята', claimedHint: 'Теперь задача за вами.',
    noPermission: 'Вы можете смотреть задачу, но не выполнять её.',
    loadingTask: 'Загрузка задачи…', taskNotFound: 'Задача не найдена',
    documentHeading: 'Документ', documentUnavailable: 'Документ недоступен', linesHeading: 'Строки',
    colItem: 'Номенклатура', colUnit: 'Ед. изм.', colLot: 'Партия', colQuantity: 'Количество',
    definition: 'Процесс', correlation: 'Ключ корреляции', created: 'Создана', number: 'Номер', kind: 'Вид', state: 'Состояние', states: { draft: 'Черновик', posted: 'Проведён', reversed: 'Сторнирован', cancelled: 'Отменён' },
    orgUnit: 'Подразделение', location: 'Место', from: 'Откуда', to: 'Куда', note: 'Примечание', plannedPeriod: 'Плановый период',
    taskForm: 'Форма задачи', reviewedOne: 'Проверенный документ: ', reviewedMany: 'Проверенные документы: ',
    sod: {
      approve: 'Этот документ должен утвердить другой человек.',
      post: 'Этот документ должен провести другой человек.',
      reverse: 'Этот документ должен сторнировать другой человек.',
      other: 'Этот шаг должен выполнить другой человек.',
    },
    sodHint: {
      approve: 'Вы оформили этот документ; утвердить его должен другой человек.',
      post: 'Вы оформили этот документ; провести его должен другой человек.',
      reverse: 'Вы оформили этот документ; сторнировать его должен другой человек.',
      other: 'Вы оформили этот документ; этот шаг должен выполнить другой человек.',
    },
    errAlreadyTaken: 'Эту задачу уже взял кто-то другой.',
    errNotHeld: 'У вас нет роли, на которую назначена эта задача.',
    errNotPending: 'Задача уже не ожидает выполнения.',
    errInsufficientStock: 'Недостаточно остатка для проведения документа.',
    errLocationFrozen: 'Эти места хранения заморожены инвентаризацией. Завершите задачу после окончания или отмены инвентаризации.',
    errGeneric: 'Не удалось выполнить действие. Повторите попытку.',
  },
  kk: {
    title: 'Менің тапсырмаларым', close: 'Жабу', eyebrow: 'Жұмыс', lede: 'Өткізуді, бекітуді немесе сторнолауды күтетін құжаттар.', listPane: 'Тапсырмалар',
    filterMe: 'Менің тапсырмаларым', filterGroup: 'Топ тапсырмалары', filterAll: 'Барлық тапсырмалар',
    searchPlaceholder: 'Тапсырмаларды іздеу…', newest: 'Алдымен жаңалары', oldest: 'Алдымен ескілері',
    emptyTitle: 'Күтіп тұрған тапсырма жоқ', emptyText: 'Бұл тізімде сізді ешнәрсе күтіп тұрған жоқ.', pickTask: 'Құжатты көру үшін тапсырманы таңдаңыз.',
    colTask: 'Тапсырма', colDocument: 'Құжат', issuedBy: 'Рәсімдеген',
    linesOne: '1 жол', linesMany: 'Жол саны: {n}', moreLines: 'тағы {n}',
    claim: 'Жұмысқа алу', claiming: 'Алынуда…', complete: 'Орындау', completing: 'Орындалуда…',
    actions: { post: 'Өткізу', approve: 'Бекіту', reverse: 'Сторнолау' },
    done: { post: 'Өткізілді', approve: 'Бекітілді', reverse: 'Сторнолады', other: 'Тапсырма орындалды' },
    claimed: 'Тапсырма алынды', claimedHint: 'Енді тапсырма сізде.',
    noPermission: 'Тапсырманы көруге болады, бірақ орындауға болмайды.',
    loadingTask: 'Тапсырма жүктелуде…', taskNotFound: 'Тапсырма табылмады',
    documentHeading: 'Құжат', documentUnavailable: 'Құжат қолжетімсіз', linesHeading: 'Жолдар',
    colItem: 'Номенклатура', colUnit: 'Өлшем бірлігі', colLot: 'Партия', colQuantity: 'Саны',
    definition: 'Процесс', correlation: 'Корреляция кілті', created: 'Құрылған', number: 'Нөмірі', kind: 'Түрі', state: 'Күйі', states: { draft: 'Жоба', posted: 'Өткізілген', reversed: 'Сторнолған', cancelled: 'Бас тартылған' },
    orgUnit: 'Бөлімше', location: 'Орын', from: 'Қайдан', to: 'Қайда', note: 'Ескертпе', plannedPeriod: 'Жоспарлы кезең',
    taskForm: 'Тапсырма формасы', reviewedOne: 'Тексерілген құжат: ', reviewedMany: 'Тексерілген құжаттар: ',
    sod: {
      approve: 'Бұл құжатты басқа адам бекітуі керек.',
      post: 'Бұл құжатты басқа адам өткізуі керек.',
      reverse: 'Бұл құжатты басқа адам сторнолауы керек.',
      other: 'Бұл қадамды басқа адам орындауы керек.',
    },
    sodHint: {
      approve: 'Бұл құжатты сіз рәсімдедіңіз; оны басқа адам бекітуі керек.',
      post: 'Бұл құжатты сіз рәсімдедіңіз; оны басқа адам өткізуі керек.',
      reverse: 'Бұл құжатты сіз рәсімдедіңіз; оны басқа адам сторнолауы керек.',
      other: 'Бұл құжатты сіз рәсімдедіңіз; бұл қадамды басқа адам орындауы керек.',
    },
    errAlreadyTaken: 'Бұл тапсырманы басқа адам алып қойған.',
    errNotHeld: 'Сізде бұл тапсырма тағайындалған рөл жоқ.',
    errNotPending: 'Тапсырма енді күтуде емес.',
    errInsufficientStock: 'Құжатты өткізуге қалдық жеткіліксіз.',
    errLocationFrozen: 'Бұл сақтау орындарын түгендеу тоңазытты. Тапсырманы түгендеу аяқталғаннан немесе бас тартылғаннан кейін орындаңыз.',
    errGeneric: 'Әрекет орындалмады. Қайталап көріңіз.',
  },
}
