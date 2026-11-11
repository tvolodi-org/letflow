/** Empty-list texts of the Users page, per UI language (T-1553). Local on purpose: the page has no IntlProvider.
 *  The kk texts are machine drafts until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface UsersMessages {
  empty: string
  emptyHint: string
  /** {term} is the applied search term. */
  emptySearch: string
  /** The button that opens the Excel import screen (T-1633). */
  importButton: string
  title: string
  newUser: string
  searchPlaceholder: string
  apply: string
  createUser: string
  cancel: string
  username: string
  displayName: string
  email: string
  password: string
  roles: string
  status: string
  created: string
  active: string
  inactive: string
  /** Success messages of the user detail page (T-1716). */
  saved: string
  deactivated: string
}

export const usersMessages: Record<UiLocale, UsersMessages> = {
  en: {
    empty: 'No users yet.',
    emptyHint: 'Create the first one with the "New User" button above.',
    emptySearch: 'No users match "{term}".',
    importButton: 'Import from Excel',
    title: 'Users',
    newUser: '+ New User',
    searchPlaceholder: 'Search users',
    apply: 'Apply',
    createUser: 'Create user',
    cancel: 'Cancel',
    username: 'Username',
    displayName: 'Display name',
    email: 'Email',
    password: 'Password',
    roles: 'Roles',
    status: 'Status',
    created: 'Created',
    active: 'ACTIVE',
    inactive: 'INACTIVE',
    saved: 'Saved',
    deactivated: 'User deactivated',
  },
  ru: {
    empty: 'Пользователей пока нет.',
    emptyHint: 'Создайте первого кнопкой «Новый пользователь» выше.',
    emptySearch: 'По запросу «{term}» пользователей не найдено.',
    importButton: 'Импорт из Excel',
    title: 'Пользователи',
    newUser: '+ Новый пользователь',
    searchPlaceholder: 'Поиск пользователей',
    apply: 'Применить',
    createUser: 'Создать пользователя',
    cancel: 'Отмена',
    username: 'Имя пользователя',
    displayName: 'Отображаемое имя',
    email: 'Эл. почта',
    password: 'Пароль',
    roles: 'Роли',
    status: 'Статус',
    created: 'Создан',
    active: 'АКТИВЕН',
    inactive: 'НЕАКТИВЕН',
    saved: 'Сохранено',
    deactivated: 'Пользователь деактивирован',
  },
  kk: {
    empty: 'Пайдаланушылар әзірге жоқ.',
    emptyHint: 'Біріншісін жоғарыдағы «Жаңа пайдаланушы» түймесімен жасаңыз.',
    emptySearch: '«{term}» сұрауы бойынша пайдаланушы табылмады.',
    importButton: 'Excel-ден импорттау',
    title: 'Пайдаланушылар',
    newUser: '+ Жаңа пайдаланушы',
    searchPlaceholder: 'Пайдаланушыларды іздеу',
    apply: 'Қолдану',
    createUser: 'Пайдаланушы жасау',
    cancel: 'Болдырмау',
    username: 'Пайдаланушы аты',
    displayName: 'Көрсетілетін аты',
    email: 'Эл. пошта',
    password: 'Құпиясөз',
    roles: 'Рөлдер',
    status: 'Күйі',
    created: 'Жасалды',
    active: 'БЕЛСЕНДІ',
    inactive: 'БЕЛСЕНДІ ЕМЕС',
    saved: 'Сақталды',
    deactivated: 'Пайдаланушы өшірілді',
  },
}
