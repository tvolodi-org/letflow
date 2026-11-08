/**
 * Display names and one-sentence descriptions of the built-in roles in en, ru and kk (T-1317, D-093).
 * The server sends the role id only; the access screens translate it here. Role names may appear only inside
 * this directory (tests/guards/no-role-literals.spec.ts). A name that is not a built-in (a routing role is a
 * free string) is shown as it is.
 */
import { getUiLocale, type UiLocale } from '../../i18n/uiLocaleStore'
import { ROLES, type Role } from './roles'

export type RoleText = { name: string; description: string }

export const ROLE_LABELS: Record<Role, Record<UiLocale, RoleText>> = {
  PLATFORM_ADMIN: {
    en: { name: 'Platform administrator', description: 'Operates the Letflow platform across tenants.' },
    ru: { name: 'Администратор платформы', description: 'Управляет платформой Letflow для всех организаций.' },
    kk: { name: 'Платформа әкімшісі', description: 'Letflow платформасын барлық ұйымдар үшін басқарады.' },
  },
  PROCESS_DESIGNER: {
    en: { name: 'Process designer', description: 'Designs process definitions, forms and scripts.' },
    ru: { name: 'Проектировщик процессов', description: 'Создаёт определения процессов, формы и скрипты.' },
    kk: { name: 'Процесс жобалаушы', description: 'Процесс анықтамаларын, пішіндер мен скрипттерді жасайды.' },
  },
  PROCESS_OPERATOR: {
    en: { name: 'Process operator', description: 'Starts, watches and cancels running process instances.' },
    ru: { name: 'Оператор процессов', description: 'Запускает, отслеживает и отменяет запущенные процессы.' },
    kk: { name: 'Процесс операторы', description: 'Іске қосылған процестерді бастайды, бақылайды және тоқтатады.' },
  },
  TASK_WORKER: {
    en: { name: 'Task worker', description: 'Works on the tasks assigned to them or their groups.' },
    ru: { name: 'Исполнитель задач', description: 'Выполняет задачи, назначенные ему или его группам.' },
    kk: { name: 'Тапсырма орындаушысы', description: 'Өзіне немесе топтарына берілген тапсырмаларды орындайды.' },
  },
  AGENT_RUNNER: {
    en: { name: 'Agent runner', description: 'Technical role for automated agents.' },
    ru: { name: 'Агент-исполнитель', description: 'Техническая роль для автоматических агентов.' },
    kk: { name: 'Агент орындаушысы', description: 'Автоматты агенттерге арналған техникалық рөл.' },
  },
  CANDIDATE: {
    en: { name: 'Candidate', description: 'Takes an exam; sees only their own sessions.' },
    ru: { name: 'Кандидат', description: 'Сдаёт экзамен; видит только свои сессии.' },
    kk: { name: 'Үміткер', description: 'Емтихан тапсырады; тек өз сессияларын көреді.' },
  },
  TENANT_ADMIN: {
    en: { name: 'Organisation administrator', description: 'Manages users, roles, modules and settings of the organisation.' },
    ru: { name: 'Администратор организации', description: 'Управляет пользователями, ролями, модулями и настройками организации.' },
    kk: { name: 'Ұйым әкімшісі', description: 'Ұйымның пайдаланушыларын, рөлдерін, модульдерін және баптауларын басқарады.' },
  },
  TENANT_AUDITOR: {
    en: { name: 'Auditor', description: 'Reads data, tasks and the audit log; changes nothing.' },
    ru: { name: 'Аудитор', description: 'Читает данные, задачи и журнал аудита; ничего не меняет.' },
    kk: { name: 'Аудитор', description: 'Деректерді, тапсырмаларды және аудит журналын оқиды; ештеңені өзгертпейді.' },
  },
  STOREKEEPER: {
    en: { name: 'Storekeeper', description: 'Stock documents, counts, balances and movements; reads and posts assets; no administration.' },
    ru: { name: 'Кладовщик', description: 'Складские документы, инвентаризации, остатки и движения; просмотр и проведение активов; без администрирования.' },
    kk: { name: 'Қоймашы', description: 'Қойма құжаттары, түгендеу, қалдықтар мен қозғалыстар; активтерді көру және жүргізу; әкімшілік құқықсыз.' },
  },
}

function builtIn(name: string): Role | null {
  return (ROLES as readonly string[]).includes(name) ? (name as Role) : null
}

/** The translated name of a built-in role, or `name` itself for any other (routing) role. */
export function roleLabel(name: string, locale: UiLocale = getUiLocale()): string {
  const role = builtIn(name)
  return role ? ROLE_LABELS[role][locale].name : name
}

/** The one-sentence description of a built-in role, or '' for any other role. */
export function roleDescription(name: string, locale: UiLocale = getUiLocale()): string {
  const role = builtIn(name)
  return role ? ROLE_LABELS[role][locale].description : ''
}
