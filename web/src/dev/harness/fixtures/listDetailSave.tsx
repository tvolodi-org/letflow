/** Harness fixtures of the shared list + detail save rule (T-1946): a stateful fake API (writes change the data, the
 *  next query sees them) for the locations tree (create) and the asset cards (edit with a long, scrolled list).
 *  Invented data only. Own file, one registry line. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import AssetCardsPage from '@/modules/assets/AssetCardsPage'
import LocationTreePage from '@/modules/locations/LocationTreePage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id,
  entity_type: type,
  field_values: { active: true, ...fields },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
})

type Clause = { field: string; op: string; value?: unknown }

function query(store: Record<string, EntityRecord[]>): FixtureRoute {
  return {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (_s, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
      const filters = b.filters ?? []
      const onlyActive = filters.some((f) => f.field === 'active' && f.value === true)
      const one = filters.find((f) => f.field === 'record_id' && f.op === 'eq')?.value
      const items = (store[b.entity_type ?? ''] ?? []).filter(
        (r) => (!onlyActive || r.field_values['active'] === true) && (one === undefined || r.record_id === one),
      )
      return { status: 200, body: { items, next_cursor: null } }
    },
  }
}

// ---- locations: create selects the new node ----
const nodes: EntityRecord[] = [
  rec('n-wh', 'location_node', { code: 'WH-ALA', name: 'Almaty central warehouse', node_kind: 'warehouse' }),
  rec('n-rcv', 'location_node', { code: 'WH-ALA-RCV', name: 'Receiving dock', node_kind: 'zone', parent_id: 'n-wh' }),
]
const locationRoutes: FixtureRoute[] = [
  query({ location_node: nodes, org_unit: [] }),
  {
    match: (path, method) => path === '/api/v1/modules/locations/nodes' && method === 'POST',
    reply: (_s, _p, body) => {
      const b = (body ?? {}) as Record<string, unknown>
      const created = rec('n-new', 'location_node', { code: b['code'], name: b['name'], node_kind: b['node_kind'] })
      nodes.push(created)
      return { status: 200, body: created }
    },
  },
  { match: (path, method) => path.startsWith('/api/v1/modules/locations/') && method !== 'GET', reply: () => ({ status: 200, body: {} }) },
]

// ---- asset cards: edit keeps the card selected and the list scrolled ----
const cards: EntityRecord[] = Array.from({ length: 60 }, (_, i) => {
  const n = String(i + 1).padStart(4, '0')
  return rec(`c-${n}`, 'assets_card', { inventory_number: `FA-${n}`, name: `Asset card ${n}`, kind: 'fixed' })
})
const cardRoutes: FixtureRoute[] = [
  query({ assets_card: cards, org_unit: [], location_node: [], org_employee: [] }),
  {
    match: (path, method) => /\/modules\/assets\/cards\/[^/]+$/.test(path) && method === 'PATCH',
    reply: (_s, path, body) => {
      const id = decodeURIComponent(path.split('/').pop() ?? '')
      const row = cards.find((c) => c.record_id === id)
      if (row) row.field_values = { ...row.field_values, ...((body ?? {}) as Record<string, unknown>) }
      return { status: 200, body: row ?? {} }
    },
  },
  {
    match: (path, method) => /\/modules\/assets\/cards\/[^/]+\/lock$/.test(path) && method === 'GET',
    reply: () => ({ status: 200, body: { posted: false, held: false } }),
  },
  { match: (path, method) => path.startsWith('/api/v1/modules/assets/') && method === 'GET', reply: () => ({ status: 200, body: { next_cursor: null, rows: [] } }) },
  { match: (path, method) => path.startsWith('/api/v1/modules/assets/') && method !== 'GET', reply: () => ({ status: 200, body: {} }) },
]

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: {
    roles: [],
    platform_tenant: false,
    permissions: ['AssetsRead', 'AssetsPost', 'AssetsReverse', 'AssetsCardWrite', 'LocationsRead', 'LocationsWrite'],
  },
}
const withAuth = (page: ReactElement): ReactElement => (
  <AuthContext.Provider value={AUTH}>
    <AccessStateProvider state={ACCESS}>
      <div className="lf-main">
        <main className="lf-content">{page}</main>
      </div>
    </AccessStateProvider>
  </AuthContext.Provider>
)

export const listDetailSaveScreens: HarnessScreen[] = [
  { name: 'list-detail-save-locations', routes: locationRoutes, render: () => withAuth(<LocationTreePage />) },
  { name: 'list-detail-save-cards', routes: cardRoutes, render: () => withAuth(<AssetCardsPage />) },
]
