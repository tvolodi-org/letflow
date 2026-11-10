// @vitest-environment jsdom
/** T-1561: the notification bell: badge (hidden at 0, 99+), states, click marks read and navigates, unknown kind. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, fireEvent } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { useUiLocaleStore, UI_LOCALES } from '@/i18n/uiLocaleStore'
import { badgeText, NotificationBell } from '../NotificationBell'
import { notificationLink, notificationMessages, notificationText } from '../notificationMessages'

expect.extend(jestDomMatchers)

const state: { data?: unknown; isLoading?: boolean; isError?: boolean } = {}
const refetch = vi.fn()
vi.mock('@tanstack/react-query', () => ({ useQuery: vi.fn(() => ({ ...state, refetch })) }))
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ isAuthenticated: true, session: { tenant_id: 'tid' } }),
}))
const markRead = vi.fn((...args: string[][]) => Promise.resolve({ marked: args.length, unread_count: 0 }))
const markAllRead = vi.fn(() => Promise.resolve({ marked: 1, unread_count: 0 }))
vi.mock('@/api/notifications', () => ({
  notificationsApi: { list: vi.fn(), markRead: (ids: string[]) => (markRead as (i: string[]) => unknown)(ids), markAllRead: () => markAllRead() },
}))

const row = (over: Record<string, unknown> = {}) => ({
  id: 'n1', kind: 'task_assigned', ref_id: 'task-1', title: 'Review', read: false, inserted_at: '2026-11-09T10:00:00Z', ...over,
})

function Where() {
  const l = useLocation()
  return <div data-testid="where">{l.pathname + l.search}</div>
}
function renderBell() {
  return render(
    <MemoryRouter>
      <Routes>
        <Route path="*" element={<><NotificationBell /><Where /></>} />
      </Routes>
    </MemoryRouter>,
  )
}

beforeEach(() => {
  useUiLocaleStore.getState().setLocaleTransient('en')
  state.data = { notifications: [], unread_count: 0 }
  state.isLoading = false
  state.isError = false
  vi.clearAllMocks()
})
afterEach(() => cleanup())

describe('NotificationBell', () => {
  it('W1 badge is hidden at 0, shows the count, caps at 99+', () => {
    renderBell()
    expect(screen.queryByTestId('notification-bell-badge')).toBeNull()
    cleanup()
    state.data = { notifications: [row()], unread_count: 3 }
    renderBell()
    expect(screen.getByTestId('notification-bell-badge')).toHaveTextContent('3')
    expect(screen.getByTestId('notification-bell-trigger')).toHaveAttribute('aria-label', 'Notifications, 3 unread')
    expect(badgeText(100)).toBe('99+')
    expect(badgeText(99)).toBe('99')
  })

  it('W2 empty, loading and error states', () => {
    renderBell()
    fireEvent.click(screen.getByTestId('notification-bell-trigger'))
    expect(screen.getByTestId('notification-empty')).toBeInTheDocument()
    cleanup()
    state.isLoading = true
    renderBell()
    fireEvent.click(screen.getByTestId('notification-bell-trigger'))
    expect(screen.getByTestId('notification-loading')).toBeInTheDocument()
    cleanup()
    state.isLoading = false
    state.isError = true
    renderBell()
    fireEvent.click(screen.getByTestId('notification-bell-trigger'))
    fireEvent.click(screen.getByText('Try again'))
    expect(refetch).toHaveBeenCalled()
  })

  it('W3 a row click marks it read and goes to the task', () => {
    state.data = { notifications: [row()], unread_count: 1 }
    renderBell()
    fireEvent.click(screen.getByTestId('notification-bell-trigger'))
    fireEvent.click(screen.getByTestId('notification-row'))
    expect(markRead).toHaveBeenCalledWith(['n1'])
    expect(screen.getByTestId('where')).toHaveTextContent('/tasks?task=task-1')
    expect(screen.queryByTestId('notification-panel')).toBeNull()
  })

  it('W3b mark all as read; Escape closes and returns focus', () => {
    state.data = { notifications: [row(), row({ id: 'n2' })], unread_count: 2 }
    renderBell()
    const trigger = screen.getByTestId('notification-bell-trigger')
    fireEvent.click(trigger)
    fireEvent.click(screen.getByTestId('notification-mark-all'))
    expect(markAllRead).toHaveBeenCalled()
    fireEvent.keyDown(screen.getByTestId('notification-panel'), { key: 'Escape' })
    expect(screen.queryByTestId('notification-panel')).toBeNull()
    expect(trigger).toHaveFocus()
  })

  it('W5 an unknown kind is a generic row with no link and no navigation', () => {
    state.data = { notifications: [row({ kind: 'from_the_future', read: true })], unread_count: 0 }
    renderBell()
    fireEvent.click(screen.getByTestId('notification-bell-trigger'))
    expect(screen.getByText(notificationMessages.en.kindUnknown)).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('notification-row'))
    expect(markRead).not.toHaveBeenCalled()
    expect(screen.getByTestId('where')).toHaveTextContent('/')
    expect(notificationLink('from_the_future', 'x')).toBeNull()
    expect(notificationLink('task_assigned', null)).toBeNull()
  })

  it('W6 count_assigned has its text in every locale and links to the count', () => {
    expect(notificationLink('count_assigned', 'c 1')).toBe('/admin/stock/counts/c%201')
    expect(notificationLink('count_assigned', null)).toBeNull()
    for (const l of UI_LOCALES) {
      expect(notificationText(notificationMessages[l], 'count_assigned')).toBe(notificationMessages[l].kindCountAssigned)
      expect(notificationMessages[l].kindCountAssigned).not.toBe(notificationMessages[l].kindUnknown)
    }
    state.data = { notifications: [row({ kind: 'count_assigned', ref_id: 'c1', title: 'CO-1' })], unread_count: 1 }
    renderBell()
    fireEvent.click(screen.getByTestId('notification-bell-trigger'))
    expect(screen.getByText(notificationMessages.en.kindCountAssigned)).toBeInTheDocument()
  })

  it('W4 every locale has every string', () => {
    const keys = Object.keys(notificationMessages.en).sort()
    for (const l of UI_LOCALES) {
      expect(Object.keys(notificationMessages[l]).sort()).toEqual(keys)
      for (const k of keys) expect((notificationMessages[l] as unknown as Record<string, string>)[k].length).toBeGreaterThan(0)
    }
  })
})
