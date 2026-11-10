import { useRef } from 'react'
import type { CSSProperties } from 'react'
import { useModalFocus } from '@/components/ui/useModalFocus'
import { fillEmail, type PasswordResetMessages } from '@/pages/admin/passwordResetMessages'

type Props = {
  open: boolean
  email: string
  isSubmitting: boolean
  messages: PasswordResetMessages
  onCancel: () => void
  onConfirm: () => void
}

export function PasswordResetDialog({ open, email, isSubmitting, messages, onCancel, onConfirm }: Props) {
  const boxRef = useRef<HTMLDivElement | null>(null)
  useModalFocus(boxRef, { open, onClose: onCancel, busy: isSubmitting })
  if (!open) return null

  return (
    <div ref={boxRef} tabIndex={-1} style={overlayStyle} role="dialog" aria-modal="true" aria-label={messages.confirmTitle}>
      <div style={dialogStyle}>
        <h3 style={{ marginTop: 0 }}>{messages.confirmTitle}</h3>
        <p data-testid="password-reset-dialog-body">{fillEmail(messages.confirmBody, email)}</p>
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button type="button" onClick={onCancel}>{messages.cancel}</button>
          <button type="button" onClick={onConfirm} disabled={isSubmitting}>
            {isSubmitting ? messages.sending : messages.confirm}
          </button>
        </div>
      </div>
    </div>
  )
}

const overlayStyle: CSSProperties = {
  position: 'fixed',
  inset: 0,
  backgroundColor: 'var(--surface-overlay-slate)',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  zIndex: 30,
}

const dialogStyle: CSSProperties = {
  backgroundColor: 'var(--surface-card)',
  width: 'min(560px, calc(100vw - 2rem))',
  borderRadius: 8,
  padding: 20,
}
