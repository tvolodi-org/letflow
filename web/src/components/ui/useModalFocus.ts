/** useModalFocus — the focus rules of a modal dialog for dialogs that are not `Dialog`.
 *
 *  Same behaviour as `Dialog.tsx` (the reference, not refactored onto this hook): on open the first focusable
 *  element inside the container gets focus (else the container itself, give it `tabIndex={-1}`); Tab and
 *  Shift+Tab wrap inside the container and pull focus back in when it is outside; Escape calls `onClose`
 *  unless `busy`; on close or unmount focus returns to the opener when it is still in the document.
 *  Pass `open` for a dialog whose container is rendered conditionally; the ref is read when `open` turns true.
 */
import { useEffect, useRef, type RefObject } from 'react'

// Copied from Dialog.tsx (same selector, kept in step by hand).
const FOCUSABLE = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

export interface ModalFocusOptions {
  open?: boolean
  onClose?: () => void
  busy?: boolean
}

export function useModalFocus(ref: RefObject<HTMLElement | null>, opts: ModalFocusOptions = {}): void {
  const { open = true } = opts
  const latest = useRef(opts)
  latest.current = opts

  useEffect(() => {
    if (!open) return
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const box = ref.current
    if (box) {
      const first = box.querySelector<HTMLElement>(FOCUSABLE)
      ;(first ?? box).focus()
    }
    return () => {
      if (opener && opener.isConnected) opener.focus()
    }
  }, [open, ref])

  useEffect(() => {
    if (!open) return
    const handler = (e: KeyboardEvent): void => {
      const box = ref.current
      if (!box) return
      if (e.key === 'Escape') {
        // Only the innermost dialog reacts: an outer one ignores an Escape that started outside it.
        if (!box.contains(document.activeElement) && document.querySelectorAll('[role="dialog"][aria-modal="true"]').length > 1) return
        e.stopPropagation()
        if (!latest.current.busy) latest.current.onClose?.()
        return
      }
      if (e.key !== 'Tab') return
      const active = document.activeElement
      if (!box.contains(active) && document.querySelectorAll('[role="dialog"][aria-modal="true"]').length > 1) {
        // Focus is in a different (inner) dialog: not ours to trap.
        const other = Array.from(document.querySelectorAll('[role="dialog"][aria-modal="true"]')).find((n) => n !== box && n.contains(active))
        if (other && !other.contains(box)) return
      }
      const nodes = Array.from(box.querySelectorAll<HTMLElement>(FOCUSABLE))
      if (nodes.length === 0) {
        e.preventDefault()
        box.focus()
        return
      }
      const first = nodes[0]
      const last = nodes[nodes.length - 1]
      if (!box.contains(active)) {
        e.preventDefault()
        first.focus()
      } else if (e.shiftKey && (active === first || active === box)) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && active === last) {
        e.preventDefault()
        first.focus()
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [open, ref])
}
