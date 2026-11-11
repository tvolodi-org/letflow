import { useState, type ReactNode } from 'react'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import type { SignInMessages } from '@/pages/admin/signInMessages'

type Props = {
  username: string
  password: string
  messages: SignInMessages
  onClose: () => void
  extraAction?: ReactNode
}

/** One-time temporary password (REQ-809). Pure view: the password lives in the parent's state only and leaves the
 *  DOM when the parent clears it on Close. */
export function TemporaryPasswordPanel({ username, password, messages, onClose, extraAction }: Props) {
  const [copied, setCopied] = useState(false)
  return (
    <div data-testid="sign-in-panel">
      <Banner tone="success" title={messages.panelTitle}>
        <div style={{ display: 'grid', gap: 'var(--space-2)', marginTop: 'var(--space-2)' }}>
          <div>
            {messages.usernameLabel}: <code data-testid="sign-in-username">{username}</code>
          </div>
          <div>
            {messages.passwordLabel}: <code data-testid="sign-in-password">{password}</code>
          </div>
          <div>{messages.onceNote}</div>
          <div style={{ display: 'flex', gap: 'var(--space-2)', flexWrap: 'wrap' }}>
            <span data-testid="sign-in-copy">
              <Button
                variant="secondary"
                size="sm"
                type="button"
                onClick={() => {
                  // A missing or refused clipboard leaves the text visible and selectable.
                  void Promise.resolve()
                    .then(() => navigator.clipboard.writeText(password))
                    .then(() => setCopied(true))
                    .catch(() => undefined)
                }}
              >
                {copied ? messages.copied : messages.copy}
              </Button>
            </span>
            {extraAction}
            <span data-testid="sign-in-close">
              <Button variant="secondary" size="sm" type="button" onClick={onClose}>{messages.close}</Button>
            </span>
          </div>
        </div>
      </Banner>
    </div>
  )
}
