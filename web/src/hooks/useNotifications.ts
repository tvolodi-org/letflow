/** useNotifications — the bell's list from `GET /api/v1/me/notifications`, polled every 60 s, and the mark-read
 *  actions (T-1561). Non-critical: a failed read leaves the shell usable (the bell shows its error state).
 *  Mark-read calls the API and then refetches the list; it uses `useQuery` only, so the shell tests that stub
 *  this one react-query hook keep working. */
import { useQuery } from '@tanstack/react-query'
import { notificationsApi } from '@/api/notifications'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useAuth } from '@/auth/AuthContext'

export const NOTIFICATIONS_POLL_MS = 60_000

export function useNotifications() {
  const { isAuthenticated } = useAuth()
  const key = useTenantScopedQueryKeys().me.notifications()
  const query = useQuery({
    queryKey: key,
    queryFn: () => notificationsApi.list(),
    enabled: isAuthenticated,
    refetchInterval: NOTIFICATIONS_POLL_MS,
    refetchOnWindowFocus: false,
    retry: false,
  })
  const refresh = () => void query.refetch?.()
  const markRead = (ids: string[]) => void notificationsApi.markRead(ids).catch(() => undefined).finally(refresh)
  const markAllRead = () => void notificationsApi.markAllRead().catch(() => undefined).finally(refresh)
  return { query, markRead, markAllRead }
}
