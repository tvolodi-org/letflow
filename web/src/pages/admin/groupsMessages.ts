/** Texts added to the Groups page by T-1610 (bulk add, search, roles column, last-administrator warning), per UI
 *  language. Local on purpose: the page has no IntlProvider (same shape as usersMessages.ts).
 *  The kk texts are machine drafts until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface GroupsMessages {
  rolesHeader: string
  noRoles: string
  /** {roles} is a comma-separated list of role names. */
  givesRole: string
  searchLabel: string
  searchPlaceholder: string
  selectAllShown: string
  addSelected: string
  inactiveTag: string
  noMatch: string
  allAlreadyMembers: string
  moreMatch: string
  /** {ok} and {failed} are counts. */
  addSummary: string
  /** {names} is a comma-separated list of user names. */
  addFailedNames: string
  lastAdminTitle: string
  lastAdminText: string
  removeAnyway: string
  cancel: string
  removeRefused: string
  deleteRefused: string
}

export const groupsMessages: Record<UiLocale, GroupsMessages> = {
  en: {
    rolesHeader: 'Roles',
    noRoles: '—',
    givesRole: 'Gives role: {roles}',
    searchLabel: 'Find a user by name, login or e-mail',
    searchPlaceholder: 'Start typing a name',
    selectAllShown: 'Select all shown',
    addSelected: 'Add selected ({n})',
    inactiveTag: 'inactive',
    noMatch: 'No users match this search.',
    allAlreadyMembers: 'Everyone found is already a member.',
    moreMatch: 'More users match. Narrow the search to see them.',
    addSummary: 'Added {ok}, failed {failed}.',
    addFailedNames: 'Not added: {names}. They stay selected; click Add selected to try again.',
    lastAdminTitle: 'Remove the last administrator?',
    lastAdminText:
      'This is the last administrator. Removing them leaves the company without one; the system may refuse.',
    removeAnyway: 'Remove anyway',
    cancel: 'Cancel',
    removeRefused: 'The system refused: the company must keep at least one administrator.',
    deleteRefused: 'The system refused to delete this group: it is bound to a role or holds the last administrator.',
  },
  ru: {
    rolesHeader: 'Роли',
    noRoles: '—',
    givesRole: 'Даёт роль: {roles}',
    searchLabel: 'Найти пользователя по имени, логину или e-mail',
    searchPlaceholder: 'Начните вводить имя',
    selectAllShown: 'Выбрать всех показанных',
    addSelected: 'Добавить выбранных ({n})',
    inactiveTag: 'неактивен',
    noMatch: 'По этому запросу пользователей нет.',
    allAlreadyMembers: 'Все найденные уже состоят в группе.',
    moreMatch: 'Подходит больше пользователей. Уточните запрос, чтобы увидеть их.',
    addSummary: 'Добавлено {ok}, не удалось {failed}.',
    addFailedNames: 'Не добавлены: {names}. Они остаются выбранными; нажмите «Добавить выбранных», чтобы повторить.',
    lastAdminTitle: 'Удалить последнего администратора?',
    lastAdminText:
      'Это последний администратор. Без него в компании не останется администратора; система может отказать.',
    removeAnyway: 'Всё равно удалить',
    cancel: 'Отмена',
    removeRefused: 'Система отказала: в компании должен остаться хотя бы один администратор.',
    deleteRefused: 'Система отказалась удалить группу: она связана с ролью или содержит последнего администратора.',
  },
  kk: {
    rolesHeader: 'Рөлдер',
    noRoles: '—',
    givesRole: 'Беретін рөл: {roles}',
    searchLabel: 'Пайдаланушыны аты, логині немесе e-mail бойынша табу',
    searchPlaceholder: 'Атын теруді бастаңыз',
    selectAllShown: 'Көрсетілгендердің бәрін таңдау',
    addSelected: 'Таңдалғандарды қосу ({n})',
    inactiveTag: 'белсенді емес',
    noMatch: 'Бұл сұрау бойынша пайдаланушы жоқ.',
    allAlreadyMembers: 'Табылғандардың бәрі топта бар.',
    moreMatch: 'Көбірек пайдаланушы сәйкес келеді. Көру үшін сұранысты нақтылаңыз.',
    addSummary: 'Қосылды {ok}, қосылмады {failed}.',
    addFailedNames: 'Қосылмады: {names}. Олар таңдалған күйде қалады; қайталау үшін «Таңдалғандарды қосу» түймесін басыңыз.',
    lastAdminTitle: 'Соңғы әкімшіні жою керек пе?',
    lastAdminText:
      'Бұл соңғы әкімші. Оны алып тастасаңыз, компанияда әкімші қалмайды; жүйе бас тартуы мүмкін.',
    removeAnyway: 'Бәрібір алып тастау',
    cancel: 'Бас тарту',
    removeRefused: 'Жүйе бас тартты: компанияда кемінде бір әкімші қалуы керек.',
    deleteRefused: 'Жүйе топты жоюдан бас тартты: ол рөлмен байланысты немесе соңғы әкімшіні қамтиды.',
  },
}

export function fillGroups(template: string, vars: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (_, k: string) => String(vars[k] ?? ''))
}
