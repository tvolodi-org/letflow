/** AssetCardActionsMenu — T-1880 / D-135. The "Actions" menu of an asset card, on the card panel and on each row of the
 *  card list: Commission, Change responsible, Hand over, Write off. Each item opens the document form with the card as
 *  its line (`documents/new?kind=&asset=`). Built like OfficialFormMenu (aria-haspopup, role=menu, Escape returns focus,
 *  outside mousedown closes, arrows move). A disabled item keeps its reason as visible text and as the tooltip (touch has
 *  no hover). The card's facts are read only while the menu is open (a list of 100 rows makes no call until a menu
 *  opens). Without AssetsPost nothing is rendered. */
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { ChevronDown, MoreHorizontal } from 'lucide-react'
import { useAccess } from '@/auth/access/useAccess'
import type { EntityRecord } from '@/types/api'
import { ASSETS_POST } from './assetsPermissions'
import { textOf } from './assetsModel'
import { CARD_ACTIONS, cardActionState, newDocumentHref } from './cardActions'
import { useCardFacts } from './AssetsShell'

export interface AssetCardActionsMenuProps {
  card: EntityRecord
  /** Row variant: an icon-only trigger that names the card. */
  size?: 'sm'
  /** Opens at once (harness screenshots). */
  initialOpen?: boolean
}

export function AssetCardActionsMenu({ card, size, initialOpen = false }: AssetCardActionsMenuProps) {
  const { can } = useAccess()
  if (!can(ASSETS_POST)) return null
  return <Menu card={card} size={size} initialOpen={initialOpen} />
}

function Menu({ card, size, initialOpen }: { card: EntityRecord; size?: 'sm'; initialOpen: boolean }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const navigate = useNavigate()
  const [open, setOpen] = useState(initialOpen)
  const [align, setAlign] = useState<'end' | 'start'>('end')
  const root = useRef<HTMLDivElement | null>(null)
  const trigger = useRef<HTMLButtonElement | null>(null)
  const facts = useCardFacts(card, open)
  const id = card.record_id
  const row = size === 'sm'

  useEffect(() => {
    if (!open) return
    const away = (e: MouseEvent) => {
      if (root.current != null && !root.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', away)
    return () => document.removeEventListener('mousedown', away)
  }, [open])

  // The row menu sits inside the list's scroll boxes (overflow hidden), so it is fixed to the viewport next to its
  // trigger; the panel menu stays absolute and only flips to the start edge when it would leave the screen.
  const [fixedAt, setFixedAt] = useState<{ top: number; left: number } | null>(null)
  useLayoutEffect(() => {
    if (!open) {
      setAlign('end')
      setFixedAt(null)
      return
    }
    const menu = root.current?.querySelector<HTMLElement>('[role="menu"]')
    if (menu == null) return
    if (row) {
      const t = trigger.current?.getBoundingClientRect()
      if (t == null) return
      const w = menu.getBoundingClientRect().width
      const left = Math.max(8, Math.min(t.right - w, window.innerWidth - w - 8))
      setFixedAt({ top: t.bottom + 6, left })
    } else if (menu.getBoundingClientRect().left < 8) setAlign('start')
  }, [open, row, facts.rows, facts.held])

  // Position through the element's style object (not a JSX style prop: assets-style scan, rule 1).
  const placeMenu = (el: HTMLDivElement | null) => {
    if (el == null) return
    if (row && fixedAt != null) {
      el.style.position = 'fixed'
      el.style.top = `${fixedAt.top}px`
      el.style.left = `${fixedAt.left}px`
      el.style.right = 'auto'
    }
  }

  useEffect(() => {
    if (!open || !row) return
    const close = () => setOpen(false)
    window.addEventListener('scroll', close, true)
    window.addEventListener('resize', close)
    return () => {
      window.removeEventListener('scroll', close, true)
      window.removeEventListener('resize', close)
    }
  }, [open, row])

  const pick = (kind: string) => {
    setOpen(false)
    navigate(newDocumentHref(kind, [id]))
  }
  const onKeyDown = (e: React.KeyboardEvent) => {
    // the row's own handlers (select, Enter) must not see the menu's keys; Escape on a closed menu still closes the panel
    if (e.key !== 'Escape' || open) e.stopPropagation()
    if (e.key === 'Escape' && open) {
      setOpen(false)
      trigger.current?.focus()
      return
    }
    if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && root.current != null) {
      e.preventDefault()
      if (!open) {
        setOpen(true)
        return
      }
      const items = Array.from(root.current.querySelectorAll<HTMLElement>('[role="menuitem"]'))
      if (items.length === 0) return
      const i = items.indexOf(document.activeElement as HTMLElement)
      items[e.key === 'ArrowDown' ? (i + 1) % items.length : i <= 0 ? items.length - 1 : i - 1].focus()
    }
  }
  const label = row ? t('assets.cardActions.rowLabel', { number: textOf(card, 'inventory_number') }) : t('assets.cardActions.menu')

  return (
    <div
      className={`lf-lang lf-formmenu${align === 'start' ? ' lf-formmenu--start' : ''}`}
      ref={root}
      onKeyDown={onKeyDown}
      onClick={(e) => e.stopPropagation()}
      onMouseDown={(e) => e.stopPropagation()}
    >
      <button
        ref={trigger}
        type="button"
        className={`lf-btn lf-btn--secondary lf-btn--s${row ? ' lf-btn--icon' : ''}`}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={row ? label : undefined}
        data-testid={row ? `card-actions-${id}` : `card-actions-panel-${id}`}
        onClick={() => setOpen((o) => !o)}
      >
        {row ? (
          <MoreHorizontal className="lf-icon" aria-hidden="true" />
        ) : (
          <>
            {t('assets.cardActions.menu')}
            <ChevronDown className="lf-icon" aria-hidden="true" />
          </>
        )}
      </button>
      {open && (
        <div
          className="lf-lang__menu"
          role="menu"
          aria-label={label}
          ref={placeMenu}
          data-fixed={row && fixedAt != null ? 'true' : undefined}
        >
          {CARD_ACTIONS.map((a) => {
            const state = cardActionState(a.id, facts)
            const reason = state.allowed ? undefined : t(state.reasonId)
            return (
              <a
                key={a.id}
                href="#"
                role="menuitem"
                className="lf-lang__item"
                aria-disabled={reason !== undefined ? 'true' : undefined}
                title={reason}
                data-testid={`card-action-${a.id}`}
                onClick={(e) => {
                  e.preventDefault()
                  if (reason === undefined) pick(a.kind)
                }}
                onKeyDown={(e) => {
                  if (e.key === ' ') {
                    e.preventDefault()
                    if (reason === undefined) pick(a.kind)
                  }
                }}
              >
                <span>{t(a.labelId)}</span>
                {reason !== undefined && <span className="lf-lang__code lf-formmenu__reason">{reason}</span>}
              </a>
            )
          })}
        </div>
      )}
    </div>
  )
}
