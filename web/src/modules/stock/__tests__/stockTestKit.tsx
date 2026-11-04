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
export const withoutAtom: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: [] },
}

export type ClientMock = { post: ReturnType<typeof vi.fn>; get: ReturnType<typeof vi.fn> }

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
  catalog_item: [rec('i1', { name: 'Bolt M8' }), rec('i2', { name: 'Nut M8' })],
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
