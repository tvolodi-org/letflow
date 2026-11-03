/** Dialog — modal with title, subtitle, body, confirm/cancel footer (NOTES.md section 2).
 *
 *  Focus: on open the confirm button gets focus (Enter confirms, as ConfirmDialog always did);
 *  Tab / Shift+Tab cycle inside the dialog; Escape cancels (not while loading); on close focus
 *  returns to the element that had it before. `error` renders a danger banner inside the body,
 *  `isLoading` disables both buttons and shows the spinner on confirm.
 */
import React, { useEffect, useId, useRef, type ReactNode } from 'react'
import { X } from 'lucide-react'
import { Banner } from './Banner'
import { useUiMessages } from './uiMessages'

export interface DialogProps {
  open: boolean
  title: string
  subtitle?: string
  children?: ReactNode
  confirmText?: string
  cancelText?: string
  confirmVariant?: 'primary' | 'danger'
  onConfirm: () => void
  onCancel: () => void
  isLoading?: boolean
  size?: 'm' | 'l'
  /** Write error shown inside the body. */
  error?: string | null
  /** Disables the confirm button without a loading state (invalid form). */
  confirmDisabled?: boolean
  testId?: string
}

const FOCUSABLE = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

export function Dialog(props: DialogProps): React.ReactElement | null {
  const t = useUiMessages()
  const {
    open,
    title,
    subtitle,
    children,
    confirmText = t.confirm,
    cancelText = t.cancel,
    confirmVariant = 'primary',
    onConfirm,
    onCancel,
    isLoading = false,
    size = 'm',
    error,
    confirmDisabled = false,
    testId = 'dialog',
  } = props

  const titleId = useId()
  const dialogRef = useRef<HTMLDivElement | null>(null)
  const confirmRef = useRef<HTMLButtonElement | null>(null)
  const loadingRef = useRef(isLoading)
  loadingRef.current = isLoading

  // Focus in on open, back to the opener on close.
  useEffect(() => {
    if (!open) return
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
    confirmRef.current?.focus()
    return () => {
      opener?.focus()
    }
  }, [open])

  useEffect(() => {
    if (!open) return
    const handler = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        if (!loadingRef.current) onCancel()
        return
      }
      if (e.key !== 'Tab' || dialogRef.current == null) return
      const nodes = Array.from(dialogRef.current.querySelectorAll<HTMLElement>(FOCUSABLE))
      if (nodes.length === 0) return
      const first = nodes[0]
      const last = nodes[nodes.length - 1]
      const active = document.activeElement
      if (!dialogRef.current.contains(active)) {
        e.preventDefault()
        first.focus()
      } else if (e.shiftKey && active === first) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && active === last) {
        e.preventDefault()
        first.focus()
      }
    }
    window.addEventListener('keydown', handler)
    return () => {
      window.removeEventListener('keydown', handler)
    }
  }, [open, onCancel])

  if (!open) return null

  return (
    <div className="lf-scrim" data-testid={`${testId}-scrim`}>
      <div
        ref={dialogRef}
        className={size === 'l' ? 'lf-dialog lf-dialog--l' : 'lf-dialog'}
        data-testid={testId}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-busy={isLoading || undefined}
      >
        <div className="lf-dialog__head">
          <div>
            <h3 className="lf-dialog__title" id={titleId}>
              {title}
            </h3>
            {subtitle != null && <p className="lf-dialog__sub">{subtitle}</p>}
          </div>
          <button
            type="button"
            className="lf-btn lf-btn--ghost lf-btn--icon"
            data-testid={`${testId}-close`}
            aria-label={t.close}
            disabled={isLoading}
            onClick={onCancel}
          >
            <X className="lf-icon" aria-hidden="true" />
          </button>
        </div>
        <div className="lf-dialog__body">
          {error != null && error !== '' && (
            <div data-testid={`${testId}-error`}>
              <Banner tone="danger">{error}</Banner>
            </div>
          )}
          {children}
        </div>
        <div className="lf-dialog__foot">
          <button
            data-testid={`${testId}-cancel`}
            type="button"
            className="lf-btn lf-btn--ghost"
            onClick={onCancel}
            disabled={isLoading}
          >
            {cancelText}
          </button>
          <button
            ref={confirmRef}
            data-testid={`${testId}-confirm`}
            type="button"
            className={`lf-btn ${confirmVariant === 'danger' ? 'lf-btn--danger' : 'lf-btn--primary'}${isLoading ? ' is-loading' : ''}`}
            onClick={onConfirm}
            disabled={isLoading || confirmDisabled}
          >
            {confirmText}
          </button>
        </div>
      </div>
    </div>
  )
}
