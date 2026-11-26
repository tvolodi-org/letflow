/** Shared helpers of the maintenance tests (GH 4802 / REQ-898): access states, a fake server over a mocked
 *  client, the routes and the render. */
import { ToastContainer } from '@/components/ui/Toast'
import { render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import type { EntityRecord } from '@/types/api'
import { maintenanceRouteObjects } from '../maintenanceRoutes'
import type { MaintenanceRequest, Urgency } from '../maintenance.api'

export const READ_ONLY: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['MaintenanceRead'] },
}
export const WITH_CREATE: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['MaintenanceRead', 'MaintenanceRequestCreate'] },
}
export const WITH_MANAGE: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['MaintenanceRead', 'MaintenanceOrderManage'] },
}
export const WITH_ALL: AccessState = {
  status: 'ready',
  info: {
    roles: [],
    platform_tenant: false,
    permissions: ['MaintenanceRead', 'MaintenanceRequestCreate', 'MaintenanceOrderManage'],
  },
}

export type ClientMock = {
  post: ReturnType<typeof vi.fn>
  patch: ReturnType<typeof vi.fn>
  get: ReturnType<typeof vi.fn>
  getBlob: ReturnType<typeof vi.fn>
}

export function rec(id: string, type: string, fields: Record<string, unknown>): EntityRecord {
  return {
    record_id: id,
    entity_type: type,
    field_values: { active: true, ...fields },
    deleted: false,
    entity_def_version: '1',
    last_event_global_seq: 1,
  }
}

export function request(over: Partial<MaintenanceRequest> = {}): MaintenanceRequest {
  return {
    id: 'r-1',
    number: 'WR-2026-000001',
    status: 'new',
    asset: { id: 'c-1', inventory_number: 'FA-1', name: 'Press machine' },
    description: 'The press does not start.',
    urgency: 'normal',
    reported_by: 'u-1',
    reject_reason: null,
    order: null,
    photo_count: 0,
    created_at: '2026-11-21T09:00:00Z',
    ...over,
  }
}

export const CARDS: EntityRecord[] = [
  rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Press machine' }),
  rec('c-2', 'assets_card', { inventory_number: 'FA-2', name: 'Lathe' }),
]

export interface FakeServerOptions {
  requests?: MaintenanceRequest[]
  /** The answer of POST /requests; an object with a `status` is a refusal. */
  create?: (body: Record<string, unknown>) => unknown
  /** The answer of POST /requests/:id/photos; a thrown error is a refusal. */
  uploadPhoto?: (index: number) => unknown
  /** The installed modules of the tenant. */
  installed?: string[]
}

export const API = '/api/v1/modules/maintenance'

/** A fake server over the mocked client: the routes of the module, the card query and the installed modules. */
export function fakeServer(client: ClientMock, options: FakeServerOptions = {}) {
  const rows = options.requests ?? [request()]
  const installed = options.installed ?? ['maintenance']
  const photos: { id: string; position: number; caption: string | null; has_thumbnail: boolean; inserted_at: string }[] = []
  let photoIndex = 0
  client.get.mockImplementation(async (path: string) => {
    if (path === '/api/v1/me/modules') {
      return { installed_modules: installed.map((m) => ({ module_id: m, version: '1.0.0' })) }
    }
    if (path === `${API}/requests`) {
      return { rows, next_cursor: null }
    }
    const photoPath = /\/requests\/([^/]+)\/photos$/.exec(path)
    if (photoPath) return { photos }
    const one = /\/requests\/([^/]+)$/.exec(path)
    if (one) {
      const found = rows.find((r) => r.id === one[1])
      return found ?? { status: 404, details: { reason: 'not_found' } }
    }
    return { rows: [], next_cursor: null }
  })
  client.post.mockImplementation(async (path: string, body: unknown) => {
    if (path === '/api/v1/entities/query') {
      const b = body as { entity_type: string }
      if (b.entity_type === 'assets_card') return { items: CARDS, next_cursor: null }
      return { items: [], next_cursor: null }
    }
    if (path === `${API}/requests`) {
      const b = body as { asset_card_id: string; description: string; urgency: Urgency }
      const created = request({
        id: 'r-new',
        number: 'WR-2026-000002',
        description: b.description,
        urgency: b.urgency,
        asset: { id: b.asset_card_id, inventory_number: 'FA-1', name: 'Press machine' },
      })
      if (options.create) {
        const answer = options.create(body as Record<string, unknown>)
        if (answer != null && typeof answer === 'object' && 'status' in answer) throw answer
        rows.push(created)
        return answer
      }
      rows.push(created)
      return created
    }
    const photoPath = /\/requests\/([^/]+)\/photos$/.exec(path)
    if (photoPath) {
      const answer = options.uploadPhoto
        ? options.uploadPhoto(photoIndex++)
        : { id: `p-${photoIndex + 1}`, position: photoIndex + 1, caption: null, has_thumbnail: false, inserted_at: '2026-11-21T09:10:00Z' }
      if (answer != null && typeof answer === 'object' && ('status' in answer || answer instanceof Error)) throw answer
      photos.push(answer as { id: string; position: number; caption: string | null; has_thumbnail: boolean; inserted_at: string })
      return answer
    }
    const reject = /\/requests\/([^/]+)\/reject$/.exec(path)
    if (reject) {
      const b = body as { reason: string }
      const found = rows.find((r) => r.id === reject[1])
      const after = { ...(found ?? request()), status: 'rejected' as const, reject_reason: b.reason }
      const i = rows.findIndex((r) => r.id === reject[1])
      if (i >= 0) rows[i] = after
      return after
    }
    return {}
  })
  client.getBlob.mockResolvedValue({ blob: new Blob(['x'], { type: 'image/jpeg' }), contentType: 'image/jpeg' })
}

/** The bodies of the calls of one path. */
export function bodiesOf(client: ClientMock, path: string): Record<string, unknown>[] {
  return client.post.mock.calls.filter(([p]) => p === path).map(([, b]) => b as Record<string, unknown>)
}

/** The paths of the calls, in order. */
export function pathsOf(client: ClientMock): string[] {
  return client.post.mock.calls.map(([p]) => String(p))
}

function Routes() {
  return useRoutes(maintenanceRouteObjects)
}

export function renderMaintenance(path: string, access: AccessState = WITH_ALL, queryClient?: QueryClient) {
  const qc = queryClient ?? new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const result = render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
        </MemoryRouter>
        <ToastContainer />
      </AccessStateProvider>
    </QueryClientProvider>,
  )
  return { ...result, queryClient: qc }
}
