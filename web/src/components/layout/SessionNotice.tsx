/** SessionNotice (T-1400): after a REAL session expiry (refresh refused, or a replayed request still 401)
 *  AuthProvider leaves a one-shot flag in sessionStorage and redirects to sign-in. The next page shows this
 *  banner once, so the user knows why they were signed in again. The flag is a constant, never a token. */
import { useEffect, useState } from 'react'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import type { UiLocale } from '@/i18n/uiLocaleStore'

export const SESSION_NOTICE_KEY = 'bpm_session_notice'

const MESSAGES: Record<UiLocale, { text: string; dismiss: string }> = {
  en: { text: 'Your session expired and you were signed in again.', dismiss: 'Dismiss' },
  ru: { text: 'Сессия истекла, вход выполнен заново.', dismiss: 'Закрыть' },
  kk: { text: 'Сессия мерзімі аяқталды, жүйеге қайта кірдіңіз.', dismiss: 'Жабу' },
}

// Read in the state initializer, removed in an effect: a StrictMode double render must not
// consume the flag before the visible render.
function flagSet(): boolean {
  try {
    return sessionStorage.getItem(SESSION_NOTICE_KEY) === 'expired'
  } catch {
    return false
  }
}

export function SessionNotice() {
  const locale = useUiLocale()
  const [visible, setVisible] = useState(flagSet)
  useEffect(() => {
    try {
      sessionStorage.removeItem(SESSION_NOTICE_KEY)
    } catch {
      /* ignore */
    }
  }, [])
  if (!visible) return null
  const m = MESSAGES[locale]
  return (
    <div data-testid="session-notice">
      <Banner
        tone="warning"
        action={
          <Button variant="ghost" size="sm" onClick={() => setVisible(false)} data-testid="session-notice-dismiss">
            {m.dismiss}
          </Button>
        }
      >
        {m.text}
      </Banner>
    </div>
  )
}
