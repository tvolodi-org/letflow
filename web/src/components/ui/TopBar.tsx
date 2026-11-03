/** TopBar — breadcrumbs (phone: only the last crumb), menu button for the drawer, end slot.
 *  Sticky glass comes from the .lf-topbar class. */
import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { ChevronRight, Menu, X } from 'lucide-react'
import { useUiMessages } from './uiMessages'

export interface Crumb {
  label: string
  /** Absent on the last (current) crumb. */
  to?: string
}

export interface TopBarProps {
  crumbs?: Crumb[]
  end?: ReactNode
  /** Drawer state; when `onMenuToggle` is given a menu button is rendered (shown under 900px by CSS). */
  menuOpen?: boolean
  onMenuToggle?: () => void
  menuControls?: string
}

export function TopBar({ crumbs = [], end, menuOpen = false, onMenuToggle, menuControls }: TopBarProps) {
  const t = useUiMessages()
  const lastIndex = crumbs.length - 1
  return (
    <div className="lf-topbar" data-testid="topbar">
      {onMenuToggle != null && (
        <button
          type="button"
          className="lf-btn lf-btn--ghost lf-btn--icon lf-topbar__menu"
          data-testid="topbar-menu"
          aria-label={menuOpen ? t.closeMenu : t.openMenu}
          aria-expanded={menuOpen}
          aria-controls={menuControls}
          onClick={onMenuToggle}
        >
          {menuOpen ? <X className="lf-icon" aria-hidden="true" /> : <Menu className="lf-icon" aria-hidden="true" />}
        </button>
      )}
      {crumbs.length > 0 && (
        <nav className="lf-crumbs" aria-label={t.breadcrumb}>
          {crumbs.map((c, i) => {
            const last = i === lastIndex
            return (
              <span key={`${i}-${c.label}`} className="lf-crumbs__item">
                {i > 0 && <ChevronRight className="lf-icon" aria-hidden="true" />}
                {last || c.to == null ? (
                  <span aria-current={last ? 'page' : undefined}>{c.label}</span>
                ) : (
                  <Link to={c.to}>{c.label}</Link>
                )}
              </span>
            )
          })}
        </nav>
      )}
      {end != null && <div className="lf-topbar__end">{end}</div>}
    </div>
  )
}
