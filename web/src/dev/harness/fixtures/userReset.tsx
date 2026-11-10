/** Harness fixtures of the user page reset button (T-1657, REQ-789). Dev only, plain data.
 *  `user-reset`: active oidc user with e-mail (button); `-dialog`, `-sent`, `-error`: the button pressed;
 *  `-inactive`, `-nologin`, `-noemail`: the three hints. */
import { useEffect } from 'react'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import UserDetailPage from '@/pages/admin/UserDetailPage'
import { AUTH } from '../importFixtures'
import { holdHarnessReady } from '../fixtureFetch'
import type { FixtureRoute, HarnessScreen } from '../types'

const ACCESS: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['UsersGroupsRolesManage'] },
}

const BASE = {
  id: 'u1', username: 'ann.sadykova', display_name: 'Ann Sadykova', email: 'ann@example.test',
  status: 'active', auth_source: 'oidc', inserted_at: '2026-11-01T09:00:00Z', updated_at: '2026-11-01T09:00:00Z',
  role_ids: [], group_ids: [],
}

type Send = 'none' | 'ok' | 'error'

function routes(user: Record<string, unknown>, send: Send): FixtureRoute[] {
  return [
    { match: (p, m) => m === 'POST' && p.endsWith('/reset-password'),
      reply: () => (send === 'ok' ? { status: 202, body: { status: 'requested' } } : { status: 500, body: { title: 'Server error' } }) },
    { match: (p, m) => m === 'GET' && p.endsWith('/identity/users/u1'), reply: () => ({ status: 200, body: user }) },
    { match: (p, m) => m === 'GET' && p.endsWith('/identity/roles'), reply: () => ({ status: 200, body: { items: [] } }) },
    { match: (p, m) => m === 'GET' && p.endsWith('/identity/groups'), reply: () => ({ status: 200, body: { items: [] } }) },
  ]
}

function click(testId: string) {
  document.querySelector<HTMLElement>(`[data-testid="${testId}"] button`)?.click()
}

/** Presses the reset button (and, for sent / error, the dialog's confirm button) as a user would. */
function Driver({ send, confirm }: { send: Send; confirm: boolean }) {
  useEffect(() => {
    const release = holdHarnessReady()
    let tries = 0
    let opened = false
    let done = false
    const timer = window.setInterval(() => {
      const dialog = document.querySelector('[role="dialog"]')
      if (!opened && document.querySelector('[data-testid="admin-user-send-reset"] button')) {
        opened = true
        click('admin-user-send-reset')
      } else if (opened && !confirm && dialog) {
        done = true
      } else if (opened && confirm && dialog && !done) {
        done = true
        Array.from(dialog.querySelectorAll('button')).pop()?.click()
      } else if (done && confirm && document.querySelector('[data-testid="admin-user-reset-message"]')) {
        window.clearInterval(timer)
        release()
      }
      if (done && !confirm) {
        window.clearInterval(timer)
        release()
      } else if (++tries > 200) {
        window.clearInterval(timer)
        release()
      }
    }, 50)
    return () => {
      window.clearInterval(timer)
      release()
    }
  }, [send, confirm])
  return <UserDetailPage />
}

function screen(name: string, patch: Record<string, unknown>, send: Send, drive: 'none' | 'open' | 'confirm'): HarnessScreen {
  return {
    name,
    initialPath: '/u1',
    routePattern: '/:userId',
    routes: routes({ ...BASE, ...patch }, send),
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <main className="lf-content">
            {drive === 'none' ? <UserDetailPage /> : <Driver send={send} confirm={drive === 'confirm'} />}
          </main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

export const userResetScreens: HarnessScreen[] = [
  screen('user-reset', {}, 'none', 'none'),
  screen('user-reset-dialog', {}, 'none', 'open'),
  screen('user-reset-sent', {}, 'ok', 'confirm'),
  screen('user-reset-error', {}, 'error', 'confirm'),
  screen('user-reset-inactive', { status: 'inactive' }, 'none', 'none'),
  screen('user-reset-nologin', { auth_source: 'internal' }, 'none', 'none'),
  screen('user-reset-noemail', { email: '' }, 'none', 'none'),
]
