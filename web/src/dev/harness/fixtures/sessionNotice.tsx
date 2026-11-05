/** Harness fixture of the "session expired" notice (T-1400). The flag is set before the banner mounts. */
import { SESSION_NOTICE_KEY, SessionNotice } from '@/components/layout/SessionNotice'
import type { HarnessScreen } from '../types'

function Flagged() {
  sessionStorage.setItem(SESSION_NOTICE_KEY, 'expired')
  return (
    <SessionNotice />
  )
}

export const sessionNoticeScreens: HarnessScreen[] = [
  { name: 'session-notice', routes: [], render: () => <Flagged /> },
]
