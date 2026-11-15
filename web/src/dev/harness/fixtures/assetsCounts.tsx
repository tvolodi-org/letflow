/** Harness fixtures of the asset count order screens (T-1933 / REQ-822 K7a). Invented data only. Own file (one registry
 *  line): sibling style tasks all edit the registry. One screen name per state, so shots do not overwrite each other. */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import AssetCountsPage from '@/modules/assets/counts/AssetCountsPage'
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

const MASTERS: Record<string, EntityRecord[]> = {
  org_unit: [
    rec('u1', 'org_unit', { code: 'WH', name: 'Warehouse team' }),
    rec('u2', 'org_unit', { code: 'IT', name: 'IT department' }),
  ],
  location_node: [
    rec('l1', 'location_node', { code: 'R-12', name: 'Almaty central warehouse' }),
    rec('l2', 'location_node', { code: 'R-14', name: 'Office floor 2' }),
  ],
  org_employee: [
    rec('e1', 'org_employee', { full_name: 'Aigerim Sarsenova' }),
    rec('e2', 'org_employee', { full_name: 'Marat Kenzhebekov' }),
    rec('e3', 'org_employee', { full_name: 'Dana Serikbayeva' }),
  ],
}

const base = {
  org_unit_id: 'u1',
  planned_start: '2026-11-16T04:00:00Z',
  planned_end: '2026-11-17T04:00:00Z',
  chair_employee_id: 'e1',
  member_employee_ids: ['e2', 'e3'],
  location_ids: ['l1', 'l2'],
  note: 'Year-end count of the warehouse and the office floor',
  freeze_locations: false,
  freeze_state: 'none',
}
const ORDERS: Record<string, Record<string, unknown>> = {
  'c-draft': { id: 'c-draft', ...base, kinds: ['fixed', 'low_value'], status: 'draft', number: null },
  'c-ordered': {
    id: 'c-ordered', ...base, kinds: ['fixed'], status: 'ordered', number: 'ACN-2026-000004', issued_at: '2026-11-12T08:00:00Z',
    freeze_locations: true, freeze_state: 'active', freeze_until: '2026-11-17T04:00:00Z',
  },
  'c-counting': { id: 'c-counting', ...base, kinds: ['fixed', 'low_value', 'intangible'], status: 'counting', number: 'ACN-2026-000003', issued_at: '2026-11-10T08:00:00Z', location_ids: [] },
  'c-cancelled': { id: 'c-cancelled', ...base, kinds: ['intangible'], status: 'cancelled', number: 'ACN-2026-000002', issued_at: '2026-11-05T08:00:00Z', cancelled_at: '2026-11-06T08:00:00Z' },
}
const ROWS = Object.values(ORDERS)

type Variant = 'default' | 'empty' | 'off' | 'refuse-cancel'

function routesOf(variant: Variant): FixtureRoute[] {
  return [
    {
      match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
      reply: (_s, _p, body) => {
        const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; value?: unknown }[] }
        const ids = b.filters?.find((f) => f.field === 'record_id')?.value
        let items = MASTERS[b.entity_type ?? ''] ?? []
        if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
        return { status: 200, body: { items, next_cursor: null } }
      },
    },
    {
      match: (path, method) => path === '/api/v1/modules/assets/counts' && method === 'GET',
      reply: (state) =>
        variant === 'off'
          ? { status: 404, body: { error: 'not_found' } }
          : { status: 200, body: { next_cursor: null, rows: variant === 'empty' || state === 'empty' ? [] : ROWS } },
    },
    {
      match: (path, method) => path.startsWith('/api/v1/modules/assets/counts/') && method === 'GET',
      reply: (_s, path) => {
        const o = ORDERS[decodeURIComponent(path.split('/').pop() ?? '')]
        return o ? { status: 200, body: o } : { status: 404, body: { error: 'not_found' } }
      },
    },
    {
      match: (path, method) => path.endsWith('/cancel') && method === 'POST',
      reply: () =>
        variant === 'refuse-cancel'
          ? { status: 422, body: { error: 'unprocessable', reason: 'not_chair' } }
          : { status: 200, body: ORDERS['c-ordered'] },
    },
    { match: (path, method) => path.startsWith('/api/v1/modules/assets/counts') && method !== 'GET', reply: () => ({ status: 200, body: ORDERS['c-draft'] }) },
  ]
}

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const accessWith = (...permissions: string[]) => ({ status: 'ready' as const, info: { roles: [], platform_tenant: false, permissions } })
const FULL = accessWith('AssetsRead', 'AssetsCountOrder', 'AssetsCountRecord')
const READ_ONLY = accessWith('AssetsRead')

function withAuth(page: ReactElement, access = FULL): ReactElement {
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

/** Harness only: clicks the elements that match the selectors, one after the other, each once it exists (a shot cannot
 *  click). Polls fast, so a chain of two or three clicks is done before the shot's ready signal. */
function ClickSequence({ selectors, children }: { selectors: string[]; children: ReactElement }): ReactElement {
  useEffect(() => {
    let step = 0
    const id = window.setInterval(() => {
      const el = document.querySelector<HTMLElement>(selectors[step] ?? '')
      if (el) {
        el.click()
        step += 1
        if (step >= selectors.length) window.clearInterval(id)
      }
    }, 20)
    return () => window.clearInterval(id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectors.join('|')])
  return children
}

const screen = (name: string, variant: Variant, opts: { id?: string; wrap?: (e: ReactElement) => ReactElement; access?: typeof FULL } = {}): HarnessScreen => ({
  name,
  routes: routesOf(variant),
  ...(opts.id ? { initialPath: `/${opts.id}`, routePattern: '/:id' } : {}),
  render: () => withAuth((opts.wrap ?? ((e) => e))(<AssetCountsPage />), opts.access),
})

const click = (...selectors: string[]) => (e: ReactElement) => <ClickSequence selectors={selectors}>{e}</ClickSequence>

export const assetsCountsScreens: HarnessScreen[] = [
  screen('assets-counts-list', 'default'),
  screen('assets-counts-empty', 'empty'),
  { name: 'assets-counts-loading', routes: routesOf('default').map((r) => (r.match('/api/v1/modules/assets/counts', 'GET') ? { ...r, pending: true } : r)), render: () => withAuth(<AssetCountsPage />) },
  { name: 'assets-counts-error', routes: routesOf('default').map((r) => (r.match('/api/v1/modules/assets/counts', 'GET') ? { ...r, reply: () => ({ status: 500, body: { error: 'server_error' } }) } : r)), render: () => withAuth(<AssetCountsPage />) },
  screen('assets-counts-off', 'off'),
  screen('assets-counts-new', 'default', { wrap: click('[data-testid="count-new"]') }),
  screen('assets-counts-invalid', 'default', { wrap: click('[data-testid="count-new"]', '[data-testid="count-save"]') }),
  screen('assets-counts-draft', 'default', { id: 'c-draft' }),
  screen('assets-counts-edit', 'default', { id: 'c-draft', wrap: click('[data-testid="count-edit"]') }),
  screen('assets-counts-ordered', 'default', { id: 'c-ordered' }),
  screen('assets-counts-confirm', 'refuse-cancel', {
    id: 'c-ordered',
    wrap: click('[data-testid="count-cancel"]', '[role="dialog"] .lf-btn--danger'),
  }),
  screen('assets-counts-readonly', 'default', { id: 'c-ordered', access: READ_ONLY }),
]
