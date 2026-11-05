/** Shared helpers of the stock register tests (GH 3767 / REQ-724): access state, a fake server over a mocked client. */
import { render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import type { EntityRecord } from '@/types/api'
import { stockRouteObjects } from '../stockRoutes'

export const withAtom: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['StockRead'] },
}
function access(...permissions: string[]): AccessState {
  return { status: 'ready', info: { roles: [], platform_tenant: false, permissions } }
}
export const withPost = access('StockRead', 'StockPost')
export const withReverse = access('StockRead', 'StockReverse')
export const withAll = access('StockRead', 'StockPost', 'StockReverse')
export const withoutAtom: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: [] },
}

export type ClientMock = {
  post: ReturnType<typeof vi.fn>
  get: ReturnType<typeof vi.fn>
  put?: ReturnType<typeof vi.fn>
  delete?: ReturnType<typeof vi.fn>
}

export function rec(id: string, fields: Record<string, unknown>): EntityRecord {
  return {
    record_id: id,
    entity_type: 'x',
    field_values: { active: true, ...fields },
    deleted: false,
    entity_def_version: '1',
    last_event_global_seq: 1,
  }
}

type Clause = { field: string; op: string; value?: unknown }

export const MASTERS: Record<string, EntityRecord[]> = {
  catalog_item: [rec('i1', { name: 'Bolt M8', base_uom_id: 'm1' }), rec('i2', { name: 'Nut M8', base_uom_id: 'm1' })],
  catalog_counterparty: [rec('c1', { name: 'Acme Ltd' })],
  location_node: [rec('l1', { name: 'Shelf A' })],
  org_unit: [rec('u1', { name: 'Main store' })],
  org_employee: [rec('e1', { full_name: 'Aigul B.' })],
  catalog_lot: [rec('t1', { code: 'LOT-7', item_id: 'i1' }), rec('t2', { code: 'LOT-9', item_id: 'i2' })],
  catalog_uom: [rec('m1', { name: 'pcs' })],
}

/** /entities/query answers from `data`: active and deleted filters, `item_id eq`, `record_id in`. */
export function fakeMasters(client: ClientMock, data: Record<string, EntityRecord[]> = MASTERS) {
  client.post.mockImplementation(async (path: string, body: Record<string, unknown>) => {
    if (path !== '/api/v1/entities/query') return {}
    const filters = (body['filters'] ?? []) as Clause[]
    const ids = filters.find((f) => f.field === 'record_id' && f.op === 'in')?.value as string[] | undefined
    const itemId = filters.find((f) => f.field === 'item_id' && f.op === 'eq')?.value
    const items = (data[body['entity_type'] as string] ?? []).filter(
      (r) => (!ids || ids.includes(r.record_id)) && (itemId === undefined || r.field_values['item_id'] === itemId),
    )
    return { items, next_cursor: null }
  })
}

export function queryBodies(client: ClientMock, type: string): Record<string, unknown>[] {
  return client.post.mock.calls
    .filter(([p, b]) => p === '/api/v1/entities/query' && (b as { entity_type: string }).entity_type === type)
    .map(([, b]) => b as Record<string, unknown>)
}

/** The params of the calls to a register route. */
export function routeCalls(client: ClientMock, route: 'balances' | 'movements'): Record<string, string>[] {
  return client.get.mock.calls
    .filter(([p]) => p === `/api/v1/modules/stock/${route}`)
    .map(([, params]) => (params ?? {}) as Record<string, string>)
}

function Routes() {
  return useRoutes(stockRouteObjects)
}

export function renderStock(path: string, access: AccessState = withAtom) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

export function problem(status: number) {
  return { status, message: 'x', code: String(status) }
}

export const BAL = '/admin/stock/balances'
export const MOV = '/admin/stock/movements'

export const DOCS = '/api/v1/modules/stock/documents'
export const LIST = '/admin/stock/documents'

export function stockDoc(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: 'd1', kind: 'receipt', state: 'draft', number: null, issued_at: null, header_id: 'h1',
    org_unit_id: 'u1', location_id: 'l1', responsible_id: 'e1', counterparty_id: null,
    event_time: '2026-11-04T05:00:00Z', note: null,
    lines: [
      { line_id: 'x2', line_no: 2, catalog_item_id: 'i2', catalog_uom_id: 'm1', catalog_lot_id: 't2', quantity: '5.000000000', unit_price: '2', line_value: '10' },
      { line_id: 'x1', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '3.000000000' },
    ],
    posted_at: null, posted_by: null, entry_id: null, reversed_at: null, reversed_by: null, posting_check: null,
    ...over,
  }
}

/** A thrown refusal as `client` makes it: status plus the RFC 9457 members in `details`. */
export function refusal(status: number, reason?: string, extra: Record<string, unknown> = {}) {
  return { status, message: 'x', code: String(status), details: reason ? { reason, ...extra } : { ...extra } }
}

/** GET of one document answers `doc`; every other call is set by the test. */
export function fakeDocument(client: ClientMock, doc: Record<string, unknown>) {
  client.get.mockImplementation(async (path: string) => {
    if (path === `${DOCS}/${String(doc['id'])}`) return doc
    return { rows: [], next_cursor: null }
  })
}

export function postsTo(client: ClientMock, suffix: string): unknown[][] {
  return client.post.mock.calls.filter(([p]) => p === `${DOCS}/${suffix}`)
}
