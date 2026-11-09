/** Empty-list texts of the Users page, per UI language (T-1553). Local on purpose: the page has no IntlProvider.
 *  The kk texts are machine drafts until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface UsersMessages {
  empty: string
  emptyHint: string
  /** {term} is the applied search term. */
  emptySearch: string
}

export const usersMessages: Record<UiLocale, UsersMessages> = {
  en: {
    empty: 'No users yet.',
    emptyHint: 'Create the first one with the "New User" button above.',
    emptySearch: 'No users match "{term}".',
  },
  ru: {
    empty: 'Пользователей пока нет.',
    emptyHint: 'Создайте первого кнопкой «Новый пользователь» выше.',
    emptySearch: 'По запросу «{term}» пользователей не найдено.',
  },
  kk: {
    empty: 'Пайдаланушылар әзірге жоқ.',
    emptyHint: 'Біріншісін жоғарыдағы «Жаңа пайдаланушы» түймесімен жасаңыз.',
    emptySearch: '«{term}» сұрауы бойынша пайдаланушы табылмады.',
  },
}
