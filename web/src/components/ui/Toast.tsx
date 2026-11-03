/** Toast — design-system primitive (NOTES.md section 2, REQ-275 store).
 *
 *  ToastContainer subscribes to the useToast.ts module-level store and renders the entries
 *  newest first, at most 4 (enforced by the store). success/info/warning close after 4 s,
 *  an error stays until it is dismissed. Errors announce assertively (role="alert"), the
 *  others politely. Appearance: .lf-toasts / .lf-toast from components.css (tokens only).
 *  The warning variant has no toast class in the design system: it uses the info tone
 *  with the alert glyph (nearest rule).
 */

import React, { useSyncExternalStore } from 'react'
import { AlertTriangle, CheckCircle2, Info, OctagonAlert, X } from 'lucide-react'
import {
  dismissToast,
  getToastSnapshot,
  subscribeToasts,
  type ToastEntry,
  type ToastVariant,
} from '../../hooks/useToast'
import { useUiMessages } from './uiMessages'

const TONE: Record<ToastVariant, 'success' | 'info' | 'danger'> = {
  success: 'success',
  info: 'info',
  warning: 'info',
  error: 'danger',
}

const ICON = { success: CheckCircle2, info: Info, warning: AlertTriangle, error: OctagonAlert } as const

function ToastItem({ entry }: { entry: ToastEntry }): React.ReactElement {
  const t = useUiMessages()
  const Icon = ICON[entry.variant]
  return (
    <div
      data-testid="toast-item"
      data-variant={entry.variant}
      className={`lf-toast lf-toast--${TONE[entry.variant]}`}
      role={entry.variant === 'error' ? 'alert' : 'status'}
      aria-live={entry.variant === 'error' ? 'assertive' : 'polite'}
    >
      <Icon className="lf-icon" aria-hidden="true" />
      <div>
        <p data-testid="toast-message" className="lf-toast__title">
          {entry.message}
        </p>
        {entry.description && (
          <p data-testid="toast-description" className="lf-toast__body">
            {entry.description}
          </p>
        )}
      </div>
      <button
        data-testid="toast-close"
        type="button"
        className="lf-btn lf-btn--ghost lf-btn--icon"
        aria-label={t.dismiss}
        onClick={() => dismissToast(entry.id)}
      >
        <X className="lf-icon" aria-hidden="true" />
      </button>
    </div>
  )
}

export function ToastContainer(): React.ReactElement | null {
  const entries = useSyncExternalStore(subscribeToasts, getToastSnapshot)

  if (entries.length === 0) {
    return null
  }

  return (
    <div data-testid="toast-container" className="lf-toasts">
      {entries.map((entry) => (
        <ToastItem key={entry.id} entry={entry} />
      ))}
    </div>
  )
}
