/** Shared helpers of the asset document and register tests (T-1334 / C14): access states, a fake server over a mocked
 *  client (masters through /entities/query, documents and ledger reads through get), render. */
import { render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import type { EntityRecord } from '@/types/api'
import { assetsRouteObjects } from '../assetsRoutes'

function access(...permissions: string[]): AccessState {
  return { status: 'ready', info: { roles: [], platform_tenant: false, permissions } }
}
export const withRead = access('AssetsRead')
export const withPost = access('AssetsRead', 'AssetsPost')
export const withReverse = access('AssetsRead', 'AssetsReverse')
export const withAll = access('AssetsRead', 'AssetsPost', 'AssetsReverse')
export const withoutAtom = access()

export type ClientMock = {
  post: ReturnType<typeof vi.fn>
  get: ReturnType<typeof vi.fn>
  put?: ReturnType<typeof vi.fn>
  delete?: ReturnType<typeof vi.fn>
}

export function rec(id: string, type: string, fields: Record<string, unknown>): EntityRecord {
  return { record_id: id, entity_type: type, field_values: { active: true, ...fields }, deleted: false, entity_def_version: '1', last_event_global_seq: 1 }
}

export const MASTERS: Record<string, EntityRecord[]> = {
  assets_card: [rec('a1', 'assets_card', { inventory_number: 'FA-0001', name: 'Delivery van' }), rec('a2', 'assets_card', { inventory_number: 'FA-0002', name: 'Laptop' })],
  org_unit: [rec('u1', 'org_unit', { code: 'WH', name: 'Warehouse' }), rec('u2', 'org_unit', { code: 'IT', name: 'IT dept' })],
  location_node: [rec('l1', 'location_node', { code: 'R1', name: 'Room 1' })],
  org_employee: [rec('e1', 'org_employee', { full_name: 'Aigul B.' }), rec('e2', 'org_employee', { full_name: 'Marat K.' })],
}

type Clause = { field: string; op: string; value?: unknown }

/** /entities/query answers from `data`: the active and deleted filters and `record_id in`. */
export function fakeMasters(client: ClientMock, data: Record<string, EntityRecord[]> = MASTERS) {
  client.post.mockImplementation(async (path: string, body: Record<string, unknown>) => {
    if (path !== '/api/v1/entities/query') return {}
    const filters = (body['filters'] ?? []) as Clause[]
    const ids = filters.find((f) => f.field === 'record_id' && f.op === 'in')?.value as string[] | undefined
    const items = (data[body['entity_type'] as string] ?? []).filter((r) => !ids || ids.includes(r.record_id))
    return { items, next_cursor: null }
  })
}

export function queryBodies(client: ClientMock, type: string): Record<string, unknown>[] {
  return client.post.mock.calls
    .filter(([p, b]) => p === '/api/v1/entities/query' && (b as { entity_type: string }).entity_type === type)
    .map(([, b]) => b as Record<string, unknown>)
}

export const API = '/api/v1/modules/assets'
export const DOCS = `${API}/documents`
export const LIST = '/admin/assets/documents'
export const BAL = '/admin/assets/balances'
export const MOV = '/admin/assets/movements'

/** The params of the calls to a ledger read route. */
export function routeCalls(client: ClientMock, route: 'balances' | 'movements' | 'documents'): Record<string, string>[] {
  return client.get.mock.calls.filter(([p]) => p === `${API}/${route}`).map(([, params]) => (params ?? {}) as Record<string, string>)
}

function Routes() {
  return useRoutes(assetsRouteObjects)
}

export function renderAssets(path: string, accessState: AccessState = withRead) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={accessState}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

export function refusal(status: number, reason?: string, extra: Record<string, unknown> = {}) {
  return { status, message: 'x', code: String(status), details: reason ? { reason, ...extra } : { ...extra } }
}

export function assetDoc(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: 'd1', kind: 'commission', state: 'draft', number: null, issued_at: null, header_id: 'h1',
    org_unit_id: 'u1', location_id: 'l1', material_responsible_id: 'e1', actual_user_id: 'e2',
    event_time: '2026-11-04T05:00:00Z', note: null,
    lines: [
      { line_id: 'x2', line_no: 2, asset_id: 'a2', quantity: '1.000000000' },
      { line_id: 'x1', line_no: 1, asset_id: 'a1', quantity: '1.000000000' },
    ],
    posted_at: null, posted_by: null, entry_id: null, reversed_at: null, reversed_by: null, posting_check: null,
    ...over,
  }
}

/** GET of one document answers `doc`; the list answers one row for it; the other calls are set by the test. */
export function fakeDocument(client: ClientMock, doc: Record<string, unknown>) {
  client.get.mockImplementation(async (path: string) => {
    if (path === `${DOCS}/${String(doc['id'])}`) return doc
    if (path === DOCS) return { rows: [{ id: doc['id'], kind: doc['kind'], state: doc['state'], number: doc['number'], org_unit_id: doc['org_unit_id'], event_time: doc['event_time'] }], next_cursor: null }
    return { rows: [], next_cursor: null }
  })
}

export function postsTo(client: ClientMock, suffix: string): unknown[][] {
  return client.post.mock.calls.filter(([p]) => p === `${DOCS}/${suffix}`)
}
