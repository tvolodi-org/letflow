/** notificationMessages — strings of the notification bell (T-1561; en, ru, kk). One text per known kind. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface NotificationCatalog {
  bell: string
  bellUnread: string
  title: string
  markAll: string
  empty: string
  loading: string
  error: string
  retry: string
  close: string
  unread: string
  kindTaskAssigned: string
  kindCountAssigned: string
  kindProblemReceived: string
  kindProblemInWork: string
  kindProblemQuestion: string
  kindProblemAnswered: string
  kindProblemFixed: string
  kindProblemNotDone: string
  kindUnknown: string
}

export const notificationMessages: Record<UiLocale, NotificationCatalog> = {
  en: {
    bell: 'Notifications',
    bellUnread: 'Notifications, {count} unread',
    title: 'Notifications',
    markAll: 'Mark all as read',
    empty: 'No notifications yet.',
    loading: 'Loading notifications',
    error: 'Could not load notifications.',
    retry: 'Try again',
    close: 'Close',
    unread: 'Unread',
    kindTaskAssigned: 'A task was assigned to you',
    kindCountAssigned: 'A stock count was assigned to you',
    kindProblemReceived: 'Your problem report was received',
    kindProblemInWork: 'Your problem report is in work',
    kindProblemQuestion: 'A question about your problem report',
    kindProblemAnswered: 'Your problem report was answered',
    kindProblemFixed: 'The problem you reported is fixed',
    kindProblemNotDone: 'Your problem report was closed without a change',
    kindUnknown: 'New notification',
  },
  ru: {
    bell: 'Уведомления',
    bellUnread: 'Уведомления, непрочитанных: {count}',
    title: 'Уведомления',
    markAll: 'Отметить все прочитанными',
    empty: 'Уведомлений пока нет.',
    loading: 'Загрузка уведомлений',
    error: 'Не удалось загрузить уведомления.',
    retry: 'Повторить',
    close: 'Закрыть',
    unread: 'Не прочитано',
    kindTaskAssigned: 'Вам назначена задача',
    kindCountAssigned: 'Вам назначена инвентаризация',
    kindProblemReceived: 'Ваше сообщение о проблеме получено',
    kindProblemInWork: 'Ваше сообщение о проблеме взято в работу',
    kindProblemQuestion: 'Вопрос по вашему сообщению о проблеме',
    kindProblemAnswered: 'На ваше сообщение о проблеме дан ответ',
    kindProblemFixed: 'Проблема из вашего сообщения исправлена',
    kindProblemNotDone: 'Ваше сообщение о проблеме закрыто без изменений',
    kindUnknown: 'Новое уведомление',
  },
  kk: {
    bell: 'Хабарландырулар',
    bellUnread: 'Хабарландырулар, оқылмаған: {count}',
    title: 'Хабарландырулар',
    markAll: 'Барлығын оқылған деп белгілеу',
    empty: 'Хабарландырулар әлі жоқ.',
    loading: 'Хабарландырулар жүктелуде',
    error: 'Хабарландыруларды жүктеу мүмкін болмады.',
    retry: 'Қайталау',
    close: 'Жабу',
    unread: 'Оқылмаған',
    kindTaskAssigned: 'Сізге тапсырма тағайындалды',
    kindCountAssigned: 'Сізге түгендеу тағайындалды',
    kindProblemReceived: 'Мәселе туралы хабарламаңыз қабылданды',
    kindProblemInWork: 'Мәселе туралы хабарламаңыз жұмысқа алынды',
    kindProblemQuestion: 'Мәселе туралы хабарламаңыз бойынша сұрақ',
    kindProblemAnswered: 'Мәселе туралы хабарламаңызға жауап берілді',
    kindProblemFixed: 'Сіз хабарлаған мәселе түзетілді',
    kindProblemNotDone: 'Мәселе туралы хабарламаңыз өзгеріссіз жабылды',
    kindUnknown: 'Жаңа хабарландыру',
  },
}

/** Link of a row, built from `kind` + `ref_id`; `null` for an unknown kind (a generic row has no link). */
export function notificationLink(kind: string, refId: string | null): string | null {
  if (!refId) return null
  const id = encodeURIComponent(refId)
  if (kind === 'task_assigned') return `/tasks?task=${id}`
  if (kind === 'count_assigned') return `/admin/stock/counts/${id}`
  return null
}

export function notificationText(m: NotificationCatalog, kind: string): string {
  if (kind === 'task_assigned') return m.kindTaskAssigned
  if (kind === 'count_assigned') return m.kindCountAssigned
  if (kind === 'problem_report_received') return m.kindProblemReceived
  if (kind === 'problem_report_in_work') return m.kindProblemInWork
  if (kind === 'problem_report_question') return m.kindProblemQuestion
  if (kind === 'problem_report_answered') return m.kindProblemAnswered
  if (kind === 'problem_report_fixed') return m.kindProblemFixed
  if (kind === 'problem_report_not_done') return m.kindProblemNotDone
  return m.kindUnknown
}
