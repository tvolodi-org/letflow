/** entitiesMessages — REQ-336
 *
 *  Message catalog for the generic admin-CRUD screen engine's pilot (the
 *  `tag` entity type). REQ-285 wired react-intl's date/time formatting and
 *  the session-locale concept, and explicitly deferred "shipping actual
 *  translations" to "a separate, later requirement" (see
 *  docs/frontend/frontend-requirements.md's Locale policy section) -- this
 *  is the first requirement to add a real, translated message catalog, so
 *  there is no existing convention to extend; this file establishes one for
 *  the entities screens this requirement and its REQ-340/REQ-342/REQ-343
 *  follow-ons add.
 *
 *  REQ-285's `PLATFORM_SUPPORTED_LOCALES` (web/src/i18n/sessionLocale.ts)
 *  governs `Intl.DateTimeFormat` locale support only and deliberately does
 *  NOT include "kk"/"ru" -- that set is a different concern (date/time
 *  formatting) from this one (UI string translation). `resolveUiLocale`
 *  below is this file's OWN, narrower resolver, over the three locales this
 *  catalog actually carries, and does not read or modify
 *  PLATFORM_SUPPORTED_LOCALES.
 *
 *  KNOWN GAP, recorded rather than silently worked around: with no browser
 *  ever reporting a bare "ru"/"kk" `navigator.language` filtered through
 *  PLATFORM_SUPPORTED_LOCALES (which the session-locale store does, for the
 *  unrelated date-formatting concern), `resolveUiLocale` here reads
 *  `navigator.languages` directly rather than going through
 *  `useSessionLocaleStore` -- so this catalog's kk/ru entries ARE reachable
 *  by an actual kk/ru browser locale, independent of REQ-285's
 *  date-formatting locale set. Flagged to ORCH per core-directives' "No
 *  Issue Left Local-Only": the two locale concepts (date formatting vs. UI
 *  string translation) are on different resolvers, which is a bit of drift
 *  worth reconciling once a second requirement adds a second catalog.
 */

export const ENTITIES_UI_LOCALES = ['en', 'ru', 'kk'] as const
export type EntitiesUiLocale = (typeof ENTITIES_UI_LOCALES)[number]

export const ENTITIES_UI_FALLBACK_LOCALE: EntitiesUiLocale = 'en'

function isEntitiesUiLocale(value: string): value is EntitiesUiLocale {
  return (ENTITIES_UI_LOCALES as readonly string[]).includes(value)
}

/** Resolves the locale this catalog's consumers render in: the first of
 *  `navigator.languages` (or `navigator.language`) whose base language tag
 *  (before any "-REGION" suffix) is one of ENTITIES_UI_LOCALES, else
 *  ENTITIES_UI_FALLBACK_LOCALE. Never throws; safe under SSR/test
 *  environments with no `navigator`. */
export function resolveUiLocale(candidates?: readonly string[]): EntitiesUiLocale {
  const sources =
    candidates ??
    (typeof navigator !== 'undefined'
      ? navigator.languages && navigator.languages.length > 0
        ? navigator.languages
        : navigator.language
          ? [navigator.language]
          : []
      : [])

  for (const raw of sources) {
    const base = raw.split('-')[0].toLowerCase()
    if (isEntitiesUiLocale(base)) return base
  }
  return ENTITIES_UI_FALLBACK_LOCALE
}

/** Message ids used by this requirement's entity admin screens. Every id
 *  below has all three locales populated -- no id is English-only. */
export const entitiesMessages: Record<EntitiesUiLocale, Record<string, string>> = {
  en: {
    // NOTE: these two ids are named after REQ-336's tag pilot but are used
    // generically by the shared EntityRecordForm for every entity type
    // (see web/src/components/entities/EntityRecordForm.tsx) -- kept as-is,
    // renaming is out of scope for ISS-0655.
    'entities.tag.form.submitError': 'Could not save this tag.',
    'entities.tag.form.conflictError':
      'This tag was changed by someone else while you were editing. Reload and try again.',
    'entities.pagination.previous': 'Previous',
    'entities.pagination.next': 'Next',
    'entities.widgets.localizedText.groupLabel': 'Text by language',
    'entities.widgets.localizedText.locale.kk': 'Kazakh',
    'entities.widgets.localizedText.locale.ru': 'Russian',
    'entities.widgets.localizedText.locale.en': 'English',
    'entities.widgets.localizedText.locale.other': 'Other language',
    'entities.widgets.fkReference.searchPlaceholder': 'Search…',
    'entities.widgets.fkReference.loading': 'Loading…',
    'entities.widgets.fkReference.noResults': 'No matches found.',

    // --- REQ-343: generic admin-CRUD screen (EntityCrudPage), all nine
    // remaining BilimBaga entity types share these ids rather than
    // duplicating tag's per-entity keys nine times.
    'entities.crud.list.createAction': 'New record',
    'entities.crud.list.editAction': 'Edit',
    'entities.crud.list.deleteAction': 'Delete',
    'entities.crud.list.column.actions': 'Actions',
    'entities.crud.list.emptyMessage': 'No records found.',
    'entities.crud.list.loadError': 'Failed to load records.',
    'entities.crud.form.createTitle': 'New record',
    'entities.crud.form.editTitle': 'Edit record',
    'entities.crud.form.submitCreate': 'Create',
    'entities.crud.form.submitUpdate': 'Save',
    'entities.crud.form.cancel': 'Cancel',
    'entities.crud.form.submitError': 'Could not save this record.',
    'entities.crud.form.restrictedFieldError':
      'You do not have permission to write a protected field. Ask a tenant administrator.',
    'entities.crud.form.conflictError':
      'This record was changed by someone else while you were editing. Reload and try again.',
    'entities.crud.delete.confirmTitle': 'Delete this record?',
    'entities.crud.delete.confirmBody': 'This action cannot be undone.',
    'entities.crud.delete.confirmAction': 'Delete',
    'entities.crud.delete.cancelAction': 'Cancel',
    'entities.crud.delete.error': 'Failed to delete this record.',
    'entities.crud.notFound': 'Unknown entity type.',
    'entities.crud.boolean.yes': 'Yes',
    'entities.crud.boolean.no': 'No',

    // Field labels, keyed by field NAME (not by entity+field): the same
    // field name means the same thing across every BilimBaga entity type
    // that carries it (e.g. category_id always means "Category"), so one
    // shared label per field name avoids nine-way duplication.
    'entities.field.name': 'Name',
    'entities.field.track': 'Track',
    'entities.field.sort_order': 'Sort order',
    'entities.field.category_id': 'Category',
    'entities.field.difficulty': 'Difficulty',
    'entities.field.type': 'Type',
    'entities.field.default_locale': 'Default language',
    'entities.field.status': 'Status',
    'entities.field.version': 'Version',
    'entities.field.stem': 'Question text',
    'entities.field.explanation': 'Explanation',
    'entities.field.question_id': 'Question',
    'entities.field.is_correct': 'Correct answer',
    'entities.field.likert_weight': 'Likert weight',
    'entities.field.likert_polarity': 'Likert polarity',
    'entities.field.text': 'Text',
    'entities.field.tag_id': 'Tag',
    'entities.field.title': 'Title',
    'entities.field.description': 'Description',
    'entities.field.time_limit_minutes': 'Time limit (minutes)',
    'entities.field.passing_score_pct': 'Passing score (%)',
    'entities.field.max_attempts': 'Max attempts',
    'entities.field.available_from': 'Available from',
    'entities.field.available_until': 'Available until',
    'entities.field.shuffle_questions': 'Shuffle questions',
    'entities.field.shuffle_options': 'Shuffle options',
    'entities.field.show_answers': 'Show answers',
    'entities.field.on_tab_switch': 'On tab switch',
    'entities.field.certificate_enabled': 'Certificate enabled',
    'entities.field.exam_id': 'Exam',
    'entities.field.section_id': 'Section',
    'entities.field.count': 'Count',
    'entities.field.rule_id': 'Rule',

    // Entity-type labels for the admin landing page's nav cards.
    'entities.entityType.category': 'Categories',
    'entities.entityType.question': 'Questions',
    'entities.entityType.answer_option': 'Answer Options',
    'entities.entityType.question_tag': 'Question Tags',
    'entities.entityType.exam': 'Exams',
    'entities.entityType.exam_section': 'Exam Sections',
    'entities.entityType.exam_question_rule': 'Question Rules',
    'entities.entityType.exam_question_rule_tag': 'Rule Tags',
    'entities.entityType.exam_manual_question': 'Manual Questions',
    'entities.entityType.tag': 'Tags',

    // Admin landing page (REQ-343).
    'entities.views.select.label': 'View',
    'entities.views.select.none': '(no view)',
    'entities.views.columns.label': 'Columns',
    'entities.views.save.nameLabel': 'View name',
    'entities.views.save.action': 'Save as view',
    'entities.views.save.errorConflict': 'A view with this name already exists.',
    'entities.views.save.errorInvalid': 'This view could not be saved: check the name, columns, filters and sort.',
    'entities.views.save.errorGeneric': 'Failed to save this view.',
    'entities.views.delete.action': 'Delete view',
    'entities.views.delete.confirmTitle': 'Delete this view?',
    'entities.views.delete.confirmBody': 'The saved view is removed. Records are not affected.',
    'entities.views.delete.confirmAction': 'Delete',
    'entities.views.delete.cancelAction': 'Cancel',
    'entities.views.delete.error': 'Failed to delete this view.',
    'entities.admin.landing.title': 'Question Bank & Exams',
    'entities.admin.landing.intro':
      'Manage the question bank and exam configuration used by BilimBaga.',
    'entities.admin.landing.examAssignmentGap':
      'Known gap: there is no screen here to assign an exam to specific candidates. Assignment is enforced (REQ-582): an exam with no active assignment cannot be started by anyone. Assignments are written only by the operator seed/release path until the assignment-management requirement lands.',
  },
  ru: {
    'entities.tag.form.submitError': 'Не удалось сохранить этот тег.',
    'entities.tag.form.conflictError':
      'Этот тег был изменён кем-то другим, пока вы его редактировали. Обновите страницу и повторите попытку.',
    'entities.pagination.previous': 'Назад',
    'entities.pagination.next': 'Вперёд',
    'entities.widgets.localizedText.groupLabel': 'Текст по языкам',
    'entities.widgets.localizedText.locale.kk': 'Казахский',
    'entities.widgets.localizedText.locale.ru': 'Русский',
    'entities.widgets.localizedText.locale.en': 'Английский',
    'entities.widgets.localizedText.locale.other': 'Другой язык',
    'entities.widgets.fkReference.searchPlaceholder': 'Поиск…',
    'entities.widgets.fkReference.loading': 'Загрузка…',
    'entities.widgets.fkReference.noResults': 'Совпадений не найдено.',

    'entities.crud.list.createAction': 'Новая запись',
    'entities.crud.list.editAction': 'Изменить',
    'entities.crud.list.deleteAction': 'Удалить',
    'entities.crud.list.column.actions': 'Действия',
    'entities.crud.list.emptyMessage': 'Записи не найдены.',
    'entities.crud.list.loadError': 'Не удалось загрузить записи.',
    'entities.crud.form.createTitle': 'Новая запись',
    'entities.crud.form.editTitle': 'Изменить запись',
    'entities.crud.form.submitCreate': 'Создать',
    'entities.crud.form.submitUpdate': 'Сохранить',
    'entities.crud.form.cancel': 'Отмена',
    'entities.crud.form.submitError': 'Не удалось сохранить эту запись.',
    'entities.crud.form.restrictedFieldError':
      'У вас нет прав на запись защищённого поля. Обратитесь к администратору тенанта.',
    'entities.crud.form.conflictError':
      'Эта запись была изменена кем-то другим, пока вы её редактировали. Обновите страницу и повторите попытку.',
    'entities.crud.delete.confirmTitle': 'Удалить эту запись?',
    'entities.crud.delete.confirmBody': 'Это действие нельзя отменить.',
    'entities.crud.delete.confirmAction': 'Удалить',
    'entities.crud.delete.cancelAction': 'Отмена',
    'entities.crud.delete.error': 'Не удалось удалить эту запись.',
    'entities.crud.notFound': 'Неизвестный тип сущности.',
    'entities.crud.boolean.yes': 'Да',
    'entities.crud.boolean.no': 'Нет',

    'entities.field.name': 'Название',
    'entities.field.track': 'Направление',
    'entities.field.sort_order': 'Порядок сортировки',
    'entities.field.category_id': 'Категория',
    'entities.field.difficulty': 'Сложность',
    'entities.field.type': 'Тип',
    'entities.field.default_locale': 'Язык по умолчанию',
    'entities.field.status': 'Статус',
    'entities.field.version': 'Версия',
    'entities.field.stem': 'Текст вопроса',
    'entities.field.explanation': 'Объяснение',
    'entities.field.question_id': 'Вопрос',
    'entities.field.is_correct': 'Правильный ответ',
    'entities.field.likert_weight': 'Вес по шкале Лайкерта',
    'entities.field.likert_polarity': 'Полярность по шкале Лайкерта',
    'entities.field.text': 'Текст',
    'entities.field.tag_id': 'Тег',
    'entities.field.title': 'Заголовок',
    'entities.field.description': 'Описание',
    'entities.field.time_limit_minutes': 'Лимит времени (мин.)',
    'entities.field.passing_score_pct': 'Проходной балл (%)',
    'entities.field.max_attempts': 'Макс. попыток',
    'entities.field.available_from': 'Доступно с',
    'entities.field.available_until': 'Доступно до',
    'entities.field.shuffle_questions': 'Перемешивать вопросы',
    'entities.field.shuffle_options': 'Перемешивать варианты',
    'entities.field.show_answers': 'Показывать ответы',
    'entities.field.on_tab_switch': 'При переключении вкладки',
    'entities.field.certificate_enabled': 'Сертификат включён',
    'entities.field.exam_id': 'Экзамен',
    'entities.field.section_id': 'Раздел',
    'entities.field.count': 'Количество',
    'entities.field.rule_id': 'Правило',

    'entities.entityType.category': 'Категории',
    'entities.entityType.question': 'Вопросы',
    'entities.entityType.answer_option': 'Варианты ответов',
    'entities.entityType.question_tag': 'Теги вопросов',
    'entities.entityType.exam': 'Экзамены',
    'entities.entityType.exam_section': 'Разделы экзамена',
    'entities.entityType.exam_question_rule': 'Правила подбора вопросов',
    'entities.entityType.exam_question_rule_tag': 'Теги правил',
    'entities.entityType.exam_manual_question': 'Вопросы вручную',
    'entities.entityType.tag': 'Теги',

    'entities.views.select.label': 'Представление',
    'entities.views.select.none': '(без представления)',
    'entities.views.columns.label': 'Столбцы',
    'entities.views.save.nameLabel': 'Название представления',
    'entities.views.save.action': 'Сохранить как представление',
    'entities.views.save.errorConflict': 'Представление с таким названием уже существует.',
    'entities.views.save.errorInvalid': 'Не удалось сохранить представление: проверьте название, столбцы, фильтры и сортировку.',
    'entities.views.save.errorGeneric': 'Не удалось сохранить представление.',
    'entities.views.delete.action': 'Удалить представление',
    'entities.views.delete.confirmTitle': 'Удалить это представление?',
    'entities.views.delete.confirmBody': 'Сохранённое представление будет удалено. Записи не затрагиваются.',
    'entities.views.delete.confirmAction': 'Удалить',
    'entities.views.delete.cancelAction': 'Отмена',
    'entities.views.delete.error': 'Не удалось удалить представление.',
    'entities.admin.landing.title': 'Банк вопросов и экзамены',
    'entities.admin.landing.intro':
      'Управляйте банком вопросов и настройками экзаменов BilimBaga.',
    'entities.admin.landing.examAssignmentGap':
      'Известное ограничение: здесь нет экрана для назначения экзамена конкретным кандидатам. Назначение проверяется (REQ-582): экзамен без активного назначения не может начать никто. Назначения записываются только оператором через seed/release, пока не будет реализовано требование по управлению назначениями.',
  },
  kk: {
    'entities.tag.form.submitError': 'Бұл тегті сақтау мүмкін болмады.',
    'entities.tag.form.conflictError':
      'Сіз өңдеп жатқан кезде бұл тегті басқа біреу өзгертті. Бетті қайта жүктеп, әрекетті қайталаңыз.',
    'entities.pagination.previous': 'Артқа',
    'entities.pagination.next': 'Алға',
    'entities.widgets.localizedText.groupLabel': 'Тіл бойынша мәтін',
    'entities.widgets.localizedText.locale.kk': 'Қазақша',
    'entities.widgets.localizedText.locale.ru': 'Орысша',
    'entities.widgets.localizedText.locale.en': 'Ағылшынша',
    'entities.widgets.localizedText.locale.other': 'Басқа тіл',
    'entities.widgets.fkReference.searchPlaceholder': 'Іздеу…',
    'entities.widgets.fkReference.loading': 'Жүктелуде…',
    'entities.widgets.fkReference.noResults': 'Сәйкестік табылмады.',

    'entities.crud.list.createAction': 'Жаңа жазба',
    'entities.crud.list.editAction': 'Өзгерту',
    'entities.crud.list.deleteAction': 'Жою',
    'entities.crud.list.column.actions': 'Әрекеттер',
    'entities.crud.list.emptyMessage': 'Жазбалар табылмады.',
    'entities.crud.list.loadError': 'Жазбаларды жүктеу мүмкін болмады.',
    'entities.crud.form.createTitle': 'Жаңа жазба',
    'entities.crud.form.editTitle': 'Жазбаны өзгерту',
    'entities.crud.form.submitCreate': 'Құру',
    'entities.crud.form.submitUpdate': 'Сақтау',
    'entities.crud.form.cancel': 'Бас тарту',
    'entities.crud.form.submitError': 'Бұл жазбаны сақтау мүмкін болмады.',
    'entities.crud.form.restrictedFieldError':
      'Қорғалған өріске жазуға рұқсатыңыз жоқ. Тенант әкімшісіне хабарласыңыз.',
    'entities.crud.form.conflictError':
      'Сіз өңдеп жатқан кезде бұл жазбаны басқа біреу өзгертті. Бетті қайта жүктеп, әрекетті қайталаңыз.',
    'entities.crud.delete.confirmTitle': 'Бұл жазбаны жоясыз ба?',
    'entities.crud.delete.confirmBody': 'Бұл әрекетті болдырмау мүмкін емес.',
    'entities.crud.delete.confirmAction': 'Жою',
    'entities.crud.delete.cancelAction': 'Бас тарту',
    'entities.crud.delete.error': 'Бұл жазбаны жою мүмкін болмады.',
    'entities.crud.notFound': 'Белгісіз нысан түрі.',
    'entities.crud.boolean.yes': 'Иә',
    'entities.crud.boolean.no': 'Жоқ',

    'entities.field.name': 'Атауы',
    'entities.field.track': 'Бағыт',
    'entities.field.sort_order': 'Сұрыптау реті',
    'entities.field.category_id': 'Санат',
    'entities.field.difficulty': 'Қиындық',
    'entities.field.type': 'Түрі',
    'entities.field.default_locale': 'Әдепкі тіл',
    'entities.field.status': 'Мәртебе',
    'entities.field.version': 'Нұсқа',
    'entities.field.stem': 'Сұрақ мәтіні',
    'entities.field.explanation': 'Түсіндірме',
    'entities.field.question_id': 'Сұрақ',
    'entities.field.is_correct': 'Дұрыс жауап',
    'entities.field.likert_weight': 'Лайкерт салмағы',
    'entities.field.likert_polarity': 'Лайкерт полярлығы',
    'entities.field.text': 'Мәтін',
    'entities.field.tag_id': 'Тег',
    'entities.field.title': 'Тақырып',
    'entities.field.description': 'Сипаттама',
    'entities.field.time_limit_minutes': 'Уақыт шегі (мин.)',
    'entities.field.passing_score_pct': 'Өту балы (%)',
    'entities.field.max_attempts': 'Ең көп әрекет саны',
    'entities.field.available_from': 'Қолжетімді бастап',
    'entities.field.available_until': 'Қолжетімді дейін',
    'entities.field.shuffle_questions': 'Сұрақтарды араластыру',
    'entities.field.shuffle_options': 'Нұсқаларды араластыру',
    'entities.field.show_answers': 'Жауаптарды көрсету',
    'entities.field.on_tab_switch': 'Қойындыны ауыстырғанда',
    'entities.field.certificate_enabled': 'Сертификат қосулы',
    'entities.field.exam_id': 'Емтихан',
    'entities.field.section_id': 'Бөлім',
    'entities.field.count': 'Саны',
    'entities.field.rule_id': 'Ереже',

    'entities.entityType.category': 'Санаттар',
    'entities.entityType.question': 'Сұрақтар',
    'entities.entityType.answer_option': 'Жауап нұсқалары',
    'entities.entityType.question_tag': 'Сұрақ тегтері',
    'entities.entityType.exam': 'Емтихандар',
    'entities.entityType.exam_section': 'Емтихан бөлімдері',
    'entities.entityType.exam_question_rule': 'Сұрақ таңдау ережелері',
    'entities.entityType.exam_question_rule_tag': 'Ереже тегтері',
    'entities.entityType.exam_manual_question': 'Қолмен таңдалған сұрақтар',
    'entities.entityType.tag': 'Тегтер',

    'entities.views.select.label': 'Көрініс',
    'entities.views.select.none': '(көріністісіз)',
    'entities.views.columns.label': 'Бағандар',
    'entities.views.save.nameLabel': 'Көрініс атауы',
    'entities.views.save.action': 'Көрініс ретінде сақтау',
    'entities.views.save.errorConflict': 'Мұндай атаулы көрініс бұрыннан бар.',
    'entities.views.save.errorInvalid': 'Көріністі сақтау мүмкін болмады: атауды, бағандарды, сүзгілерді және сұрыптауды тексеріңіз.',
    'entities.views.save.errorGeneric': 'Көріністі сақтау мүмкін болмады.',
    'entities.views.delete.action': 'Көріністі жою',
    'entities.views.delete.confirmTitle': 'Бұл көріністі жоясыз ба?',
    'entities.views.delete.confirmBody': 'Сақталған көрініс жойылады. Жазбаларға әсер етпейді.',
    'entities.views.delete.confirmAction': 'Жою',
    'entities.views.delete.cancelAction': 'Бас тарту',
    'entities.views.delete.error': 'Көріністі жою мүмкін болмады.',
    'entities.admin.landing.title': 'Сұрақтар банкі және емтихандар',
    'entities.admin.landing.intro':
      'BilimBaga сұрақтар банкін және емтихан баптауларын осы жерден басқарыңыз.',
    'entities.admin.landing.examAssignmentGap':
      'Белгілі кемшілік: емтиханды нақты үміткерлерге тағайындайтын экран әлі жоқ. Тағайындау тексеріледі (REQ-582): белсенді тағайындауы жоқ емтиханды ешкім бастай алмайды. Тағайындауларды басқару талабы енгізілгенге дейін тек оператор seed/release арқылы жазады.',
  },
}
