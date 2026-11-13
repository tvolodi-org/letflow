/** Harness fixtures of the asset card screen (T-1333 / C13). Invented data only. The query route answers by entity
 *  type and honours the `active` and equality filters the screen sends; `empty` answers no rows. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import AssetCardsPage from '@/modules/assets/AssetCardsPage'
import { AssetCardFacts } from '@/modules/assets/AssetCardFacts'
import { AssetsIntlProvider } from '@/modules/assets/AssetsIntlProvider'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { currenciesRoute } from './currencyDirectoryRoute'

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
    depreciation_method: 'straight_line', depreciation_rate: '20',
  }),
  card('c-2', 'FA-0002', 'Reach truck with a long model name for the wrapping check', 'u-wh', { acquisition_date: '2021-11-02', acquisition_cost: '9200000' }),
  card('c-3', 'FA-0003', 'Office laser printer', 'u-it', { acquisition_date: '2024-01-20', acquisition_cost: '185000.50' }),
  card('c-4', 'LV-0101', 'Monitor 27 inch', 'u-it', { kind: 'low_value', acquisition_cost: '95000' }),
  card('c-5', 'LV-0102', 'Office chair', 'u-ho', { kind: 'low_value', acquisition_cost: '42000', depreciation_method: 'Declining 2x' }),
  card('c-6', 'IA-0201', 'Accounting software licence', 'u-ho', {
    kind: 'intangible', acquisition_cost: '1200000', valid_until: '2027-06-30', acquisition_date: '2025-07-01',
  }),
  card('c-7', 'IA-0202', 'Warehouse management add-on', 'u-wh', { kind: 'intangible', valid_until: '2026-12-31' }),
  card('c-8', 'FA-0009', 'Forklift (sold)', 'u-wh', { active: false, currency: 'KZT', acquisition_cost: '6100000', book_value: '0' }),
  card('c-10', 'FA-0011', 'Legacy currency card', 'u-ast', { currency: 'TNG', acquisition_cost: '120000' }),
  card('c-9', 'FA-0010', 'Pallet jack', 'u-ast', { acquisition_cost: '310000', book_value: '250000' }),
]
const UNITS: EntityRecord[] = [
  rec('u-ho', 'org_unit', { code: 'GATEA-OU-HO', name: 'Head office' }),
  rec('u-wh', 'org_unit', { code: 'GATEA-OU-WH', name: 'Warehouse team' }),
  rec('u-it', 'org_unit', { code: 'GATEA-OU-IT', name: 'IT department' }),
  rec('u-ast', 'org_unit', { code: 'GATEA-OU-AST', name: 'Astana depot' }),
]

const LOCATIONS: EntityRecord[] = [rec('l-1', 'location_node', { code: 'WH-A1', name: 'Warehouse A, rack 1' })]
const PEOPLE: EntityRecord[] = [
  rec('e-1', 'org_employee', { code: 'E-014', full_name: 'Aigul Nurlanovna', name: 'Aigul Nurlanovna' }),
  rec('e-2', 'org_employee', { code: 'E-027', full_name: 'Bolat Serikov', name: 'Bolat Serikov' }),
]

type Clause = { field: string; op: string; value?: unknown }

function answer(state: string, body: unknown, more = false) {
  const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
  const all =
    b.entity_type === 'assets_card'
      ? CARDS
      : b.entity_type === 'location_node'
        ? LOCATIONS
        : b.entity_type === 'org_employee'
          ? PEOPLE
          : UNITS
  const filters = b.filters ?? []
  const onlyActive = filters.some((f) => f.field === 'active' && f.value === true)
  const eqs = filters.filter((f) => f.op === 'eq' && f.field !== 'active' && f.field !== 'deleted')
  const items =
    state === 'empty'
      ? []
      : all.filter(
          (r) => (!onlyActive || r.field_values['active'] === true) && eqs.every((f) => r.field_values[f.field] === f.value),
        )
  // T-1793: `more` answers a first page that has a next page, so the truncation notice and Load more show
  return { status: 200, body: { items, next_cursor: more && b.entity_type === 'assets_card' ? 'next-page' : null } }
}

export const routes: FixtureRoute[] = [
  currenciesRoute,
  { match: (path, method) => path === '/api/v1/entities/query' && method === 'POST', reply: (state, _path, body) => answer(state, body) },
  // a write answers an empty object so a click in the harness does not fail
  { match: (path, method) => path.startsWith('/api/v1/modules/assets/') && method !== 'GET', reply: () => ({ status: 200, body: {} }) },
]

const moreRoutes: FixtureRoute[] = [
  { match: (path, method) => path === '/api/v1/entities/query' && method === 'POST', reply: (state, _path, body) => answer(state, body, true) },
  ...routes,
]

// T-1488: the holder section reads GET balances?asset=<id> and needs AssetsRead.
const BALANCE_ROW = { asset: 'c-1', org_unit: 'u-wh', location: 'l-1', material_responsible: 'e-1', actual_user: 'e-2', unit_ref: 'pcs', quantity: '1' }
const balancesRoute = (reply: () => { status: number; body: unknown }): FixtureRoute => ({
  match: (path, method) => path === '/api/v1/modules/assets/balances' && method === 'GET',
  reply,
})
const rowsRoutes = [balancesRoute(() => ({ status: 200, body: { rows: [BALANCE_ROW], next_cursor: null } })), ...routes]
const noRowsRoutes = [balancesRoute(() => ({ status: 200, body: { rows: [], next_cursor: null } })), ...routes]
const pendingRoutes = [{ ...balancesRoute(() => ({ status: 200, body: {} })), pending: true }, ...routes]
const errorRoutes = [balancesRoute(() => ({ status: 500, body: {} })), ...routes]
// T-1490: the lock route decides whether the inventory number of an existing card is read-only.
const lockRoute = (reply: () => { status: number; body: unknown }, pending = false): FixtureRoute => ({
  match: (path, method) => path.startsWith('/api/v1/modules/assets/cards/') && path.endsWith('/lock') && method === 'GET',
  pending,
  reply,
})
const lockedRoutes = [lockRoute(() => ({ status: 200, body: { posted: true } })), ...rowsRoutes]
const unlockedRoutes = [lockRoute(() => ({ status: 200, body: { posted: false } })), ...rowsRoutes]
const lockPendingRoutes = [lockRoute(() => ({ status: 200, body: {} }), true), ...rowsRoutes]
export const READER: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['AssetsCardWrite', 'AssetsRead'] },
}
const WRITER_ONLY: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['AssetsCardWrite'] },
}

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function withAuth(page: ReactElement, access: AccessState = WRITER_ONLY): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={access}>
        <div className="lf-main">
          <main className="lf-content">{page}</main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

export const assetsScreens: HarnessScreen[] = [
  { name: 'asset-cards', routes, render: () => withAuth(<AssetCardsPage />) },
  { name: 'asset-cards-more', routes: moreRoutes, render: () => withAuth(<AssetCardsPage />) },
  { name: 'asset-cards-detail', routes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />) },
  { name: 'asset-cards-dep-single', routes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-9" />) },
  { name: 'asset-cards-dep-legacy', routes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-5" />) },
  { name: 'asset-cards-dep-none', routes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-2" />) },
  { name: 'asset-cards-intangible', routes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-6" />) },
  { name: 'asset-cards-currency-legacy', routes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-10" />) },
  { name: 'asset-card-facts', routes, render: () => withAuth(<AssetsIntlProvider><AssetCardFacts record={CARDS[7]!} /></AssetsIntlProvider>) },
  { name: 'asset-cards-create', routes, render: () => withAuth(<AssetCardsPage initialCreating />) },
  { name: 'asset-cards-holder', routes: rowsRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />, READER) },
  { name: 'asset-cards-holder-none', routes: noRowsRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-3" />, READER) },
  { name: 'asset-cards-holder-retired', routes: rowsRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-8" />, READER) },
  { name: 'asset-cards-holder-noperm', routes: rowsRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />, WRITER_ONLY) },
  { name: 'asset-cards-holder-loading', routes: pendingRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />, READER) },
  { name: 'asset-cards-holder-error', routes: errorRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />, READER) },
  { name: 'asset-cards-lock-open', routes: unlockedRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />, READER) },
  { name: 'asset-cards-lock-posted', routes: lockedRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />, READER) },
  { name: 'asset-cards-lock-loading', routes: lockPendingRoutes, render: () => withAuth(<AssetCardsPage initialSelectedId="c-1" />, READER) },
]
