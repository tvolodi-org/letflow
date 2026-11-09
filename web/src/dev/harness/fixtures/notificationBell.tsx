/** Harness fixtures of the notification bell (T-1561). Invented data only. `notification-bell` opens the popover
 *  (state default = some unread, empty, loading, error); `notification-bell-closed` shows the badge with 3 unread and
 *  `notification-bell-99` the "99+" badge. The bell reads the signed-in session, so a stub is provided. */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { NotificationBell } from '@/components/layout/NotificationBell'
import { TopBar } from '@/components/ui/TopBar'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

const NOW = Date.now()
const ago = (min: number) => new Date(NOW - min * 60_000).toISOString()
const ROWS = [
  { id: 'n1', kind: 'task_assigned', ref_id: 't1', title: 'Approve stock count SC-0042', read: false, inserted_at: ago(3) },
  { id: 'n2', kind: 'task_assigned', ref_id: 't2', title: 'Post the receipt document', read: false, inserted_at: ago(55) },
  { id: 'n3', kind: 'task_assigned', ref_id: 't3', title: 'Review', read: false, inserted_at: ago(300) },
  { id: 'n4', kind: 'task_assigned', ref_id: 't4', title: 'Check the opening balances', read: true, inserted_at: ago(2000) },
  { id: 'n5', kind: 'future_kind', ref_id: null, title: '', read: true, inserted_at: ago(4000) },
]

const route = (unread: number): FixtureRoute => ({
  match: (path, method) => path === '/api/v1/me/notifications' && method === 'GET',
  reply: (state) =>
    state === 'error'
      ? { status: 500, body: { title: 'error' } }
      : state === 'empty'
        ? { status: 200, body: { notifications: [], unread_count: 0 } }
        : { status: 200, body: { notifications: ROWS, unread_count: unread } },
})

function OpenOnMount({ active }: { active: boolean }) {
  useEffect(() => {
    if (!active) return
    const frame = requestAnimationFrame(() => document.querySelector<HTMLElement>('[data-testid="notification-bell-trigger"]')?.click())
    return () => cancelAnimationFrame(frame)
  }, [active])
  return null
}

function page(open: boolean): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <div className="lf-main">
        <TopBar end={<NotificationBell />} />
        <OpenOnMount active={open} />
      </div>
    </AuthContext.Provider>
  )
}

export const notificationBellScreens: HarnessScreen[] = [
  { name: 'notification-bell', routes: [route(3)], render: () => page(true) },
  { name: 'notification-bell-closed', routes: [route(3)], render: () => page(false) },
  { name: 'notification-bell-99', routes: [route(120)], render: () => page(false) },
]
