/** NotificationBell — the app shell's in-app notification list (T-1561): a bell with an unread badge (hidden at 0,
 *  "99+" cap) and a popover list. A row shows the kind text, the title and the time, with an unread dot; a click marks
 *  it read and follows its link. An unknown kind is a generic row with no link. Esc closes and returns focus. */
import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Bell, ListTodo, Info } from 'lucide-react'
import { useNotifications } from '@/hooks/useNotifications'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { formatDateTime } from '@/i18n/format'
import type { NotificationItem } from '@/api/notifications'
import { notificationLink, notificationMessages, notificationText } from './notificationMessages'

export function badgeText(count: number): string {
  return count > 99 ? '99+' : String(count)
}

export function NotificationBell() {
  const locale = useUiLocale()
  const m = notificationMessages[locale]
  const navigate = useNavigate()
  const { query, markRead, markAllRead } = useNotifications()
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)
  const trigger = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => {
      if (root.current && !root.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    return () => document.removeEventListener('mousedown', onDown)
  }, [open])

  const unread = query.data?.unread_count ?? 0
  const items = query.data?.notifications ?? []

  const close = () => {
    setOpen(false)
    trigger.current?.focus()
  }

  const onRow = (n: NotificationItem) => {
    if (!n.read) markRead([n.id])
    const link = notificationLink(n.kind, n.ref_id)
    if (link) {
      setOpen(false)
      navigate(link)
    }
  }

  return (
    <div
      className="lf-bell"
      ref={root}
      data-testid="notification-bell"
      onKeyDown={(e) => {
        if (e.key === 'Escape' && open) {
          e.stopPropagation()
          close()
        }
      }}
    >
      <button
        ref={trigger}
        type="button"
        className="lf-btn lf-btn--ghost lf-btn--icon lf-bell__trigger"
        aria-haspopup="true"
        aria-expanded={open}
        aria-label={unread > 0 ? m.bellUnread.replace('{count}', String(unread)) : m.bell}
        title={m.bell}
        data-testid="notification-bell-trigger"
        onClick={() => setOpen((o) => !o)}
      >
        <Bell className="lf-icon" aria-hidden="true" />
        {unread > 0 && (
          <span className="lf-bell__badge" data-testid="notification-bell-badge" aria-hidden="true">
            {badgeText(unread)}
          </span>
        )}
      </button>
      {open && (
        <div className="lf-lang__menu lf-bell__panel" role="region" aria-label={m.title} data-testid="notification-panel">
          <div className="lf-bell__head">
            <strong>{m.title}</strong>
            <button
              type="button"
              className="lf-btn lf-btn--ghost lf-btn--s"
              disabled={unread === 0}
              onClick={markAllRead}
              data-testid="notification-mark-all"
            >
              {m.markAll}
            </button>
          </div>
          {query.isLoading ? (
            <p className="lf-bell__state" role="status" data-testid="notification-loading">
              {m.loading}
            </p>
          ) : query.isError ? (
            <div className="lf-bell__state" role="alert" data-testid="notification-error">
              <p>{m.error}</p>
              <button type="button" className="lf-btn lf-btn--secondary lf-btn--s" onClick={() => void query.refetch()}>
                {m.retry}
              </button>
            </div>
          ) : items.length === 0 ? (
            <p className="lf-bell__state" data-testid="notification-empty">
              {m.empty}
            </p>
          ) : (
            <ul className="lf-bell__list">
              {items.map((n) => {
                const Icon = n.kind === 'task_assigned' ? ListTodo : Info
                return (
                  <li key={n.id}>
                    <button
                      type="button"
                      className="lf-lang__item lf-bell__row"
                      data-read={n.read ? 'true' : 'false'}
                      data-testid="notification-row"
                      onClick={() => onRow(n)}
                    >
                      <Icon className="lf-icon" aria-hidden="true" />
                      <span className="lf-bell__text">
                        <span>{notificationText(m, n.kind)}</span>
                        {n.title && <span className="lf-bell__title">{n.title}</span>}
                        <span className="lf-bell__time">{formatDateTime(n.inserted_at, { second: undefined }, locale)}</span>
                      </span>
                      {!n.read && <span className="lf-bell__dot" role="img" aria-label={m.unread} />}
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      )}
    </div>
  )
}
