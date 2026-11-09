/** Notifications API — `GET /api/v1/me/notifications` and `POST /api/v1/me/notifications/read` (T-1561).
 *  The caller's own in-app list (the bell). No tenant or user id is sent: the server takes both from the token (INV-10). */
import { client } from './client'

export interface NotificationItem {
  id: string
  /** Closed list on the server; today only `task_assigned`. An unknown kind renders as a generic row. */
  kind: string
  ref_id: string | null
  title: string
  read: boolean
  inserted_at: string
}

export interface NotificationsAnswer {
  notifications: NotificationItem[]
  unread_count: number
}

export interface MarkReadAnswer {
  marked: number
  unread_count: number
}

export const notificationsApi = {
  list: () => client.get<NotificationsAnswer>('/api/v1/me/notifications'),
  markRead: (ids: string[]) => client.post<MarkReadAnswer>('/api/v1/me/notifications/read', { ids }),
  markAllRead: () => client.post<MarkReadAnswer>('/api/v1/me/notifications/read', { all: true }),
}
