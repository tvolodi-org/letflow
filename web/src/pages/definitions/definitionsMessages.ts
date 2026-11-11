/** Empty-list texts of the Definitions list, per UI language (T-1553). The kk texts are machine drafts
 *  until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface DefinitionsMessages {
  empty: string
  emptyHint: string
  /** {term} is the applied search term. */
  emptySearch: string
  title: string
  importButton: string
  newDefinition: string
  searchPlaceholder: string
  searching: string
  status: string
  all: string
  draft: string
  active: string
  deprecated: string
  archived: string
  colName: string
  colVersion: string
  colUpdated: string
  colActions: string
  activate: string
  archive: string
  rollback: string
  versionHistory: string
  loadingVersions: string
  createTitle: string
  fieldName: string
  fieldVersion: string
  fieldDescription: string
  descPlaceholder: string
  nameRequired: string
  versionRequired: string
  cancel: string
  create: string
  creating: string
  importInvalid: string
  importExists: string
  importUnreadable: string
}

export const definitionsMessages: Record<UiLocale, DefinitionsMessages> = {
  en: {
    empty: 'No definitions found',
    emptyHint: 'Create the first process definition with the create button.',
    emptySearch: 'No results found for "{term}"',
    title: 'Process Definitions',
    importButton: 'Import',
    newDefinition: '+ New Definition',
    searchPlaceholder: 'Search definitions...',
    searching: 'Searching…',
    status: 'Status',
    all: 'All',
    draft: 'Draft',
    active: 'Active',
    deprecated: 'Deprecated',
    archived: 'Archived',
    colName: 'Name',
    colVersion: 'Version',
    colUpdated: 'Updated',
    colActions: 'Actions',
    activate: 'Activate',
    archive: 'Archive',
    rollback: 'Rollback…',
    versionHistory: 'Version history: {name}',
    loadingVersions: 'Loading versions...',
    createTitle: 'Create New Definition',
    fieldName: 'Name',
    fieldVersion: 'Version',
    fieldDescription: 'Description',
    descPlaceholder: 'Optional description',
    nameRequired: 'Name is required',
    versionRequired: 'Version is required',
    cancel: 'Cancel',
    create: 'Create',
    creating: 'Creating...',
    importInvalid: 'Invalid file — expected a BPM export JSON file',
    importExists: 'A definition with this name and version already exists.',
    importUnreadable: 'Could not read file',
  },
  ru: {
    empty: 'Определений не найдено',
    emptyHint: 'Создайте первое определение процесса кнопкой создания.',
    emptySearch: 'По запросу «{term}» ничего не найдено',
    title: 'Определения процессов',
    importButton: 'Импорт',
    newDefinition: '+ Новое определение',
    searchPlaceholder: 'Поиск определений...',
    searching: 'Поиск…',
    status: 'Статус',
    all: 'Все',
    draft: 'Черновик',
    active: 'Активно',
    deprecated: 'Устарело',
    archived: 'В архиве',
    colName: 'Название',
    colVersion: 'Версия',
    colUpdated: 'Обновлено',
    colActions: 'Действия',
    activate: 'Активировать',
    archive: 'Архивировать',
    rollback: 'Откатить…',
    versionHistory: 'История версий: {name}',
    loadingVersions: 'Загрузка версий...',
    createTitle: 'Создание нового определения',
    fieldName: 'Название',
    fieldVersion: 'Версия',
    fieldDescription: 'Описание',
    descPlaceholder: 'Необязательное описание',
    nameRequired: 'Укажите название',
    versionRequired: 'Укажите версию',
    cancel: 'Отмена',
    create: 'Создать',
    creating: 'Создание...',
    importInvalid: 'Неверный файл: ожидается JSON-файл экспорта BPM',
    importExists: 'Определение с таким названием и версией уже существует.',
    importUnreadable: 'Не удалось прочитать файл',
  },
  kk: {
    empty: 'Анықтамалар табылмады',
    emptyHint: 'Алғашқы процесс анықтамасын жасау түймесімен жасаңыз.',
    emptySearch: '«{term}» сұрауы бойынша ештеңе табылмады',
    title: 'Процесс анықтамалары',
    importButton: 'Импорттау',
    newDefinition: '+ Жаңа анықтама',
    searchPlaceholder: 'Анықтамаларды іздеу...',
    searching: 'Іздеу…',
    status: 'Күйі',
    all: 'Барлығы',
    draft: 'Жоба',
    active: 'Белсенді',
    deprecated: 'Ескірген',
    archived: 'Мұрағатталған',
    colName: 'Атауы',
    colVersion: 'Нұсқа',
    colUpdated: 'Жаңартылды',
    colActions: 'Әрекеттер',
    activate: 'Белсендіру',
    archive: 'Мұрағаттау',
    rollback: 'Кері қайтару…',
    versionHistory: 'Нұсқалар тарихы: {name}',
    loadingVersions: 'Нұсқалар жүктелуде...',
    createTitle: 'Жаңа анықтама жасау',
    fieldName: 'Атауы',
    fieldVersion: 'Нұсқа',
    fieldDescription: 'Сипаттама',
    descPlaceholder: 'Қосымша сипаттама',
    nameRequired: 'Атауын көрсетіңіз',
    versionRequired: 'Нұсқасын көрсетіңіз',
    cancel: 'Болдырмау',
    create: 'Жасау',
    creating: 'Жасалуда...',
    importInvalid: 'Жарамсыз файл: BPM экспорттау JSON файлы күтілуде',
    importExists: 'Мұндай атау мен нұсқадағы анықтама бұрыннан бар.',
    importUnreadable: 'Файлды оқу мүмкін болмады',
  },
}
