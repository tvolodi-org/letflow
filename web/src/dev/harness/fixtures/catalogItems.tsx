/** Harness fixtures of the Items screen (task T-1402, lf-registry). Invented data only. The entity query route answers
 *  by entity type; the two stock reads answer the balances and movements of the selected item. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import { makeRoutes as prefRoutes } from './layoutBase'
import ItemsPage from '@/modules/catalog_items/items/ItemsPage'
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

const UOM = '00000000-0000-4000-8000-0000000000a1'
const KG = '00000000-0000-4000-8000-0000000000a2'
const NAMES: [string, string, string, Record<string, unknown>][] = [
  ['Milk 2.5% 1 l', 'GATEA-M-2611', UOM, { tracking_policy: 'expiry' }],
  ['Wheat bread, sliced', 'GATEA-B-0042', UOM, { tracking_policy: 'lot' }],
  ['Sunflower oil 5 l', 'GATEA-S-0007', UOM, {}],
  ['Flour, premium grade, 50 kg sack for the bakery and the canteen', 'GATEA-F-0100', KG, { tracking_policy: 'lot' }],
  ['Rice, long grain', 'GATEA-R-0031', KG, {}],
  ['Delivery service', 'GATEA-SRV-01', UOM, { kind: 'service' }],
  ['Old packaging film (discontinued)', 'GATEA-P-0003', UOM, { active: false }],
]
const ITEMS: EntityRecord[] = NAMES.map(([name, code, uom, extra], i) =>
  rec(`00000000-0000-4000-8000-00000000010${i}`, 'catalog_item', { code, name, base_uom_id: uom, kind: 'material', ...extra }),
)
const SELECTED = ITEMS[0]?.record_id ?? ''
/** The record the `-open` fixtures start with. */
export const catalogItemsSelectedId = SELECTED

const LOC_A = '00000000-0000-4000-8000-0000000000b1'
const LOC_B = '00000000-0000-4000-8000-0000000000b2'
const OU = '00000000-0000-4000-8000-0000000000c1'
const LOT = '00000000-0000-4000-8000-0000000000d1'
const REFS: Record<string, EntityRecord[]> = {
  catalog_item: ITEMS,
  catalog_uom: [rec(UOM, 'catalog_uom', { code: 'PCS', name: 'Piece' }), rec(KG, 'catalog_uom', { code: 'KG', name: 'Kilogram' })],
  location_node: [rec(LOC_A, 'location_node', { code: 'WH-ALA-A-01', name: 'Rack 01' }), rec(LOC_B, 'location_node', { code: 'WH-ALA-RCV', name: 'Receiving dock' })],
  org_unit: [rec(OU, 'org_unit', { code: 'GATEA-OU-WH', name: 'Warehouse team' })],
  catalog_lot: [rec(LOT, 'catalog_lot', { code: 'LOT-2611-A' })],
}

const BALANCES = {
  next_cursor: null,
  rows: [
    { sku: SELECTED, location: LOC_A, org_unit: OU, lot: LOT, unit_ref: UOM, quantity: '240' },
    { sku: SELECTED, location: LOC_B, org_unit: OU, lot: null, unit_ref: UOM, quantity: '36' },
  ],
}
const MOVEMENTS = {
  next_cursor: null,
  rows: [
    { entry_id: 'e3', posting_seq: 31, cause: 'count_difference', document_type: 'stock_count', event_time: '2026-10-29T10:15:00Z' },
    { entry_id: 'e2', posting_seq: 22, cause: 'transfer', document_type: 'stock_transfer', event_time: '2026-10-21T08:40:00Z' },
    { entry_id: 'e1', posting_seq: 7, cause: 'opening', document_type: 'stock_opening', event_time: '2026-10-02T09:00:00Z' },
  ],
}

type Clause = { field: string; op: string; value?: unknown }

/** The data routes of the items screen (also used by the AppShell fixtures of slice 6). */
export const catalogItemsDataRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (state, _path, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
      const all = REFS[b.entity_type ?? ''] ?? []
      return { status: 200, body: { items: state === 'empty' ? [] : all, next_cursor: null } }
    },
  },
  {
    match: (path, method) => path === '/api/v1/modules/stock/balances' && method === 'GET',
    reply: (state) => ({ status: 200, body: state === 'empty' ? { rows: [], next_cursor: null } : BALANCES }),
  },
  {
    match: (path, method) => path === '/api/v1/modules/stock/movements' && method === 'GET',
    reply: (state) => ({ status: 200, body: state === 'empty' ? { rows: [], next_cursor: null } : MOVEMENTS }),
  },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function screen(selected: boolean): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['StockRead'] } }}>
        <LayoutPrefsProvider>
          <div className="lf-main">
            <main className="lf-content lf-content--fluid">
              <ItemsPage initialItemId={selected ? SELECTED : undefined} />
            </main>
          </div>
        </LayoutPrefsProvider>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

/** A stored layout (what the preferences route answers): list pane 45 %, code column 24 %. */
const SEED_REMEMBERED = {
  v: 1,
  shell: { sidenav: {} },
  screens: { 'stock.registry.items': { panes: { list: [45] }, cols: { list: { code: 34, name: 24 } } } },
}

export const catalogItemsScreens: HarnessScreen[] = [
  { name: 'catalog-items', routes: [...prefRoutes(null), ...catalogItemsDataRoutes], render: () => screen(false) },
  { name: 'catalog-items-detail', routes: [...prefRoutes(null), ...catalogItemsDataRoutes], render: () => screen(true) },
  // the same screen at 1920 / 2560 / 3440 (the shot script sets the viewport): fluid, no centred column
  { name: 'catalog-items-wide', routes: [...prefRoutes(null), ...catalogItemsDataRoutes], render: () => screen(true) },
  { name: 'catalog-items-remembered', routes: [...prefRoutes(SEED_REMEMBERED), ...catalogItemsDataRoutes], render: () => screen(true) },
]
