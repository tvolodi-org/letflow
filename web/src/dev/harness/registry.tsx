/** Fixtures registry (task S0d). Every screen task adds one entry here: its name, the fake API routes it reads
 *  and a render function. Keep fixtures to plain data; no secrets, no real tenant names. */
import { useEffect } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { ToastContainer } from '@/components/ui/Toast'
import LotsPage from '@/modules/catalog_items/LotsPage'
import VerifyCertificatePage from '@/pages/VerifyCertificatePage'
// The harness renders a module's screen directly (it needs the screen's `initial` preset, which the route does
// not carry); the module boundary rule is about modules importing each other, not about this dev-only file.
import CodesPage, { type CodesInitial } from '@/modules/codes/CodesPage'
import { locationsScreens } from './fixtures/locations'
import { orgLegal, orgSites, orgUnits, orgUnitsNewChild } from './orgFixtures'
import type { EntityRecord } from '@/types/api'
import type { FixtureRoute, HarnessLang, HarnessScreen } from './types'

const verifyCertificate: HarnessScreen = {
  name: 'verify-certificate',
  initialPath: '/verify/demo-handle',
  routePattern: '/verify/:handle',
  routes: [
    {
      match: path => path.startsWith('/api/public/certificate/'),
      // empty: the server answers not found, the page shows its single "not valid" result.
      reply: state =>
        state === 'empty'
          ? { status: 404, body: { title: 'Not found', status: 404 } }
          : {
              status: 200,
              body: {
                candidate_name: 'Aigerim Sarsenova',
                exam_title: 'Warehouse operations, level 2',
                score_pct: 87,
                issued_on: '2026-10-30',
              },
            },
    },
  ],
  render: () => <VerifyCertificatePage />,
}

/** Codes screen (task S4): invented codes and targets, served through the generic query route. */
type Rec = { record_id: string; entity_type: string; field_values: Record<string, unknown>; deleted: boolean; entity_def_version: string; last_event_global_seq: number }
const rec = (id: string, type: string, fields: Record<string, unknown>): Rec => ({
  record_id: id,
  entity_type: type,
  field_values: { active: true, ...fields },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
})
const CODE_DATA: Record<string, Rec[]> = {
  code_tag: [
    rec('c1', 'code_tag', { value: 'E280116061B9D57E00000001', kind: 'epc', status: 'assigned' }),
    rec('c2', 'code_tag', { value: 'E2801160200074A1B2C30001', kind: 'tid', status: 'not_assigned' }),
    rec('c3', 'code_tag', { value: 'GATEA-BC-0001', kind: 'barcode', status: 'assigned' }),
    rec('c4', 'code_tag', { value: 'GATEA-BC-0002', kind: 'barcode', status: 'not_assigned' }),
    rec('c5', 'code_tag', { value: 'GATEA-QR-0001', kind: 'qr', status: 'assigned' }),
    rec('c6', 'code_tag', { value: 'GATEA-BC-0003', kind: 'barcode', status: 'retired' }),
  ],
  location_node: [
    rec('l1', 'location_node', { code: 'WHGATEA-A-01', name: 'Rack 01' }),
    rec('l2', 'location_node', { code: 'WHGATEA-A-02', name: 'Rack 02' }),
  ],
  catalog_item: [rec('i1', 'catalog_item', { code: 'ITM-0042', name: 'Laptop Dell Latitude 5440' })],
  catalog_lot: [rec('t1', 'catalog_lot', { code: 'GATEA-M-2611', name: 'Milk 2.5% 1 l' })],
  code_assignment: [
    rec('a1', 'code_assignment', { code_id: 'c1', target_type: 'catalog_item', target_id: 'i1', assigned_at: '2026-11-03T10:42:00Z' }),
    rec('a2', 'code_assignment', { code_id: 'c3', target_type: 'catalog_lot', target_id: 't1', assigned_at: '2026-11-02T15:58:00Z' }),
    rec('a3', 'code_assignment', { code_id: 'c5', target_type: 'location_node', target_id: 'l1', assigned_at: '2026-11-02T15:57:00Z' }),
    rec('a4', 'code_assignment', {
      code_id: 'c1', target_type: 'location_node', target_id: 'l2',
      assigned_at: '2026-10-20T09:00:00Z', released_at: '2026-11-03T10:30:00Z',
    }),
  ],
}

type Clause = { field: string; op: string; value?: unknown }
function queryCodes(state: string, body: unknown) {
  const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
  if (state === 'empty') return { status: 200, body: { items: [], next_cursor: null } }
  const items = (CODE_DATA[b.entity_type ?? ''] ?? []).filter((r) =>
    (b.filters ?? []).every((f) => {
      if (f.field === 'released_at' && f.op === 'is_null') return r.field_values['released_at'] === undefined
      if (f.op === 'eq' && f.field !== 'deleted') return r.field_values[f.field] === f.value
      return true
    }),
  )
  return { status: 200, body: { items, next_cursor: null } }
}

/** Lots screen (module catalog_items, T-1174). Invented data; the entity query route answers per entity_type. */
function fixtureRecord(id: string, type: string, fields: Record<string, unknown>): EntityRecord {
  return {
    record_id: id,
    entity_type: type,
    field_values: { active: true, ...fields },
    deleted: false,
    entity_def_version: '1',
    last_event_global_seq: 1,
  }
}
const LOT_ITEMS = [
  fixtureRecord('i1', 'catalog_item', { code: 'GATEA-M-2611', name: 'Milk 2.5% 1 l' }),
  fixtureRecord('i2', 'catalog_item', { code: 'GATEA-B-0042', name: 'Wheat bread, sliced' }),
  fixtureRecord('i3', 'catalog_item', { code: 'GATEA-S-0007', name: 'Sunflower oil 5 l' }),
]
const LOT_ROWS = [
  fixtureRecord('l1', 'catalog_lot', { code: 'LOT-2611-A', item_id: 'i1', producer: 'Dala Dairy', mark: 'KZ-M-0001', expiry_date: '2026-11-20' }),
  fixtureRecord('l2', 'catalog_lot', { code: 'LOT-2611-B', item_id: 'i1', producer: 'Dala Dairy', mark: '', expiry_date: '2026-12-02' }),
  fixtureRecord('l3', 'catalog_lot', { code: 'LOT-0042-A', item_id: 'i2', producer: 'Steppe Bakery', mark: 'KZ-B-0310', expiry_date: '2026-11-08' }),
  fixtureRecord('l4', 'catalog_lot', { code: 'LOT-0007-A', item_id: 'i3', producer: '', mark: '', expiry_date: '' }),
  fixtureRecord('l5', 'catalog_lot', { code: 'LOT-0007-OLD', item_id: 'i3', producer: 'Altyn Oil', mark: '', expiry_date: '2026-08-01', active: false }),
]
const HARNESS_AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' },
  isAuthenticated: true,
} as unknown as AuthContextValue

/** Answers the entity query route from the invented rows: by entity_type, honouring the active and item filters. */
function lotQueryReply(state: string, _path: string, body?: unknown) {
  const req = (body ?? {}) as { entity_type?: string; filters?: { field: string; value?: unknown }[] }
  const filters = req.filters ?? []
  const rows = req.entity_type === 'catalog_item' ? LOT_ITEMS : state === 'empty' ? [] : LOT_ROWS
  const items = rows.filter(r =>
    filters.every(f => f.field === 'deleted' || r.field_values[f.field] === f.value),
  )
  return { status: 200, body: { items, next_cursor: null } }
}

const codesRoutes: FixtureRoute[] = [{ match: (path: string) => path === '/api/v1/entities/query', reply: (state: Parameters<FixtureRoute['reply']>[0], _path: string, body?: unknown) => queryCodes(state, body) }]
/** A signed-in stand-in: the harness has no login. Only `session.tenant_id` (a cache key part) is read. */
const harnessAuth = {
  session: { tenant_id: 'harness-tenant' },
  isAuthenticated: true,
  isLoading: false,
  loginSource: null,
  login: async () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
  switchTenant: async () => 'ok',
  switchingToTenantSlug: null,
} as unknown as AuthContextValue
const withWrite: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['CodesWrite'] } }

function codesScreen(name: string, initial?: CodesInitial): HarnessScreen {
  return {
    name,
    routes: codesRoutes,
    render: ({ lang }) => (
      <AuthContext.Provider value={harnessAuth}>
        <AccessStateProvider state={withWrite}>
          <main className="lf-content">
            <CodesPage locale={lang} initial={initial} />
          </main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

/** Opens the panel the way a user does: clicks the create button or the first row's edit button once they exist. */
function CatalogItemsLotsHarness({ lang, open }: { lang: HarnessLang; open?: 'create' | 'edit' }) {
  useEffect(() => {
    if (!open) return
    const testid = open === 'create' ? 'create-lot' : 'edit-LOT-2611-A'
    let tries = 0
    const timer = window.setInterval(() => {
      const el = document.querySelector<HTMLElement>(`[data-testid="${testid}"]`)
      tries += 1
      if (el) el.click()
      if (el || tries > 60) window.clearInterval(timer)
    }, 50)
    return () => window.clearInterval(timer)
  }, [open])
  return (
    <AuthContext.Provider value={HARNESS_AUTH}>
      <AccessStateProvider
        state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['CatalogLotsWrite'] } }}
      >
        <main className="lf-content">
          <LotsPage locale={lang} />
        </main>
        <ToastContainer />
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

const lotsRoutes = [{ match: (path: string, method: string) => method === 'POST' && path === '/api/v1/entities/query', reply: lotQueryReply }]
const catalogItemsLots: HarnessScreen = {
  name: 'catalog-items-lots',
  routes: lotsRoutes,
  render: ({ lang }) => <CatalogItemsLotsHarness lang={lang} />,
}
const catalogItemsLotsEdit: HarnessScreen = {
  name: 'catalog-items-lots-edit',
  routes: lotsRoutes,
  render: ({ lang }) => <CatalogItemsLotsHarness lang={lang} open="edit" />,
}
const catalogItemsLotsCreate: HarnessScreen = {
  name: 'catalog-items-lots-create',
  routes: lotsRoutes,
  render: ({ lang }) => <CatalogItemsLotsHarness lang={lang} open="create" />,
}

export const HARNESS_SCREENS: Record<string, HarnessScreen> = Object.fromEntries(
  [
    verifyCertificate,
    orgLegal,
    orgSites,
    orgUnits,
    orgUnitsNewChild,
    catalogItemsLots,
    catalogItemsLotsEdit,
    catalogItemsLotsCreate,
    codesScreen('codes'),
    codesScreen('codes-detail', { selectedId: 'c1' }),
    codesScreen('codes-assign', { assignId: 'c2' }),
    codesScreen('codes-receive', { receive: true }),
    ...locationsScreens,
  ].map(s => [s.name, s]),
)
