/** Empty-list texts of the Definitions list, per UI language (T-1553). The kk texts are machine drafts
 *  until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface DefinitionsMessages {
  empty: string
  emptyHint: string
  /** {term} is the applied search term. */
  emptySearch: string
}

export const definitionsMessages: Record<UiLocale, DefinitionsMessages> = {
  en: {
    empty: 'No definitions found',
    emptyHint: 'Create the first process definition with the create button.',
    emptySearch: 'No results found for "{term}"',
  },
  ru: {
    empty: 'Определений не найдено',
    emptyHint: 'Создайте первое определение процесса кнопкой создания.',
    emptySearch: 'По запросу «{term}» ничего не найдено',
  },
  kk: {
    empty: 'Анықтамалар табылмады',
    emptyHint: 'Алғашқы процесс анықтамасын жасау түймесімен жасаңыз.',
    emptySearch: '«{term}» сұрауы бойынша ештеңе табылмады',
  },
}
