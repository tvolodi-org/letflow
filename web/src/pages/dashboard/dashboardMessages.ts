/** Texts of the tenant home page, per UI language. Local on purpose: the page has no IntlProvider. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface DashboardMessages {
  welcome: string
  tenantUnknown: string
  recentDefinitions: string
  activeInstances: string
  pendingTasks: string
  noDefinitions: string
}

export const dashboardMessages: Record<UiLocale, DashboardMessages> = {
  en: {
    welcome: 'Here is a summary of your current activity.',
    tenantUnknown: 'Tenant name could not be loaded. Contact your administrator.',
    recentDefinitions: 'Recent Definitions',
    activeInstances: 'Active Instances',
    pendingTasks: 'Pending Tasks',
    noDefinitions: 'No definitions yet.',
  },
  ru: {
    welcome: 'Сводка вашей текущей активности.',
    tenantUnknown: 'Не удалось загрузить название организации. Обратитесь к администратору.',
    recentDefinitions: 'Последние определения',
    activeInstances: 'Активные экземпляры',
    pendingTasks: 'Задачи в ожидании',
    noDefinitions: 'Определений пока нет.',
  },
  kk: {
    welcome: 'Ағымдағы белсенділігіңіздің қысқаша мазмұны.',
    tenantUnknown: 'Ұйым атауын жүктеу мүмкін болмады. Әкімшіге хабарласыңыз.',
    recentDefinitions: 'Соңғы анықтамалар',
    activeInstances: 'Белсенді даналар',
    pendingTasks: 'Күтіп тұрған тапсырмалар',
    noDefinitions: 'Анықтамалар әзірге жоқ.',
  },
}
