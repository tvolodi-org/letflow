/** Harness fixtures of the asset card screen (T-1333 / C13). Invented data only. The query route answers by entity
 *  type and honours the `active` and equality filters the screen sends; `empty` answers no rows. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import AssetCardsPage from '@/modules/assets/AssetCardsPage'
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

const card = (id: string, no: string, name: string, unit: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'assets_card', { inventory_number: no, name, kind: 'fixed', org_unit_id: unit, ...extra })

const CARDS: EntityRecord[] = [
  card('c-1', 'FA-0001', 'Delivery van Gazelle Next', 'u-wh', {
    acquisition_date: '2022-03-15', currency: 'KZT', acquisition_cost: '14500000.00',
    accumulated_depreciation: '5800000.00', book_value: '8700000.00', depreciation_as_of: '2026-09-30',
  }),
  card('c-2', 'FA-0002', 'Reach truck with a long model name for the wrapping check', 'u-wh', { acquisition_date: '2021-11-02', acquisition_cost: '9200000' }),
  card('c-3', 'FA-0003', 'Office laser printer', 'u-it', { acquisition_date: '2024-01-20', acquisition_cost: '185000.50' }),
  card('c-4', 'LV-0101', 'Monitor 27 inch', 'u-it', { kind: 'low_value', acquisition_cost: '95000' }),
  card('c-5', 'LV-0102', 'Office chair', 'u-ho', { kind: 'low_value', acquisition_cost: '42000' }),
  card('c-6', 'IA-0201', 'Accounting software licence', 'u-ho', {
    kind: 'intangible', acquisition_cost: '1200000', valid_until: '2027-06-30', acquisition_date: '2025-07-01',
  }),
  card('c-7', 'IA-0202', 'Warehouse management add-on', 'u-wh', { kind: 'intangible', valid_until: '2026-12-31' }),
  card('c-8', 'FA-0009', 'Forklift (sold)', 'u-wh', { active: false, acquisition_cost: '6100000', book_value: '0' }),
  card('c-9', 'FA-0010', 'Pallet jack', 'u-ast', { acquisition_cost: '310000' }),
]
const UNITS: EntityRecord[] = [
  rec('u-ho', 'org_unit', { code: 'GATEA-OU-HO', name: 'Head office' }),
  rec('u-wh', 'org_unit', { code: 'GATEA-OU-WH', name: 'Warehouse team' }),
  rec('u-it', 'org_unit', { code: 'GATEA-OU-IT', name: 'IT department' }),
  rec('u-ast', 'org_unit', { code: 'GATEA-OU-AST', name: 'Astana depot' }),
]

type Clause = { field: string; op: string; value?: unknown }

function answer(state: string, body: unknown) {
  const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
  const all = b.entity_type === 'assets_card' ? CARDS : UNITS
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
  { match: (path, method) => path.startsWith('/api/v1/modules/assets/') && method !== 'GET', reply: () => ({ status: 200, body: {} }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function withAuth(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <div className="lf-main">
        <main className="lf-content">{page}</main>
      </div>
    </AuthContext.Provider>
  )
}

export const assetsScreens: HarnessScreen[] = [
  { name: 'asset-cards', routes, render: () => withAuth(<AssetCardsPage />) },
  { name: 'asset-cards-detail', routes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />) },
  { name: 'asset-cards-intangible', routes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-6" />) },
  { name: 'asset-cards-create', routes, render: () => withAuth(<AssetCardsPage initialCreating />) },
]
