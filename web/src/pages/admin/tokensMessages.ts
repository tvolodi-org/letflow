/** Texts of the admin Tokens page (T-2187, GH #4712), per UI language. Local on purpose: the page has no
 *  IntlProvider (same shape as groupsMessages.ts / usersMessages.ts).
 *  The kk texts are machine drafts until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface TokensMessages {
  title: string
  issueAction: string
  issueTitle: string
  issuedDialog: string
  shownOnce: string
  copyToken: string
  copied: string
  close: string
  targetUser: string
  selectUser: string
  roleSet: string
  rolesPlaceholder: string
  expiryDate: string
  generatedOnce: string
  issueSubmit: string
  cancel: string
  selectUserError: string
  rolesRequiredError: string
  colName: string
  colRoles: string
  colExpires: string
  colCreated: string
  colIssuedBy: string
  colRevoked: string
  colStatus: string
  colActions: string
  statusActive: string
  statusRevoked: string
  statusExpired: string
  statusOwnerInactive: string
  statusUnknown: string
  unknownUser: string
  never: string
  revoke: string
  revokeDialog: string
  revokeTitle: string
  revokeText: string
  revokeConfirm: string
  empty: string
}

export const tokensMessages: Record<UiLocale, TokensMessages> = {
  en: {
    title: 'API Tokens',
    issueAction: '+ Issue token',
    issueTitle: 'Issue token',
    issuedDialog: 'Issued token',
    shownOnce: 'This value will not be shown again.',
    copyToken: 'Copy token',
    copied: 'Copied',
    close: 'Close',
    targetUser: 'Target user',
    selectUser: 'Select a user',
    roleSet: 'Role set',
    rolesPlaceholder: 'Comma-separated roles',
    expiryDate: 'Expiry date',
    generatedOnce: 'The generated value is shown once and can be copied from the confirmation dialog.',
    issueSubmit: 'Issue token',
    cancel: 'Cancel',
    selectUserError: 'Select a target user',
    rolesRequiredError: 'Enter at least one role',
    colName: 'Name',
    colRoles: 'Roles',
    colExpires: 'Expires',
    colCreated: 'Created',
    colIssuedBy: 'Issued by',
    colRevoked: 'Revoked',
    colStatus: 'Status',
    colActions: 'Actions',
    statusActive: 'Active',
    statusRevoked: 'Revoked',
    statusExpired: 'Expired',
    statusOwnerInactive: 'Owner inactive',
    statusUnknown: 'Unknown',
    unknownUser: 'Unknown user',
    never: 'Never',
    revoke: 'Revoke',
    revokeDialog: 'Revoke token',
    revokeTitle: 'Revoke token?',
    revokeText: 'Revoking this API token immediately removes access for the associated user and roles.',
    revokeConfirm: 'Revoke token',
    empty: 'No API tokens found.',
  },
  ru: {
    title: 'API-токены',
    issueAction: '+ Выпустить токен',
    issueTitle: 'Выпуск токена',
    issuedDialog: 'Выпущенный токен',
    shownOnce: 'Это значение больше не будет показано.',
    copyToken: 'Скопировать токен',
    copied: 'Скопировано',
    close: 'Закрыть',
    targetUser: 'Пользователь',
    selectUser: 'Выберите пользователя',
    roleSet: 'Набор ролей',
    rolesPlaceholder: 'Роли через запятую',
    expiryDate: 'Срок действия',
    generatedOnce: 'Сгенерированное значение показывается один раз; его можно скопировать из окна подтверждения.',
    issueSubmit: 'Выпустить токен',
    cancel: 'Отмена',
    selectUserError: 'Выберите пользователя',
    rolesRequiredError: 'Укажите хотя бы одну роль',
    colName: 'Имя',
    colRoles: 'Роли',
    colExpires: 'Истекает',
    colCreated: 'Создан',
    colIssuedBy: 'Кем выпущен',
    colRevoked: 'Отозван',
    colStatus: 'Статус',
    colActions: 'Действия',
    statusActive: 'Активен',
    statusRevoked: 'Отозван',
    statusExpired: 'Истёк',
    statusOwnerInactive: 'Владелец неактивен',
    statusUnknown: 'Неизвестно',
    unknownUser: 'Неизвестный пользователь',
    never: 'Никогда',
    revoke: 'Отозвать',
    revokeDialog: 'Отзыв токена',
    revokeTitle: 'Отозвать токен?',
    revokeText: 'Отзыв этого API-токена сразу лишает доступа связанного пользователя и его роли.',
    revokeConfirm: 'Отозвать токен',
    empty: 'API-токены не найдены.',
  },
  kk: {
    title: 'API-токендер',
    issueAction: '+ Токен шығару',
    issueTitle: 'Токен шығару',
    issuedDialog: 'Шығарылған токен',
    shownOnce: 'Бұл мән қайта көрсетілмейді.',
    copyToken: 'Токенді көшіру',
    copied: 'Көшірілді',
    close: 'Жабу',
    targetUser: 'Пайдаланушы',
    selectUser: 'Пайдаланушыны таңдаңыз',
    roleSet: 'Рөлдер жиыны',
    rolesPlaceholder: 'Рөлдер үтір арқылы',
    expiryDate: 'Жарамдылық мерзімі',
    generatedOnce: 'Жасалған мән бір рет көрсетіледі; оны растау терезесінен көшіруге болады.',
    issueSubmit: 'Токен шығару',
    cancel: 'Бас тарту',
    selectUserError: 'Пайдаланушыны таңдаңыз',
    rolesRequiredError: 'Кемінде бір рөлді көрсетіңіз',
    colName: 'Аты',
    colRoles: 'Рөлдер',
    colExpires: 'Аяқталады',
    colCreated: 'Жасалған',
    colIssuedBy: 'Кім шығарды',
    colRevoked: 'Кері қайтарылған',
    colStatus: 'Күйі',
    colActions: 'Әрекеттер',
    statusActive: 'Белсенді',
    statusRevoked: 'Кері қайтарылған',
    statusExpired: 'Мерзімі өткен',
    statusOwnerInactive: 'Иесі белсенді емес',
    statusUnknown: 'Белгісіз',
    unknownUser: 'Белгісіз пайдаланушы',
    never: 'Ешқашан',
    revoke: 'Кері қайтару',
    revokeDialog: 'Токенді кері қайтару',
    revokeTitle: 'Токенді кері қайтару керек пе?',
    revokeText: 'Бұл API-токенді кері қайтару байланысты пайдаланушы мен рөлдердің қолжетімділігін бірден жояды.',
    revokeConfirm: 'Токенді кері қайтару',
    empty: 'API-токендер табылмады.',
  },
}
