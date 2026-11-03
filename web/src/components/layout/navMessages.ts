/** navMessages — D-083. Labels of the left menu in en, ru, kk, keyed by the route (`to`), so module entries
 *  (which carry their own English label) are covered too. An entry with no key keeps its own label.
 *  The ru and kk words are a machine draft: docs/design-system/language-switch.md lists them for a native check. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export type NavGroupId = 'work' | 'tenantAdmin' | 'platform'

export interface NavCatalog {
  groups: Record<NavGroupId, string>
  items: Record<string, string>
}

export const navMessages: Record<UiLocale, NavCatalog> = {
  en: {
    groups: { work: 'Work', tenantAdmin: 'Tenant administration', platform: 'Platform' },
    items: {
      '/instances': 'Instances',
      '/tasks': 'My Tasks',
      '/definitions': 'Definitions',
      '/promotions': 'Promotion Reviews',
      '/dlq': 'DLQ',
      '/webhooks': 'Webhooks',
      '/admin/users': 'Users',
      '/admin/groups': 'Groups',
      '/admin/tokens': 'Tokens',
      '/admin/audit': 'Audit',
      '/admin/print-templates': 'Print Templates',
      '/admin/import': 'Import data',
      '/admin/module-lifecycle': 'Module lifecycle',
      '/admin/health': 'Health',
      '/admin/metrics': 'Metrics',
      '/admin/onboarding/new': 'Register Tenant',
      '/admin/tenants': 'Tenants',
      '/admin/services': 'Services',
      '/admin/platform-migrations': 'Platform Migrations',
      '/solution-packs': 'Solution Packs',
      '/admin/event-retention': 'Event Retention',
      '/admin/codes': 'Codes',
      '/admin/org/legal-entities': 'Legal companies',
      '/admin/org/sites': 'Sites',
      '/admin/org/units': 'Org units',
      '/admin/org/positions': 'Positions',
      '/admin/org/employees': 'Employees',
      '/admin/catalog/lots': 'Lots',
      '/exam': 'Exams',
      '/admin/questions': 'Question Bank',
      '/exam/grading': 'Grading',
    },
  },
  ru: {
    groups: { work: 'Работа', tenantAdmin: 'Администрирование', platform: 'Платформа' },
    items: {
      '/instances': 'Экземпляры',
      '/tasks': 'Мои задачи',
      '/definitions': 'Определения',
      '/promotions': 'Проверка переноса',
      '/dlq': 'Очередь ошибок',
      '/webhooks': 'Вебхуки',
      '/admin/users': 'Пользователи',
      '/admin/groups': 'Группы',
      '/admin/tokens': 'Токены',
      '/admin/audit': 'Аудит',
      '/admin/print-templates': 'Шаблоны печати',
      '/admin/import': 'Импорт данных',
      '/admin/module-lifecycle': 'Жизненный цикл модулей',
      '/admin/health': 'Состояние',
      '/admin/metrics': 'Метрики',
      '/admin/onboarding/new': 'Регистрация организации',
      '/admin/tenants': 'Организации',
      '/admin/services': 'Сервисы',
      '/admin/platform-migrations': 'Миграции платформы',
      '/solution-packs': 'Пакеты решений',
      '/admin/event-retention': 'Хранение событий',
      '/admin/codes': 'Коды',
      '/admin/org/legal-entities': 'Юридические лица',
      '/admin/org/sites': 'Площадки',
      '/admin/org/units': 'Подразделения',
      '/admin/org/positions': 'Должности',
      '/admin/org/employees': 'Сотрудники',
      '/admin/catalog/lots': 'Партии',
      '/exam': 'Экзамены',
      '/admin/questions': 'Банк вопросов',
      '/exam/grading': 'Оценивание',
    },
  },
  kk: {
    groups: { work: 'Жұмыс', tenantAdmin: 'Әкімшілік', platform: 'Платформа' },
    items: {
      '/instances': 'Орындалып жатқан процестер',
      '/tasks': 'Менің тапсырмаларым',
      '/definitions': 'Анықтамалар',
      '/promotions': 'Көшірмені тексеру',
      '/dlq': 'Қателер кезегі',
      '/webhooks': 'Вебхуктар',
      '/admin/users': 'Пайдаланушылар',
      '/admin/groups': 'Топтар',
      '/admin/tokens': 'Токендер',
      '/admin/audit': 'Аудит',
      '/admin/print-templates': 'Басып шығару үлгілері',
      '/admin/import': 'Деректерді импорттау',
      '/admin/module-lifecycle': 'Модульдердің өмірлік циклі',
      '/admin/health': 'Күй',
      '/admin/metrics': 'Метрикалар',
      '/admin/onboarding/new': 'Ұйымды тіркеу',
      '/admin/tenants': 'Ұйымдар',
      '/admin/services': 'Сервистер',
      '/admin/platform-migrations': 'Платформа миграциялары',
      '/solution-packs': 'Шешім пакеттері',
      '/admin/event-retention': 'Оқиғаларды сақтау',
      '/admin/codes': 'Кодтар',
      '/admin/org/legal-entities': 'Заңды тұлғалар',
      '/admin/org/sites': 'Алаңдар',
      '/admin/org/units': 'Бөлімшелер',
      '/admin/org/positions': 'Лауазымдар',
      '/admin/org/employees': 'Қызметкерлер',
      '/admin/catalog/lots': 'Партиялар',
      '/exam': 'Емтихандар',
      '/admin/questions': 'Сұрақтар банкі',
      '/exam/grading': 'Бағалау',
    },
  },
}

/** Label of a menu entry in `locale`; the entry's own (English) label when the route has no translation. */
export function navLabel(locale: UiLocale, to: string, fallback: string): string {
  return navMessages[locale].items[to] ?? fallback
}
