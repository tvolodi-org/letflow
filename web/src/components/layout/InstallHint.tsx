/** InstallHint — the "Install on your phone" entry of the main screen (owner finding O-003, checklist item 19).
 *  Until the user presses "I have read it" the short how-to (iPhone and Android) is open; afterwards only a
 *  one-line button stays, and pressing it opens the how-to again. The "read" flag is kept per user in
 *  localStorage (`userKey`); a storage failure (private mode) only means it is remembered for this visit. */
import { useState } from 'react'
import { Smartphone } from 'lucide-react'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { installHintMessages } from './installHintMessages'

const STORAGE_PREFIX = 'letflow.installHintRead.'

export function loadInstallHintRead(userKey: string): boolean {
  try {
    return window.localStorage.getItem(STORAGE_PREFIX + userKey) === '1'
  } catch {
    return false
  }
}

export function saveInstallHintRead(userKey: string): void {
  try {
    window.localStorage.setItem(STORAGE_PREFIX + userKey, '1')
  } catch {
    // storage unavailable: the choice lasts for this visit only
  }
}

export function InstallHint({ userKey }: { userKey: string }): JSX.Element {
  const t = installHintMessages[useUiLocale()]
  const [read, setRead] = useState(() => loadInstallHintRead(userKey))
  const [reopened, setReopened] = useState(false)

  if (read && !reopened) {
    return (
      <div data-testid="install-hint-entry">
        <Button variant="ghost" size="sm" icon={<Smartphone className="lf-icon" />} onClick={() => setReopened(true)} data-testid="install-hint-open">
          {t.title}
        </Button>
      </div>
    )
  }

  const markRead = () => {
    saveInstallHintRead(userKey)
    setRead(true)
    setReopened(false)
  }

  return (
    <div data-testid="install-hint">
      <Banner
        tone="info"
        title={t.title}
        action={
          <Button variant="secondary" size="sm" onClick={markRead} data-testid="install-hint-read">
            {t.read}
          </Button>
        }
      >
        <p>{t.intro}</p>
        <strong>{t.iphoneTitle}</strong>
        <ol>
          {t.iphoneSteps.map((s) => (
            <li key={s}>{s}</li>
          ))}
        </ol>
        <strong>{t.androidTitle}</strong>
        <ol>
          {t.androidSteps.map((s) => (
            <li key={s}>{s}</li>
          ))}
        </ol>
      </Banner>
    </div>
  )
}
