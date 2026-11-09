/** Empty-list texts of the Instances board, per UI language (T-1553). The kk texts are machine drafts
 *  until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface InstancesMessages {
  empty: string
  emptyHint: string
}

export const instancesMessages: Record<UiLocale, InstancesMessages> = {
  en: {
    empty: 'No process instances yet.',
    emptyHint: 'Start one from a process definition.',
  },
  ru: {
    empty: 'Экземпляров процессов пока нет.',
    emptyHint: 'Запустите его из определения процесса.',
  },
  kk: {
    empty: 'Процесс даналары әзірге жоқ.',
    emptyHint: 'Оны процесс анықтамасынан іске қосыңыз.',
  },
}
