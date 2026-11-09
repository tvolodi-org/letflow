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
    kindUnknown: 'Жаңа хабарландыру',
  },
}

/** Link of a row, built from `kind` + `ref_id`; `null` for an unknown kind (a generic row has no link). */
export function notificationLink(kind: string, refId: string | null): string | null {
  if (kind === 'task_assigned' && refId) return `/tasks?task=${encodeURIComponent(refId)}`
  return null
}

export function notificationText(m: NotificationCatalog, kind: string): string {
  return kind === 'task_assigned' ? m.kindTaskAssigned : m.kindUnknown
}
