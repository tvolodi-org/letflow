/** Harness fixtures of the locations screens (task T-1172, style S3). Invented data only. The query route answers
 *  by entity type and honours the `active` and equality filters the screens send; `empty` answers no rows. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import LocationLinksPage from '@/modules/locations/LocationLinksPage'
import LocationTreePage from '@/modules/locations/LocationTreePage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

function rec(id: string, type: string, fields: Record<string, unknown>): EntityRecord {
  return {
    record_id: id,
    entity_type: type,
    field_values: { active: true, ...fields },
    deleted: false,
    entity_def_version: '1',
    last_event_global_seq: 1,
  }
}

const node = (id: string, code: string, name: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'location_node', { code, name, node_kind: 'zone', ...extra })

const NODES: EntityRecord[] = [
  node('n-wh', 'WH-ALA', 'Almaty central warehouse', { node_kind: 'warehouse', location_type: 'custody' }),
  node('n-rcv', 'WH-ALA-RCV', 'Receiving dock', { parent_id: 'n-wh', location_type: 'receiving', address: 'RCV' }),
  node('n-a', 'WH-ALA-A', 'Zone A: fast moving goods and consumables', { parent_id: 'n-wh', location_type: 'pick' }),
  node('n-a1', 'WH-ALA-A-01', 'Rack 01', { parent_id: 'n-a', node_kind: 'rack', segment: '01', address: 'A-01' }),
  node('n-a101', 'WH-ALA-A-01-01', 'Bin 01', { parent_id: 'n-a1', node_kind: 'bin', segment: '01', address: 'A-01-01' }),
  node('n-a102', 'WH-ALA-A-01-02', 'Bin 02', { parent_id: 'n-a1', node_kind: 'bin', segment: '02', address: 'A-01-02' }),
  node('n-q', 'WH-ALA-QRN', 'Quarantine', { parent_id: 'n-wh', location_type: 'quarantine' }),
  node('n-old', 'WH-ALA-OLD', 'Old yard (closed)', { parent_id: 'n-wh', location_type: 'outdoor', active: false }),
  node('n-ast', 'WH-AST', 'Astana depot', { node_kind: 'warehouse', location_type: 'custody' }),
]
const UNITS: EntityRecord[] = [
  rec('u-ho', 'org_unit', { code: 'GATEA-OU-HO', name: 'Head office' }),
  rec('u-wh', 'org_unit', { code: 'GATEA-OU-WH', name: 'Warehouse team', parent: 'u-ho' }),
  rec('u-it', 'org_unit', { code: 'GATEA-OU-IT', name: 'IT department', parent: 'u-ho' }),
]
const LINKS: EntityRecord[] = [
  rec('k-1', 'location_org_unit_link', { org_unit_id: 'u-wh', location_id: 'n-wh' }),
  rec('k-2', 'location_org_unit_link', { org_unit_id: 'u-wh', location_id: 'n-rcv' }),
  rec('k-3', 'location_org_unit_link', { org_unit_id: 'u-wh', location_id: 'n-a1' }),
]

type Clause = { field: string; op: string; value?: unknown }

function answer(state: string, body: unknown) {
  const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
  const all = b.entity_type === 'location_node' ? NODES : b.entity_type === 'org_unit' ? UNITS : LINKS
  const filters = b.filters ?? []
  const onlyActive = filters.some((f) => f.field === 'active' && f.value === true)
  const eqs = filters.filter((f) => f.op === 'eq' && f.field !== 'active' && f.field !== 'deleted')
  const items =
    state === 'empty'
      ? []
      : all.filter(
          (r) => (!onlyActive || r.field_values['active'] === true) && eqs.every((f) => r.field_values[f.field] === f.value),
        )
  return { status: 200, body: { items, next_cursor: null } }
}

const routes: FixtureRoute[] = [
  { match: (path, method) => path === '/api/v1/entities/query' && method === 'POST', reply: (state, _path, body) => answer(state, body) },
  // a write answers an empty object so a click in the harness does not fail
  { match: (path, method) => path.startsWith('/api/v1/modules/locations/') && method !== 'GET', reply: () => ({ status: 200, body: {} }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function withAuth(page: ReactElement): ReactElement {
  // the same frame the app shell gives a page: .lf-content is the padded, gapped column
  return (
    <AuthContext.Provider value={AUTH}>
      <div className="lf-main">
        <main className="lf-content">{page}</main>
      </div>
    </AuthContext.Provider>
  )
}

export const locationsScreens: HarnessScreen[] = [
  { name: 'locations', routes, render: () => withAuth(<LocationTreePage />) },
  { name: 'locations-detail', routes, render: () => withAuth(<LocationTreePage initialSelectedId="n-a" />) },
  { name: 'location-links', routes, render: () => withAuth(<LocationLinksPage initialUnitId="u-wh" />) },
]
