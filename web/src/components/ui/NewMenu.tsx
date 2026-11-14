/** NewMenu — T-1953. The one "New" menu of a screen with three or more creation kinds (docs/design-system/
 *  page-header-actions.md R3), placed in the page header's actions. Built like the other in-product menus
 *  (`lf-lang lf-formmenu`): a primary trigger with `aria-haspopup="menu"` and `aria-expanded`; a `role="menu"` list named
 *  by the trigger label; `role="menuitem"` links. Keys (R5): ArrowDown/ArrowUp on the closed trigger open it and focus the
 *  first/last item; arrows move with wrap, Home/End jump; Enter/Space choose; Escape closes and returns focus to the
 *  trigger; Tab and a mousedown outside close. A disabled item keeps its reason as visible text and chooses nothing.
 *  The caller passes its own label and item labels (en/ru/kk from its catalog); the component has no text of its own. */
import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { ChevronDown, Plus } from 'lucide-react'

export interface NewMenuItem {
  id: string
  label: string
  onSelect: () => void
  disabled?: boolean
  /** Visible text for a disabled item. */
  reason?: string
}

export interface NewMenuProps {
  /** Trigger text and the menu's accessible name. */
  label: string
  /** In display order. */
  items: NewMenuItem[]
  /** Trigger test id (default `new-menu`); items get `${testid}-${id}`, the menu `${testid}-menu`. */
  'data-testid'?: string
  /** Opens at once (harness screenshots and tests). */
  initialOpen?: boolean
}

export function NewMenu({ label, items, 'data-testid': testid = 'new-menu', initialOpen = false }: NewMenuProps) {
  const [open, setOpen] = useState(initialOpen)
  const [align, setAlign] = useState<'end' | 'start'>('end')
  const root = useRef<HTMLDivElement | null>(null)
  const trigger = useRef<HTMLButtonElement | null>(null)
  const menuId = useId()

  useEffect(() => {
    if (!open) return
    const away = (e: MouseEvent) => {
      if (root.current != null && !root.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', away)
    return () => document.removeEventListener('mousedown', away)
  }, [open])

  useLayoutEffect(() => {
    if (!open) {
      setAlign('end')
      return
    }
    const menu = root.current?.querySelector<HTMLElement>('[role="menu"]')
    if (menu != null && menu.getBoundingClientRect().left < 8) setAlign('start')
  }, [open])

  const itemEls = () => (root.current == null ? [] : Array.from(root.current.querySelectorAll<HTMLElement>('[role="menuitem"]')))
  const focusItem = (i: number) => {
    const els = itemEls()
    if (els.length > 0) els[(i + els.length) % els.length].focus()
  }
  // After the menu has rendered, focus the first or last item.
  const [pendingFocus, setPendingFocus] = useState<'first' | 'last' | null>(null)
  useEffect(() => {
    if (!open || pendingFocus == null) return
    const els = root.current == null ? [] : Array.from(root.current.querySelectorAll<HTMLElement>('[role="menuitem"]'))
    if (els.length > 0) els[pendingFocus === 'first' ? 0 : els.length - 1].focus()
    setPendingFocus(null)
  }, [open, pendingFocus])

  const choose = (item: NewMenuItem) => {
    if (item.disabled) return
    setOpen(false)
    item.onSelect()
  }
  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape' && open) {
      e.preventDefault()
      e.stopPropagation()
      setOpen(false)
      trigger.current?.focus()
      return
    }
    if (e.key === 'Tab') {
      if (open) setOpen(false)
      return
    }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      if (!open) {
        setOpen(true)
        setPendingFocus(e.key === 'ArrowDown' ? 'first' : 'last')
        return
      }
      const els = itemEls()
      const i = els.indexOf(document.activeElement as HTMLElement)
      focusItem(e.key === 'ArrowDown' ? (i < 0 ? 0 : i + 1) : i <= 0 ? -1 : i - 1)
      return
    }
    if (open && (e.key === 'Home' || e.key === 'End')) {
      e.preventDefault()
      focusItem(e.key === 'Home' ? 0 : -1)
    }
  }

  return (
    <div className={`lf-lang lf-formmenu lf-newmenu${align === 'start' ? ' lf-formmenu--start' : ''}`} ref={root} onKeyDown={onKeyDown}>
      <button
        ref={trigger}
        type="button"
        className="lf-btn lf-btn--primary"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        data-testid={testid}
        onClick={() => setOpen((o) => !o)}
      >
        <Plus className="lf-icon" aria-hidden="true" />
        {label}
        <ChevronDown className="lf-icon" aria-hidden="true" />
      </button>
      {open && (
        <div className="lf-lang__menu" role="menu" id={menuId} aria-label={label} data-testid={`${testid}-menu`}>
          {items.map((item) => (
            <a
              key={item.id}
              href="#"
              role="menuitem"
              className="lf-lang__item"
              aria-disabled={item.disabled ? 'true' : undefined}
              data-testid={`${testid}-${item.id}`}
              onClick={(e) => {
                e.preventDefault()
                choose(item)
              }}
              onKeyDown={(e) => {
                if (e.key === ' ' || e.key === 'Enter') {
                  e.preventDefault()
                  e.stopPropagation()
                  choose(item)
                }
              }}
            >
              <span>{item.label}</span>
              {item.disabled && item.reason != null && <span className="lf-lang__code lf-formmenu__reason">{item.reason}</span>}
            </a>
          ))}
        </div>
      )}
    </div>
  )
}
