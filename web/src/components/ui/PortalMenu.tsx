/** PortalMenu — T-2020 (owner checklist 28). The popup of a disclosure menu, rendered into `document.body` so that no
 *  panel, divider or `overflow` box of the screen can clip it. It is placed with `position: fixed` under its trigger,
 *  right-aligned to the trigger (start-aligned when that would leave the window on the left), kept inside the window,
 *  and follows the trigger on resize and scroll. The menu semantics (role=menu, items, keys) stay with the caller. */
import { useLayoutEffect, useState, type ReactNode, type RefObject } from 'react'
import { createPortal } from 'react-dom'

export interface PortalMenuProps {
  /** The trigger button the menu hangs under. */
  anchor: RefObject<HTMLElement | null>
  /** Ref of the menu box itself (the caller needs it for arrow keys and outside-click tests). */
  menuRef: RefObject<HTMLDivElement | null>
  label: string
  children: ReactNode
}

const GAP = 6
const EDGE = 8

export function PortalMenu({ anchor, menuRef, label, children }: PortalMenuProps) {
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null)

  useLayoutEffect(() => {
    const place = () => {
      const a = anchor.current
      const m = menuRef.current
      if (a == null || m == null) return
      const r = a.getBoundingClientRect()
      const w = m.getBoundingClientRect().width
      let left = r.right - w
      if (left < EDGE) left = r.left
      left = Math.max(EDGE, Math.min(left, window.innerWidth - w - EDGE))
      setPos({ top: r.bottom + GAP, left })
    }
    place()
    window.addEventListener('resize', place)
    window.addEventListener('scroll', place, true)
    return () => {
      window.removeEventListener('resize', place)
      window.removeEventListener('scroll', place, true)
    }
  }, [anchor, menuRef])

  return createPortal(
    <div
      className="lf-formmenu lf-formmenu--pop"
      data-testid="portal-menu"
      style={{ top: pos?.top ?? 0, left: pos?.left ?? 0, visibility: pos === null ? 'hidden' : 'visible' }}
    >
      <div className="lf-lang__menu" role="menu" aria-label={label} ref={menuRef}>
        {children}
      </div>
    </div>,
    document.body,
  )
}
