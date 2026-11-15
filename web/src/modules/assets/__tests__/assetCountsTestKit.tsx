/** Shared helpers of the asset count order tests (T-1933 / K7a): access states, a fake server over a mocked client. */
import type { AccessState } from '@/auth/access/types'
import type { AssetCountOrder } from '../counts/assetCounts.api'
import { MASTERS, fakeMasters, rec, type ClientMock } from './registerTestKit'

export { renderAssets, refusal } from './registerTestKit'

export const accessOf = (...permissions: string[]): AccessState => ({
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions },
})
export const FULL = accessOf('AssetsRead', 'AssetsCountOrder', 'AssetsCountRecord')
export const READ_ONLY = accessOf('AssetsRead')

export const COUNTS = '/api/v1/modules/assets/counts'
export const LIST = '/admin/assets/counts'

export const COUNT_MASTERS = {
  ...MASTERS,
  org_employee: [...MASTERS['org_employee']!, rec('e3', 'org_employee', { full_name: 'Dana S.' })],
  location_node: [...MASTERS['location_node']!, rec('l2', 'location_node', { code: 'R2', name: 'Room 2' })],
}

export function order(over: Partial<AssetCountOrder> = {}): AssetCountOrder {
  return {
    id: 'c1',
    org_unit_id: 'u1',
    kinds: ['fixed', 'intangible'],
    status: 'draft',
    planned_start: '2026-11-10T04:00:00Z',
    planned_end: '2026-11-11T04:00:00Z',
    chair_employee_id: 'e1',
    member_employee_ids: ['e2', 'e3'],
    location_ids: ['l1'],
    note: 'Year end',
    freeze_locations: true,
    freeze_state: 'none',
    number: 'AC-0001',
    ...over,
  }
}

export interface Fake {
  orders?: AssetCountOrder[]
  /** Per call overrides: thrown for a route (`GET list`, `POST /c1/issue` ...). */
  fail?: Record<string, unknown>
  /** What POST/PUT answer with (default: a new draft). */
  saved?: AssetCountOrder
}

/** Fakes the count routes on the mocked client; entity queries answer from COUNT_MASTERS. */
export function fakeCounts(client: ClientMock & { put: NonNullable<ClientMock['put']> }, f: Fake = {}) {
  const orders = f.orders ?? [order()]
  fakeMasters(client, COUNT_MASTERS)
  const masters = client.post.getMockImplementation()! as (path: string, body?: Record<string, unknown>) => Promise<unknown>
  const maybeFail = (key: string) => {
    if (f.fail && key in f.fail) throw f.fail[key]
  }
  client.get.mockImplementation(async (path: string, params?: Record<string, string>) => {
    if (path === COUNTS) {
      maybeFail('GET list')
      return { rows: orders.filter((o) => !params?.['status'] || o.status === params['status']), next_cursor: null }
    }
    const id = path.slice(COUNTS.length + 1)
    maybeFail(`GET ${id}`)
    const found = orders.find((o) => o.id === id)
    if (!found) throw { status: 404, message: 'x', code: '404' }
    return found
  })
  client.post.mockImplementation(async (path: string, body?: Record<string, unknown>) => {
    if (path === '/api/v1/entities/query') return masters(path, body)
    maybeFail(`POST ${path.replace(COUNTS, '')}`)
    return f.saved ?? order({ id: 'c-new' })
  })
  client.put.mockImplementation(async (path: string) => {
    maybeFail(`PUT ${path.replace(COUNTS, '')}`)
    return f.saved ?? order()
  })
}

/** The writes to the count routes, in order. */
export function writes(client: ClientMock & { put: NonNullable<ClientMock['put']> }): [string, string, unknown][] {
  return [
    ...client.post.mock.calls.filter(([p]) => String(p).startsWith(COUNTS)).map(([p, b]) => ['POST', p, b] as [string, string, unknown]),
    ...client.put.mock.calls.map(([p, b]) => ['PUT', p, b] as [string, string, unknown]),
  ]
}
