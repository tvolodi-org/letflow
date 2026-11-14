/** Harness fixtures of the "Install on your phone" entry of the main screen (T-1962, O-003): the open how-to (not
 *  read yet) and the one-line entry (already read; the flag is seeded before the first render). */
import { TopBar } from '@/components/ui/TopBar'
import { InstallHint } from '@/components/layout/InstallHint'
import type { HarnessScreen } from '../types'

const KEY = 'harness-user'

function hintScreen(name: string, read: boolean): HarnessScreen {
  function Screen() {
    // seeded during render on purpose: InstallHint reads the flag in its initial state
    if (read) window.localStorage.setItem('letflow.installHintRead.' + KEY, '1')
    else window.localStorage.removeItem('letflow.installHintRead.' + KEY)
    return (
      <div className="lf-main">
        <TopBar />
        <main className="lf-content">
          <h1>Demo company</h1>
          <p>Here is a summary of your current activity.</p>
          <div className="lf-install-hint">
            <InstallHint userKey={KEY} />
          </div>
        </main>
      </div>
    )
  }
  return { name, routes: [], render: () => <Screen /> }
}

export const installHintScreens: HarnessScreen[] = [hintScreen('install-hint-open', false), hintScreen('install-hint-entry', true)]
