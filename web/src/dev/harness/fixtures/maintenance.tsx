/** Harness fixtures of the maintenance work requests (GH 4802 / REQ-898): the list with the request in the
 *  detail pane, the request page and the form of a new request. Invented data only. Own file (one registry line). */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import MaintenanceRequestFormPage from '@/modules/maintenance/MaintenanceRequestFormPage'
import MaintenanceRequestsPage from '@/modules/maintenance/MaintenanceRequestsPage'
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

const CARDS: EntityRecord[] = [
  rec('c-1', 'assets_card', { inventory_number: 'FA-0001', name: 'Delivery van Gazelle Next' }),
  rec('c-2', 'assets_card', { inventory_number: 'FA-0002', name: 'Reach truck with a long model name for the wrapping check' }),
  rec('c-3', 'assets_card', { inventory_number: 'FA-0003', name: 'Office laser printer' }),
]

const request = (
  id: string,
  number: string,
  status: string,
  urgency: string,
  card: { id: string; inventory_number: string; name: string },
  description: string,
  over: Record<string, unknown> = {},
) => ({
  id,
  number,
  status,
  asset: card,
  description,
  urgency,
  reported_by: 'u-1',
  reject_reason: null,
  order: null,
  photo_count: 0,
  created_at: '2026-11-21T09:15:00Z',
  ...over,
})

const PRESS = { id: 'c-1', inventory_number: 'FA-0001', name: 'Delivery van Gazelle Next' }
const TRUCK = { id: 'c-2', inventory_number: 'FA-0002', name: 'Reach truck with a long model name for the wrapping check' }
const PRINTER = { id: 'c-3', inventory_number: 'FA-0003', name: 'Office laser printer' }

const REQUESTS = [
  request('r-1', 'WR-2026-000003', 'new', 'urgent', PRESS, 'The van does not start in the morning. The engine light is on.', {
    photo_count: 2,
  }),
  request('r-2', 'WR-2026-000002', 'ordered', 'normal', TRUCK, 'The reach truck squeaks when the mast goes up.', {
    order: { id: 'o-1', number: 'WO-2026-000002' },
  }),
  request('r-3', 'WR-2026-000001', 'rejected', 'low', PRINTER, 'The printer jams every second page.', {
    reject_reason: 'The printer belongs to the office contract, not to the equipment of the plant.',
  }),
]

/** A 1x1 PNG: the stored bytes of a photo, so the tile shows a real image in the shot. */
const PHOTO_BYTES = new Blob([
  Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4duMaVsQwtCQA6GqhAcVvatIAAAAASUVORK5CYII='), (c) => c.charCodeAt(0)),
], { type: 'image/png' })

const PHOTOS = [
  { id: 'p-1', position: 1, caption: null, has_thumbnail: true, inserted_at: '2026-11-21T09:16:00Z' },
  { id: 'p-2', position: 2, caption: null, has_thumbnail: true, inserted_at: '2026-11-21T09:17:00Z' },
]

/** The routes of the screens. The `empty` state of the harness answers no rows; the `error` state answers
 *  the 500 of the harness. */
function routes(): FixtureRoute[] {
  return [
    {
      match: (path, method) => path === '/api/v1/modules/maintenance/requests' && method === 'GET',
      reply: (state) => ({ status: 200, body: { rows: state === 'empty' ? [] : REQUESTS, next_cursor: null } }),
    },
    {
      match: (path, method) => /\/modules\/maintenance\/requests\/[^/]+\/photos$/.test(path) && method === 'GET',
      reply: () => ({ status: 200, body: { photos: PHOTOS } }),
    },
    {
      match: (path, method) => /\/modules\/maintenance\/requests\/[^/]+$/.test(path) && method === 'GET',
      reply: (_s, path) => {
        const id = decodeURIComponent(path.split('/').slice(-1)[0] ?? '')
        return { status: 200, body: REQUESTS.find((r) => r.id === id) ?? REQUESTS[0] }
      },
    },
    {
      match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
      reply: () => ({ status: 200, body: { items: CARDS, next_cursor: null } }),
    },
    {
      // The bytes of a stored photo: a 1x1 PNG, so the tile shows a real image in the shot.
      match: (path, method) => /\/modules\/maintenance\/requests\/[^/]+\/photos\/[^/]+\/(original|thumbnail)$/.test(path) && method === 'GET',
      reply: () => ({ status: 200, body: PHOTO_BYTES }),
    },
    {
      match: (path, method) => path.startsWith('/api/v1/modules/maintenance/') && method !== 'GET',
      reply: () => ({ status: 200, body: {} }),
    },
  ]
}

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: {
    roles: [],
    platform_tenant: false,
    permissions: ['MaintenanceRead', 'MaintenanceRequestCreate', 'MaintenanceOrderManage'],
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

/** Harness only: clicks the element with this test id once it exists (a shot cannot click). */
function ClickTestId({ id, children }: { id: string; children: ReactElement }): ReactElement {
  useEffect(() => {
    const t = window.setInterval(() => {
      const el = document.querySelector<HTMLElement>(`[data-testid="${id}"]`)
      if (el) {
        el.click()
        window.clearInterval(t)
      }
    }, 150)
    return () => window.clearInterval(t)
  }, [id])
  return children
}

export const maintenanceScreens: HarnessScreen[] = [
  {
    name: 'maintenance-requests',
    initialPath: '/requests',
    routePattern: '/requests',
    routes: routes(),
    render: () => withAuth(<MaintenanceRequestsPage />),
  },
  {
    name: 'maintenance-request',
    initialPath: '/r-2',
    routePattern: '/:id',
    routes: routes(),
    render: () => withAuth(<MaintenanceRequestsPage />),
  },
  {
    name: 'maintenance-request-reject',
    initialPath: '/r-1',
    routePattern: '/:id',
    routes: routes(),
    render: () => withAuth(<ClickTestId id="request-reject"><MaintenanceRequestsPage /></ClickTestId>),
  },
  {
    name: 'maintenance-request-order',
    initialPath: '/r-1',
    routePattern: '/:id',
    routes: routes(),
    render: () => withAuth(<ClickTestId id="request-make-order"><MaintenanceRequestsPage /></ClickTestId>),
  },
  {
    name: 'maintenance-request-form',
    initialPath: '/new',
    routePattern: '/new',
    routes: routes(),
    render: () => withAuth(<MaintenanceRequestFormPage />),
  },
]
