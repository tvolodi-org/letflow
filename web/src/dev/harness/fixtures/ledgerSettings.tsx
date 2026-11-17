/** Harness fixtures for the Negative balances admin screen (REQ-839).
 *  One screen name per state, because the screenshot tool names files without the state. The open dialog, the
 *  reason and the on-mount submit are HARNESS-ONLY props of the page (the tool cannot click). */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import LedgerSettingsPage, { type LedgerSettingsPageProps } from '@/pages/admin/ledger-settings/LedgerSettingsPage'
import type { LedgerSetting } from '@/api/ledgerSettings'
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
  info: { roles: [], platform_tenant: false, permissions: ['LedgerSettingsManage', 'MyAccessRead'] },
}

const REFUSED: LedgerSetting = {
  registration: 'stock',
  allow_negative: false,
  changed_by: null,
  changed_by_name: null,
  changed_at: null,
  reason: null,
}
const ALLOWED: LedgerSetting = {
  ...REFUSED,
  allow_negative: true,
  changed_by: '5c1f4b0e-0000-4000-8000-000000000001',
  changed_by_name: 'Aigerim Sadykova',
  changed_at: '2026-11-10T09:30:00Z',
  reason: 'Warehouse issues before receipts are posted',
}

interface Spec {
  items?: LedgerSetting[]
  get?: { status: number; body?: unknown } | 'pending'
  put?: { status: number; body: unknown }
  props?: LedgerSettingsPageProps
}

function routesOf(spec: Spec): FixtureRoute[] {
  return [
    {
      match: (path, method) => path === '/api/v1/ledger-settings' && method === 'GET',
      pending: spec.get === 'pending',
      reply: () =>
        spec.get && spec.get !== 'pending'
          ? { status: spec.get.status, body: spec.get.body ?? { status: spec.get.status, message: 'error' } }
          : { status: 200, body: { items: spec.items ?? [REFUSED] } },
    },
    {
      match: (path, method) => path.startsWith('/api/v1/ledger-settings/') && method === 'PUT',
      reply: () => spec.put ?? { status: 200, body: ALLOWED },
    },
  ]
}

function mkScreen(name: string, spec: Spec = {}): HarnessScreen {
  return {
    name,
    routes: routesOf(spec),
    render: ({ lang }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <LedgerSettingsPage locale={lang} {...spec.props} />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

export const ledgerSettingsScreens: HarnessScreen[] = [
  mkScreen('ledger-settings-list'),
  mkScreen('ledger-settings-allowed', { items: [ALLOWED] }),
  mkScreen('ledger-settings-dialog', { props: { initialDialog: 'stock', initialReason: 'Receipts are posted after the issues' } }),
  mkScreen('ledger-settings-dialog-empty', { props: { initialDialog: 'stock' } }),
  mkScreen('ledger-settings-validation', { props: { initialDialog: 'stock', submitOnMount: true } }),
  mkScreen('ledger-settings-loading', { get: 'pending' }),
  mkScreen('ledger-settings-load-error', { get: { status: 500 } }),
  mkScreen('ledger-settings-error', {
    put: { status: 422, body: { status: 422, detail: 'not_switchable' } },
    props: { initialDialog: 'stock', initialReason: 'x', submitOnMount: true },
  }),
  mkScreen('ledger-settings-empty', { items: [] }),
]
