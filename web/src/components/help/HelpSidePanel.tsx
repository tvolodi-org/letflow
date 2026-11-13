/** HelpSidePanel — T-1872. The Help of a screen as a side panel in the same React tree: opening it never navigates,
 *  so the working form behind it is not remounted and keeps what the user typed. Same container pattern as
 *  `HelpPanel` (portal, overlay, `role="dialog"`); the role matters: the screens' own Escape handlers skip while a
 *  dialog is in the DOM. Full width at phone size, with a Close button that is always visible. */
import type { ReactNode } from 'react'
import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { useModalFocus } from '@/components/ui/useModalFocus'

export interface HelpSidePanelProps {
  title: string
  closeLabel: string
  onClose: () => void
  children: ReactNode
}

export function HelpSidePanel({ title, closeLabel, onClose, children }: HelpSidePanelProps) {
  const boxRef = useRef<HTMLDivElement | null>(null)
  const closeRef = useRef<HTMLButtonElement | null>(null)
  useModalFocus(boxRef, { onClose })
  useEffect(() => {
    closeRef.current?.focus()
  }, [])

  return createPortal(
    <div
      ref={boxRef}
      tabIndex={-1}
      role="dialog"
      aria-modal="true"
      aria-labelledby="help-side-title"
      data-testid="help-side-overlay"
      style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay)', zIndex: 'var(--z-dialog)' as unknown as number, display: 'flex', justifyContent: 'flex-end' }}
      onClick={onClose}
    >
      <div
        data-testid="help-side-panel"
        onClick={(e) => e.stopPropagation()}
        style={{ background: 'var(--surface-card)', width: 'min(420px, 100vw)', height: '100%', overflowY: 'auto', boxShadow: 'var(--shadow-modal-lg)' }}
      >
        <div
          style={{
            position: 'sticky',
            top: 0,
            zIndex: 1,
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            gap: 'var(--space-3)',
            padding: 'var(--space-4) var(--space-6)',
            background: 'var(--surface-card)',
          }}
        >
          <h2 id="help-side-title" data-testid="help-side-title" style={{ margin: 0, color: 'var(--text-primary)' }}>
            {title}
          </h2>
          <button ref={closeRef} type="button" className="lf-btn lf-btn--ghost" data-testid="help-side-close" onClick={onClose}>
            {closeLabel}
          </button>
        </div>
        <div style={{ padding: '0 var(--space-6) var(--space-6)' }}>{children}</div>
      </div>
    </div>,
    document.body,
  )
}
