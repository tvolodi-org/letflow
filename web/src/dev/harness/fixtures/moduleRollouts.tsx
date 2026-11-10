/** Harness fixtures of the module rollout operator screen (T-1660). Dev only, invented data.
 *  `module-rollouts`: list with a running rollout selected (outcomes incl. outside window); `-halted`: a halted rollout
 *  with the banner and Resume; `-done`: a completed rollout (no Resume). States: default, empty (no rollouts), loading,
 *  error (the list answers 500; the detail 404 in `-notfound`). */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { RequirePermission } from '@/auth/access'
import type { AccessState } from '@/auth/access/types'
import ModuleRolloutsPage from '@/pages/admin/module-rollouts/ModuleRolloutsPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH = {
  session: { token: 'fixture', display_name: 'Platform Operator', tenant_id: 'platform-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS: AccessState = { status: 'ready', info: { roles: [], platform_tenant: true, permissions: ['ModuleRolloutsManage', 'TenantsManage'] } }

const T = (n: number) => `00000000-0000-4000-8000-00000000000${n}`
const NAMES: Record<string, string> = { [T(1)]: 'Acme Logistics', [T(2)]: 'Steppe Foods', [T(3)]: 'Altyn Retail', [T(4)]: 'Nomad Trade' }

const rollout = (id: string, status: string, over: Record<string, unknown> = {}) => ({
  id, module_id: 'assets', to_version: '1.4.0', status, halt_after: 3, consecutive_failures: 0,
  started_at: '2026-11-10T09:00:00Z', completed_at: null, halted_at: null, ...over,
})
const out = (tenant: number, status: string, over: Record<string, unknown> = {}) => ({
  tenant_id: T(tenant), status, error_code: null, plan_hash: null, attempted_at: '2026-11-10T09:05:00Z', completed_at: null, ...over,
})

const RUNNING = rollout('r-run', 'running')
const HALTED = rollout('r-halt', 'halted', { consecutive_failures: 3, halted_at: '2026-11-09T11:30:00Z', module_id: 'stock', to_version: '2.1.0' })
const DONE = rollout('r-done', 'completed', { module_id: 'exam', to_version: '0.9.2', completed_at: '2026-11-08T10:00:00Z' })

const DETAIL: Record<string, { rollout: unknown; outcomes: unknown[] }> = {
  'r-run': {
    rollout: RUNNING,
    outcomes: [
      out(1, 'succeeded', { completed_at: '2026-11-10T09:06:00Z' }),
      out(2, 'outside_window', { attempted_at: '2026-11-10T09:05:30Z' }),
      out(3, 'pending', { attempted_at: null }),
      out(4, 'skipped', { completed_at: '2026-11-10T09:07:00Z' }),
    ],
  },
  'r-halt': {
    rollout: HALTED,
    outcomes: [
      out(1, 'failed', { error_code: 'migration_failed', completed_at: '2026-11-09T11:10:00Z' }),
      out(2, 'failed', { error_code: 'plan_hash_mismatch', completed_at: '2026-11-09T11:20:00Z' }),
      out(3, 'failed', { error_code: 'migration_failed', completed_at: '2026-11-09T11:30:00Z' }),
      out(4, 'pending', { attempted_at: null }),
    ],
  },
  'r-done': { rollout: DONE, outcomes: [out(1, 'succeeded', { completed_at: '2026-11-08T09:55:00Z' }), out(2, 'succeeded', { completed_at: '2026-11-08T10:00:00Z' })] },
}

const LIST = [
  { rollout: RUNNING, counts: { succeeded: 1, outside_window: 1, pending: 1, skipped: 1 } },
  { rollout: HALTED, counts: { failed: 3, pending: 1 } },
  { rollout: DONE, counts: { succeeded: 2 } },
]

const routes = (notFound: boolean): FixtureRoute[] => [
  {
    match: (p, m) => m === 'GET' && p === '/api/v1/platform-module-rollouts',
    reply: (s) => (s === 'error' ? { status: 500, body: { title: 'internal_error', status: 500 } } : { status: 200, body: { rollouts: s === 'empty' ? [] : LIST } }),
  },
  {
    match: (p, m) => m === 'GET' && p.startsWith('/api/v1/platform-module-rollouts/'),
    reply: (_s, p) => {
      const d = DETAIL[p.split('/').pop() ?? '']
      return notFound || !d ? { status: 404, body: { title: 'not_found', status: 404 } } : { status: 200, body: d }
    },
  },
  {
    match: (p, m) => m === 'GET' && p === '/api/v1/tenants',
    reply: () => ({ status: 200, body: { items: Object.entries(NAMES).map(([tenant_id, display_name]) => ({ tenant_id, slug: display_name.toLowerCase().split(' ')[0], display_name })), next_cursor: null } }),
  },
]

function screen(name: string, id: string | null, notFound = false): HarnessScreen {
  return {
    name,
    initialPath: id ? `/admin/module-rollouts?rollout=${id}` : '/admin/module-rollouts',
    routes: routes(notFound),
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <main className="lf-content">
            <ModuleRolloutsPage />
          </main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

const DENIED: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['InstancesRead'] } }

const forbidden: HarnessScreen = {
  name: 'module-rollouts-forbidden',
  initialPath: '/admin/module-rollouts',
  routes: [],
  render: () => (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={DENIED}>
        <main className="lf-content">
          <RequirePermission permission="ModuleRolloutsManage" platformOnly>
            <ModuleRolloutsPage />
          </RequirePermission>
        </main>
      </AccessStateProvider>
    </AuthContext.Provider>
  ),
}

export const moduleRolloutsScreens: HarnessScreen[] = [
  screen('module-rollouts', 'r-run'),
  screen('module-rollouts-halted', 'r-halt'),
  screen('module-rollouts-done', 'r-done'),
  screen('module-rollouts-notfound', 'r-gone', true),
  screen('module-rollouts-list', null),
  forbidden,
]
