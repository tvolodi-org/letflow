# Language switch

Owner decision D-083 (2026-11-03). The platform has a UI-language switch: English, Русский, Қазақша (en, ru, kk).
There is no `uz`.

## How it works

- One store: `web/src/i18n/uiLocaleStore.ts` (Zustand). `useUiLocale()` is the hook, `getUiLocale()` the plain accessor.
- Priority: `?lang=xx` address parameter > saved choice (`localStorage`, key `lf-locale`) > browser language
  (`navigator.languages`, read live) > `en`. An unsupported value is ignored at each step.
- `?lang` holds for that page load only and is not saved. Choosing a language in the switcher saves it.
- The tenant `default_locale` tier stays unused, and there is no per-user profile setting yet (later work).
- The switcher (`LanguageSwitcher`, `web/src/components/ui/`) sits in the `TopBar` of `AppShell`. Choosing a language
  re-renders every area at once, without reload.
- Areas that read the store: `OrgIntlProvider`, `LocationsIntlProvider`, `CodesIntlProvider`,
  `CatalogItemsIntlProvider`, `ExamIntlProvider`, `EntitiesIntlProvider`, `ImportIntlProvider`, `LoginIntlProvider`,
  `ThemeToggle`, `useFormMessages`, `useUiMessages`, and the left menu. Each module's own `resolveUiLocale()` with no
  argument returns the store's language (`resolveUiLocale([tag])` with candidates is unchanged).
- The session-locale store (REQ-285, date and number formats) is unchanged: its supported set
  (`PLATFORM_SUPPORTED_LOCALES`) has no ru or kk formats, so it does not follow the switch.
- The screen harness has no workaround any more: `HarnessPage` sets the store (not saved) from `?lang`.
  `web/scripts/screenshot.sh` already builds the harness URL with `lang=`, so `LF_SHOT_LANG` is the `?lang` parameter.
  The harness screen `topbar-language` shows the switcher (state `default`: menu open, `empty`: closed).

## How to add a language

1. Add the code to `UI_LOCALES` and `UI_LOCALE_LABELS` in `uiLocaleStore.ts` (its own name as the label).
2. Add the code to every module's and shared `*_UI_LOCALES` list and give each catalog the same id set
   (`entitiesMessages`, `loginMessages`, `importMessages`, `uiMessages`, `formMessages`, `themeToggleMessages`,
   `orgMessages`, `codesMessages`, `locationsMessages`, `catalogItemsMessages`, `examMessages`).
3. Add a `navMessages` block (`web/src/components/layout/navMessages.ts`): groups and one word per route.
4. Add it to `HARNESS_LANGS`; run the tests; list the new machine-draft words below for a native check.

## Left menu: machine draft for a native check

The ru and kk words below are a machine draft. Routes without a word keep the entry's own English label.

| Route / group | English | Русский (draft) | Қазақша (draft) |
|---|---|---|---|
| group `work` | Work | Работа | Жұмыс |
| group `tenantAdmin` | Tenant administration | Администрирование | Әкімшілік |
| group `platform` | Platform | Платформа | Платформа |
| `/instances` | Instances | Экземпляры | Орындалып жатқан процестер |
| `/tasks` | My Tasks | Мои задачи | Менің тапсырмаларым |
| `/definitions` | Definitions | Определения | Анықтамалар |
| `/promotions` | Promotion Reviews | Проверка переноса | Көшірмені тексеру |
| `/dlq` | DLQ | Очередь ошибок | Қателер кезегі |
| `/webhooks` | Webhooks | Вебхуки | Вебхуктар |
| `/admin/users` | Users | Пользователи | Пайдаланушылар |
| `/admin/groups` | Groups | Группы | Топтар |
| `/admin/tokens` | Tokens | Токены | Токендер |
| `/admin/audit` | Audit | Аудит | Аудит |
| `/admin/print-templates` | Print Templates | Шаблоны печати | Басып шығару үлгілері |
| `/admin/import` | Import data | Импорт данных | Деректерді импорттау |
| `/admin/module-lifecycle` | Module lifecycle | Жизненный цикл модулей | Модульдердің өмірлік циклі |
| `/admin/health` | Health | Состояние | Күй |
| `/admin/metrics` | Metrics | Метрики | Метрикалар |
| `/admin/onboarding/new` | Register Tenant | Регистрация организации | Ұйымды тіркеу |
| `/admin/tenants` | Tenants | Организации | Ұйымдар |
| `/admin/services` | Services | Сервисы | Сервистер |
| `/admin/platform-migrations` | Platform Migrations | Миграции платформы | Платформа миграциялары |
| `/solution-packs` | Solution Packs | Пакеты решений | Шешім пакеттері |
| `/admin/event-retention` | Event Retention | Хранение событий | Оқиғаларды сақтау |
| `/admin/codes` | Codes | Коды | Кодтар |
| `/admin/org/legal-entities` | Legal companies | Юридические лица | Заңды тұлғалар |
| `/admin/org/sites` | Sites | Площадки | Алаңдар |
| `/admin/org/units` | Org units | Подразделения | Бөлімшелер |
| `/admin/org/positions` | Positions | Должности | Лауазымдар |
| `/admin/org/employees` | Employees | Сотрудники | Қызметкерлер |
| `/admin/catalog/lots` | Lots | Партии | Партиялар |
| `/exam` | Exams | Экзамены | Емтихандар |
| `/admin/questions` | Question Bank | Банк вопросов | Сұрақтар банкі |
| `/exam/grading` | Grading | Оценивание | Бағалау |
