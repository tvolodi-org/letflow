/** Harness fixtures of the users import screen (T-1633). Dev only, plain data.
 *  `users-import`: step 1; `-dryrun`: checked file with refused rows; `-ready`: clean check; `-done`: imported;
 *  `-notapplied`: atomic import rolled back; `-error`: a whole-file refusal. A small driver picks a file and presses
 *  the buttons, as a user would; the fixture answers by scenario. */
import { useEffect, type ReactElement } from 'react'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import UsersImportPage from '@/pages/admin/usersImport/UsersImportPage'
import { AUTH } from '../importFixtures'
import { holdHarnessReady } from '../fixtureFetch'
import type { FixtureRoute, HarnessScreen } from '../types'

const ACCESS: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['UsersGroupsRolesManage'] },
}

type Scenario = 'dryrun' | 'ready' | 'done' | 'notapplied' | 'error'

const ROWS_BAD = [
  { status: 'ok', line: 2, outcome: 'created' },
  { status: 'error', line: 3, reason: { type: 'user_field_required', header: 'email' } },
  { status: 'ok', line: 4, outcome: 'unchanged' },
  { status: 'error', line: 5, reason: { type: 'user_exists_different', header: 'username' } },
  { status: 'error', line: 6, reason: { type: 'user_duplicate_in_file', header: 'username' } },
  { status: 'error', line: 7, reason: { type: 'xlsx_cell_count' } },
]
const ROWS_OK = [
  { status: 'ok', line: 2, outcome: 'created' },
  { status: 'ok', line: 3, outcome: 'created' },
  { status: 'ok', line: 4, outcome: 'unchanged' },
]

function importRoute(scenario: Scenario): FixtureRoute {
  let calls = 0 // the first call is the check, the second (done / notapplied) the real import
  return {
    match: (path, method) => method === 'POST' && path.endsWith('/identity/users/import'),
    reply: () => {
      calls += 1
      if (scenario === 'error') {
        return {
          status: 422,
          body: { type: 'about:blank', title: 'Unprocessable', status: 422, detail: 'xlsx file is missing a required column', code: 'xlsx_missing_header', headers: ['email'] },
        }
      }
      if (scenario === 'dryrun') return { status: 200, body: { dry_run: true, results: ROWS_BAD } }
      if (scenario === 'ready' || calls === 1) return { status: 200, body: { dry_run: true, results: ROWS_OK } }
      if (scenario === 'notapplied') return { status: 200, body: { results: ROWS_BAD, applied: false } }
      return { status: 200, body: { results: ROWS_OK, applied: true } }
    },
  }
}

function Shell({ children }: { children: ReactElement }) {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <main className="lf-content">{children}</main>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

function click(testId: string) {
  document.querySelector<HTMLButtonElement>(`[data-testid="${testId}"]`)?.click()
}

/** Picks a small .xlsx, presses Check, and for done / notapplied then presses Import. */
function Driver({ scenario }: { scenario: Scenario }) {
  useEffect(() => {
    const final = { dryrun: 'users-import-dry-run', ready: 'users-import-dry-run', done: 'users-import-summary', notapplied: 'users-import-not-applied', error: 'users-import-error' }[scenario]
    const needsConfirm = scenario === 'done' || scenario === 'notapplied'
    const has = (id: string) => document.querySelector(`[data-testid="${id}"]`) !== null
    let tries = 0
    let picked = false
    let confirmed = false
    const release = holdHarnessReady()
    const timer = window.setInterval(() => {
      const input = document.querySelector<HTMLInputElement>('[data-testid="dropzone-input"]')
      if (has(final) && (!needsConfirm || confirmed)) {
        window.clearInterval(timer)
        release()
      } else if (input && !picked) {
        picked = true
        const dt = new DataTransfer()
        dt.items.add(new File([new Uint8Array(6144)], 'new_users.xlsx'))
        input.files = dt.files
        input.dispatchEvent(new Event('change', { bubbles: true }))
        window.setTimeout(() => click('users-import-check'), 50)
      } else if (needsConfirm && !confirmed && has('users-import-dry-run')) {
        confirmed = true
        window.setTimeout(() => click('users-import-confirm'), 50)
      } else if (++tries > 200) {
        window.clearInterval(timer)
        release()
      }
    }, 50)
    return () => {
      window.clearInterval(timer)
      release()
    }
  }, [scenario])
  return <UsersImportPage />
}

function screen(name: string, scenario: Scenario | null): HarnessScreen {
  return {
    name,
    routes: scenario ? [importRoute(scenario)] : [],
    render: () => <Shell>{scenario ? <Driver scenario={scenario} /> : <UsersImportPage />}</Shell>,
  }
}

export const usersImportScreens: HarnessScreen[] = [
  screen('users-import', null),
  screen('users-import-dryrun', 'dryrun'),
  screen('users-import-ready', 'ready'),
  screen('users-import-done', 'done'),
  screen('users-import-notapplied', 'notapplied'),
  screen('users-import-error', 'error'),
]
