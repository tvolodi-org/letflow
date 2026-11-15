/** T-2012: the real process list/editor inside the real shell, with isolated API fixtures. */
import { lazy, Suspense } from 'react'
import { Route, Routes } from 'react-router-dom'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import type { ProcessDefinition, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AppShell = lazy(() => import('@/components/layout/AppShell').then(m => ({ default: m.AppShell })))
const AUTH = {
  session: { token: 'harness', display_name: 'Aigerim', tenant_id: 'harness-tenant', tenant_slug: 'demo', tenant_display_name: 'Demo', tenant_type: 'test' } as UserSession,
  isAuthenticated: true, isLoading: false, loginSource: null,
  login: async () => undefined, logout: () => undefined, setSession: () => undefined,
  switchTenant: async () => 'ok', switchingToTenantSlug: null,
} as AuthContextValue

function routes(failure: boolean): FixtureRoute[] {
  let def: ProcessDefinition = {
    id: 'discovery', name: 'purchase_request', version: '1.0.0', description: '', status: 'DRAFT',
    created_by: 'Aigerim', created_at: '2026-11-01T09:00:00Z', updated_at: '2026-11-01T09:00:00Z',
    graph: {
      nodes: [
        { id: 'start', node_type: 'START', label: null, attributes: null },
        { id: 'end', node_type: 'END', label: null, attributes: null },
      ],
      edges: [{ id: 'e1', source: 'start', target: 'end' }],
    },
  }
  return [
    { match: p => p === '/health', reply: () => ({ status: 200, body: { status: 'ok' } }) },
    { match: p => p === '/api/v1/me/preferences', reply: () => ({ status: 200, body: { preferences: {}, effective: {}, tenant_defaults: {} } }) },
    { match: (p, m) => m === 'GET' && p === '/api/v1/definitions', reply: s => ({ status: 200, body: { items: s === 'empty' ? [] : [def], next_cursor: null } }) },
    { match: (p, m) => m === 'GET' && p === '/api/v1/definitions/discovery', reply: () => ({ status: 200, body: def }) },
    { match: (p, m) => m === 'PATCH' && p === '/api/v1/definitions/discovery', reply: (_s, _p, body) => {
      def = { ...def, ...(body as Partial<ProcessDefinition>), updated_at: '2026-11-16T09:00:00Z' }
      return { status: 200, body: def }
    } },
    { match: p => p.endsWith('/activate'), reply: () => {
      if (failure) return { status: 422, body: { title: 'Invalid graph', status: 422, errors: [{ code: 'missing_end', message: 'A process must have an end step.' }] } }
      def = { ...def, status: 'ACTIVE' }
      return { status: 200, body: def }
    } },
    { match: p => p.endsWith('/validate'), reply: () => ({ status: 200, body: { status: 'valid', findings: [], definition_id: def.id } }) },
    { match: () => true, reply: () => ({ status: 200, body: { items: [], next_cursor: null } }) },
  ]
}

function frame(editor: boolean, reader: boolean) {
  return <AuthContext.Provider value={AUTH}>
    <BrandingProvider>
      <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, user_id: 'harness', permissions: reader ? ['DefinitionsRead'] : ['DefinitionsRead', 'DefinitionsWrite'] } }}>
        <LayoutPrefsProvider><Suspense fallback={null}><Routes>
          <Route element={<AppShell fluid />}><Route path="*" element={editor ? <DefinitionEditorPage /> : <DefinitionListPage />} /></Route>
        </Routes></Suspense></LayoutPrefsProvider>
      </AccessStateProvider>
    </BrandingProvider>
  </AuthContext.Provider>
}

export const processDiscoveryScreens: HarnessScreen[] = [
  { name: 'process-discovery-list', routes: routes(false), render: () => frame(false, false) },
  { name: 'process-discovery-reader', routes: routes(false), render: () => frame(false, true) },
  { name: 'process-discovery-edit', initialPath: '/definitions/discovery', routePattern: '/definitions/:id', routes: routes(false), render: () => frame(true, false) },
  { name: 'process-discovery-blocked', initialPath: '/definitions/discovery', routePattern: '/definitions/:id', routes: routes(true), render: () => frame(true, false) },
]
