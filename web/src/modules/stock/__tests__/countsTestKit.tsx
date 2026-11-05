/** Shared helpers of the count screen tests (GH 3735 / REQ-702): access states, a fake server over a mocked client. */
import { render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import type { EntityRecord } from '@/types/api'
import type { CountEntry, CountLine, CountOrder, Differences, SignatureRow } from '../counts/counts.api'
import { stockRouteObjects } from '../stockRoutes'
import { fakeMasters, rec } from './stockTestKit'

export const accessOf = (...permissions: string[]): AccessState => ({
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions },
})
export const FULL = accessOf('StockRead', 'StockCountOrder', 'StockCountRecord')
export const READ_ONLY = accessOf('StockRead')

export type CountsClient = { post: ReturnType<typeof vi.fn>; get: ReturnType<typeof vi.fn>; put: ReturnType<typeof vi.fn> }

export const BASE = '/api/v1/modules/stock/counts'

export const COUNT_MASTERS: Record<string, EntityRecord[]> = {
  org_unit: [rec('u1', { name: 'Main store' }), rec('u2', { name: 'Yard' })],
  org_employee: [rec('e1', { full_name: 'Aigul B.' }), rec('e2', { full_name: 'Marat K.' }), rec('e3', { full_name: 'Dana S.' })],
  location_node: [rec('l1', { name: 'Shelf A' }), rec('l2', { name: 'Shelf B' })],
  catalog_item: [rec('i1', { name: 'Bolt M8' })],
  catalog_uom: [rec('m1', { name: 'pcs' })],
  catalog_lot: [rec('t1', { code: 'LOT-7', item_id: 'i1' })],
}

export function order(over: Partial<CountOrder> = {}): CountOrder {
  return {
    id: 'c1',
    org_unit_id: 'u1',
    kind: 'full',
    status: 'draft',
    planned_start: '2026-11-10T04:00:00Z',
    planned_end: '2026-11-11T04:00:00Z',
    chair_employee_id: 'e1',
    member_employee_ids: ['e2', 'e3'],
    location_ids: ['l1'],
    note: 'Year end',
    number: 'CNT-0001',
    ...over,
  }
}
export function line(no: number, over: Partial<CountLine> = {}): CountLine {
  return {
    line_no: no, kind: 'stock', location_id: 'l1', catalog_item_id: 'i1', catalog_lot_id: null,
    responsible_employee_id: 'e1', unit_ref: 'm1', book_quantity: '10', counted_quantity: null, ...over,
  }
}
export function entry(no: number, over: Partial<CountEntry> = {}): CountEntry {
  return {
    entry_no: no, line_no: 1, method: 'typed', quantity_before: null, quantity_after: '4',
    entered_by: 'user-1', entered_by_employee_id: 'e1', entered_at: '2026-11-10T04:30:00Z', ...over,
  }
}

export interface Fake {
  orders?: CountOrder[]
  /** Pages of orders for the list; the cursor of page n is `p<n+1>`. */
  orderPages?: CountOrder[][]
  /** Pages of lines / entries; the cursor of page n is `p<n+1>`. */
  linePages?: CountLine[][]
  entryPages?: CountEntry[][]
  /** Per call overrides: return or throw for a route (`POST issue` ...). */
  fail?: Record<string, unknown>
  /** Answers of POST routes by suffix (`/scan`); a function can differ per call. */
  postAnswers?: Record<string, unknown | ((body: unknown) => unknown)>
  differences?: Differences
  signatures?: SignatureRow[]
  /** Master records the entity query answers from (default COUNT_MASTERS). */
  masters?: Record<string, EntityRecord[]>
}

const paged = <T,>(pages: T[][], cursor?: string) => {
  const n = cursor ? Number(cursor.slice(1)) : 0
  return { rows: pages[n] ?? [], next_cursor: n + 1 < pages.length ? `p${n + 1}` : null }
}

/** Fakes the count routes on the mocked client; entity queries answer from COUNT_MASTERS. */
export function fakeCounts(client: CountsClient, f: Fake = {}) {
  const orders = f.orders ?? [order()]
  fakeMasters(client, f.masters ?? COUNT_MASTERS)
  const masters = client.post.getMockImplementation()!
  const maybeFail = (key: string) => {
    if (f.fail && key in f.fail) throw f.fail[key]
  }
  client.get.mockImplementation(async (path: string, params?: Record<string, string>) => {
    maybeFail(`GET ${path.replace(BASE, '')}`)
    if (path === BASE && f.orderPages) return paged(f.orderPages, params?.['cursor'])
    if (path === BASE) {
      const rows = orders.filter((o) => !params?.['status'] || o.status === params['status'])
      return { rows, next_cursor: null }
    }
    if (path.endsWith('/differences')) return f.differences ?? { number: 'DIF-1', version_no: 1, issued_at: null, content_hash: 'h', lines: [] }
    if (path.endsWith('/signatures')) return { rows: f.signatures ?? [] }
    const m = /^.*\/counts\/([^/]+)(\/lines|\/entries)?$/.exec(path)
    if (!m) return {}
    if (m[2] === '/lines') return paged(f.linePages ?? [[]], params?.['cursor'])
    if (m[2] === '/entries') return paged(f.entryPages ?? [[]], params?.['cursor'])
    const found = orders.find((o) => o.id === m[1])
    if (!found) throw { status: 404, message: 'x', code: '404' }
    return found
  })
  client.post.mockImplementation(async (path: string, body?: Record<string, unknown>) => {
    if (path === '/api/v1/entities/query') return masters(path, body)
    maybeFail(`POST ${path.replace(BASE, '')}`)
    const key = Object.keys(f.postAnswers ?? {}).find((k) => path.endsWith(k))
    if (key) {
      const a = f.postAnswers![key]
      return typeof a === 'function' ? (a as (b: unknown) => unknown)(body) : a
    }
    return order({ id: 'c-new' })
  })
  client.put.mockImplementation(async (path: string) => {
    maybeFail(`PUT ${path.replace(BASE, '')}`)
    return {}
  })
}

export function writes(client: CountsClient): [string, string, unknown][] {
  return [
    ...client.post.mock.calls.filter(([p]) => p !== '/api/v1/entities/query').map(([p, b]) => ['POST', p, b] as [string, string, unknown]),
    ...client.put.mock.calls.map(([p, b]) => ['PUT', p, b] as [string, string, unknown]),
  ]
}

function Routes() {
  return useRoutes(stockRouteObjects)
}

export function renderCounts(path: string, access: AccessState = FULL) {
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

export const LIST = '/admin/stock/counts'
export const problem = (status: number, reason?: string, field?: string) => ({
  status, message: 'x', code: String(status), ...(reason ? { details: { reason, ...(field ? { field } : {}) } } : {}),
})
