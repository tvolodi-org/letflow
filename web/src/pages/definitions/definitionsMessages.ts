/** Empty-list texts of the Definitions list, per UI language (T-1553). The kk texts are machine drafts
 *  until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface DefinitionsMessages {
  empty: string
  emptyHint: string
  /** {term} is the applied search term. */
  emptySearch: string
  title: string
  hint: string
  openProcess: string
  publish: string
  publishing: string
  saveBeforePublish: string
  published: string
  publishFailed: string
  exportButton: string
  exporting: string
  readOnly: string
  noEditPermission: string
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
  copyAsDraft: string
  copyFailed: string
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
    empty: 'No business processes found',
    emptyHint: 'Create your first process with New process.',
    emptySearch: 'No results found for "{term}"',
    title: 'Business processes',
    hint: 'Open a process to view its diagram, edit steps, save a draft, publish a version or compare versions.',
    openProcess: 'Open process',
    publish: 'Publish saved version',
    publishing: 'Publishing…',
    saveBeforePublish: 'Save your changes before publishing.',
    published: 'This version is active. New instances will use it.',
    publishFailed: 'Publishing failed. Review the problems below and try again.',
    exportButton: 'Export',
    exporting: 'Exporting…',
    readOnly: 'Read-only',
    noEditPermission: 'No edit permission',
    importButton: 'Import',
    newDefinition: '+ New process',
    searchPlaceholder: 'Search processes...',
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
    copyAsDraft: 'Copy as draft',
    copyFailed: 'Could not copy the process',
    rollback: 'Rollback…',
    versionHistory: 'Version history: {name}',
    loadingVersions: 'Loading versions...',
    createTitle: 'Create process',
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
    empty: 'Бизнес-процессы не найдены',
    emptyHint: 'Создайте первый процесс кнопкой «Новый процесс».',
    emptySearch: 'По запросу «{term}» ничего не найдено',
    title: 'Бизнес-процессы',
    hint: 'Откройте процесс, чтобы посмотреть схему, изменить шаги, сохранить черновик, опубликовать версию или сравнить версии.',
    openProcess: 'Открыть процесс',
    publish: 'Опубликовать сохранённую версию',
    publishing: 'Публикация…',
    saveBeforePublish: 'Перед публикацией сохраните изменения.',
    published: 'Версия активна. Новые экземпляры будут использовать её.',
    publishFailed: 'Не удалось опубликовать. Исправьте ошибки ниже и повторите попытку.',
    exportButton: 'Экспорт',
    exporting: 'Экспорт…',
    readOnly: 'Только просмотр',
    noEditPermission: 'Нет разрешения на изменение',
    importButton: 'Импорт',
    newDefinition: '+ Новый процесс',
    searchPlaceholder: 'Поиск процессов...',
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
    copyAsDraft: 'Копировать как черновик',
    copyFailed: 'Не удалось скопировать процесс',
    rollback: 'Откатить…',
    versionHistory: 'История версий: {name}',
    loadingVersions: 'Загрузка версий...',
    createTitle: 'Создание процесса',
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
    empty: 'Бизнес-процестер табылмады',
    emptyHint: '«Жаңа процесс» түймесімен алғашқы процесті жасаңыз.',
    emptySearch: '«{term}» сұрауы бойынша ештеңе табылмады',
    title: 'Бизнес-процестер',
    hint: 'Схеманы көру, қадамдарды өзгерту, жобаны сақтау, нұсқаны жариялау немесе нұсқаларды салыстыру үшін процесті ашыңыз.',
    openProcess: 'Процесті ашу',
    publish: 'Сақталған нұсқаны жариялау',
    publishing: 'Жариялануда…',
    saveBeforePublish: 'Жариялау алдында өзгерістерді сақтаңыз.',
    published: 'Бұл нұсқа белсенді. Жаңа даналар осы нұсқаны қолданады.',
    publishFailed: 'Жариялау сәтсіз аяқталды. Төмендегі қателерді түзетіп, қайталаңыз.',
    exportButton: 'Экспорттау',
    exporting: 'Экспортталуда…',
    readOnly: 'Тек көру',
    noEditPermission: 'Өзгертуге рұқсат жоқ',
    importButton: 'Импорттау',
    newDefinition: '+ Жаңа процесс',
    searchPlaceholder: 'Процестерді іздеу...',
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
    copyAsDraft: 'Жоба ретінде көшіру',
    copyFailed: 'Процесті көшіру мүмкін болмады',
    rollback: 'Кері қайтару…',
    versionHistory: 'Нұсқалар тарихы: {name}',
    loadingVersions: 'Нұсқалар жүктелуде...',
    createTitle: 'Процесс жасау',
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
