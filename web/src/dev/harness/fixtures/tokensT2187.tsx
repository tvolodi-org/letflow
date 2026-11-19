/** Harness fixtures for the admin Tokens page (T-2187, GH #4712): list (default, empty, error through the state
 *  switch), issue form open and revoke dialog open. One screen name per state; a driver clicks the button. */
import { useEffect, useRef, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ROLES, TENANT_ADMIN_ROLE } from '@/auth/access'
import type { AccessState } from '@/auth/access/types'
import TokensPage from '@/pages/admin/TokensPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH: AuthContextValue = {
  session: {
    token: 'harness.' + btoa(JSON.stringify({ sub: 'harness-id' })) + '.sig',
    tenant_id: 'harness-tenant',
    display_name: 'Harness Admin',
    loginSource: 'oidc',
    tenant_slug: 'harness',
    tenant_display_name: 'Harness Co',
    tenant_type: 'production',
  } as UserSession,
  isAuthenticated: true,
  isLoading: false,
  login: () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
} as unknown as AuthContextValue

const ACCESS: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['TokensManage', 'MyAccessRead'] },
}

const USER = { id: 'u-1', username: 'ainur', display_name: 'Ainur S.', email: 'ainur@example.com', status: 'active', auth_source: 'internal' }
/** A second built-in role, taken from the access module (role names may not be written outside it). */
const SECOND_ROLE = ROLES[ROLES.length - 1]
const TOKENS = [
  { id: 't-1', user_id: 'u-1', issuer_user_id: 'u-1', roles: [TENANT_ADMIN_ROLE], status: 'active', created_at: '2026-10-01T00:00:00Z', expires_at: null, revoked_at: null },
  { id: 't-2', user_id: 'u-1', issuer_user_id: null, roles: [SECOND_ROLE], status: 'revoked', created_at: '2026-09-01T00:00:00Z', expires_at: '2026-12-01T00:00:00Z', revoked_at: '2026-09-02T00:00:00Z' },
  { id: 't-3', user_id: 'u-1', issuer_user_id: null, roles: [SECOND_ROLE], status: 'expired', created_at: '2026-01-01T00:00:00Z', expires_at: '2026-02-01T00:00:00Z', revoked_at: null },
  { id: 't-4', user_id: 'u-1', issuer_user_id: null, roles: [SECOND_ROLE], status: 'owner_inactive', created_at: '2026-10-01T00:00:00Z', expires_at: null, revoked_at: null },
]

const ROUTES: FixtureRoute[] = [
  {
    match: (p, m) => p === '/api/v1/identity/tokens' && m === 'GET',
    reply: (state) => ({ status: 200, body: { items: state === 'empty' ? [] : TOKENS } }),
  },
  {
    match: (p, m) => p === '/api/v1/identity/users' && m === 'GET',
    reply: () => ({ status: 200, body: { items: [USER], next_cursor: null, count: 1 } }),
  },
]

/** Clicks the first button whose text matches once the page has drawn it. */
function Driver({ pick }: { pick: (root: HTMLElement) => HTMLElement | null }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const t = window.setInterval(() => {
      const root = ref.current
      if (!root) return
      const el = pick(root)
      if (!el) return
      window.clearInterval(t)
      el.click()
    }, 50)
    return () => window.clearInterval(t)
  }, [pick])
  return (
    <div ref={ref}>
      <TokensPage />
    </div>
  )
}

const pickIssue = (root: HTMLElement) => root.querySelector<HTMLElement>('button.lf-btn--primary')
const pickRevoke = (root: HTMLElement) => root.querySelector<HTMLElement>('button.lf-btn--danger')

function shell(content: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <div className="lf-main">
          <main className="lf-content">{content}</main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

export const tokensT2187Screens: HarnessScreen[] = [
  { name: 'tokens-admin', routes: ROUTES, render: () => shell(<TokensPage />) },
  { name: 'tokens-admin-issue', routes: ROUTES, render: () => shell(<Driver pick={pickIssue} />) },
  { name: 'tokens-admin-revoke', routes: ROUTES, render: () => shell(<Driver pick={pickRevoke} />) },
]
