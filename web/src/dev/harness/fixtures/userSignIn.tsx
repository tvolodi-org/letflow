/** Harness fixtures of "Create sign-in" (T-1732, REQ-809). Dev only, plain data.
 *  `user-signin`: internal user, action visible; `-panel`: pressed, 201 with a one-time password;
 *  `-refused`: pressed, 409 no_email; `users-new-signin`: the new-user form with the checkbox;
 *  `users-import-signin`: a done import whose rows carry sign_in (REQ-808 answer shape). */
import { useEffect } from 'react'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import UserDetailPage from '@/pages/admin/UserDetailPage'
import UsersPage from '@/pages/admin/UsersPage'
import UsersImportPage from '@/pages/admin/usersImport/UsersImportPage'
import { AUTH } from '../importFixtures'
import { holdHarnessReady } from '../fixtureFetch'
import type { FixtureRoute, HarnessScreen } from '../types'

const ACCESS: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['UsersGroupsRolesManage'] },
}

const USER = {
  id: 'u1', username: 'ann.sadykova', display_name: 'Ann Sadykova', email: 'ann@example.test',
  status: 'active', auth_source: 'internal', inserted_at: '2026-11-01T09:00:00Z', updated_at: '2026-11-01T09:00:00Z',
  role_ids: [], group_ids: [], roles: [],
}

type Sign = 'ok' | 'refused'

function userRoutes(sign: Sign): FixtureRoute[] {
  return [
    { match: (p, m) => m === 'POST' && p.endsWith('/sign-in'),
      reply: () => (sign === 'ok'
        ? { status: 201, body: { user: { ...USER, auth_source: 'oidc' }, temporary_password: 'Kd7-Rq2m-Vw9x' } }
        : { status: 409, body: { title: 'Conflict', detail: 'no_email' } }) },
    { match: (p, m) => m === 'GET' && p.endsWith('/identity/users/u1'), reply: () => ({ status: 200, body: USER }) },
    { match: (p, m) => m === 'GET' && p.endsWith('/identity/users'), reply: () => ({ status: 200, body: { items: [USER] } }) },
    { match: (p, m) => m === 'GET' && p.endsWith('/identity/roles'), reply: () => ({ status: 200, body: { items: [] } }) },
    { match: (p, m) => m === 'GET' && p.endsWith('/identity/groups'), reply: () => ({ status: 200, body: { items: [] } }) },
  ]
}

function Shell({ children }: { children: React.ReactElement }) {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <main className="lf-content">{children}</main>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

function press(selector: string): boolean {
  const el = document.querySelector<HTMLElement>(selector)
  el?.click()
  return el !== null
}

/** Presses the first matching element once it exists, then releases the harness. */
function useAutoPress(selector: string, until: string) {
  useEffect(() => {
    const release = holdHarnessReady()
    let tries = 0
    let pressed = false
    const timer = window.setInterval(() => {
      if (!pressed) pressed = press(selector)
      else if (document.querySelector(until) || ++tries > 200) {
        window.clearInterval(timer)
        release()
      }
      if (++tries > 400) {
        window.clearInterval(timer)
        release()
      }
    }, 50)
    return () => {
      window.clearInterval(timer)
      release()
    }
  }, [selector, until])
}

function UserDriver() {
  useAutoPress('[data-testid="admin-user-create-sign-in"] button', '[data-testid="sign-in-panel"], [data-testid="admin-user-sign-in-live"] [role="alert"]')
  return <UserDetailPage />
}

function NewUserDriver() {
  useAutoPress('[data-testid="admin-users-new"] button', '[data-testid="admin-users-create-sign-in"]')
  return <UsersPage />
}

const IMPORT_ROWS = [
  { status: 'ok', line: 2, outcome: 'created', sign_in: { created: true, temporary_password: 'Kd7-Rq2m-Vw9x' } },
  { status: 'ok', line: 3, outcome: 'created', sign_in: { created: false, reason: 'no_email' } },
  { status: 'ok', line: 4, outcome: 'unchanged' },
]

function ImportDriver() {
  useEffect(() => {
    const release = holdHarnessReady()
    let tries = 0
    let picked = false
    let confirmed = false
    const timer = window.setInterval(() => {
      const input = document.querySelector<HTMLInputElement>('[data-testid="dropzone-input"]')
      if (document.querySelector('[data-testid="users-import-summary"]')) {
        window.clearInterval(timer)
        release()
      } else if (input && !picked) {
        picked = true
        const dt = new DataTransfer()
        dt.items.add(new File([new Uint8Array(6144)], 'new_users.xlsx'))
        input.files = dt.files
        input.dispatchEvent(new Event('change', { bubbles: true }))
        window.setTimeout(() => press('[data-testid="users-import-check"]'), 50)
      } else if (!confirmed && document.querySelector('[data-testid="users-import-dry-run"]')) {
        confirmed = true
        window.setTimeout(() => press('[data-testid="users-import-confirm"]'), 50)
      } else if (++tries > 200) {
        window.clearInterval(timer)
        release()
      }
    }, 50)
    return () => {
      window.clearInterval(timer)
      release()
    }
  }, [])
  return <UsersImportPage />
}

function importRoute(): FixtureRoute {
  let calls = 0
  return {
    match: (p, m) => m === 'POST' && p.endsWith('/identity/users/import'),
    reply: () => {
      calls += 1
      return calls === 1
        ? { status: 200, body: { dry_run: true, results: IMPORT_ROWS.map((r) => ({ status: r.status, line: r.line, outcome: r.outcome })) } }
        : { status: 200, body: { results: IMPORT_ROWS, applied: true } }
    },
  }
}

function userScreen(name: string, sign: Sign, drive: boolean): HarnessScreen {
  return {
    name,
    initialPath: '/u1',
    routePattern: '/:userId',
    routes: userRoutes(sign),
    render: () => <Shell>{drive ? <UserDriver /> : <UserDetailPage />}</Shell>,
  }
}

export const userSignInScreens: HarnessScreen[] = [
  userScreen('user-signin', 'ok', false),
  userScreen('user-signin-panel', 'ok', true),
  userScreen('user-signin-refused', 'refused', true),
  { name: 'users-new-signin', routes: userRoutes('ok'), render: () => <Shell><NewUserDriver /></Shell> },
  { name: 'users-import-signin', routes: [importRoute()], render: () => <Shell><ImportDriver /></Shell> },
]
