// @vitest-environment jsdom
/** T-1635 (REQ-799) useInstanceNodeEntries (H1..H4): the replay reads every NODE_ENTERED page of the history route,
 *  polls while ACTIVE with one final refetch, caps at MAX_TIMELINE_PAGES (truncated), keeps loaded pages on a failed
 *  page with a retry, and keys its cache by tenant. The API is mocked. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor, cleanup, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import type { NodeEnteredItem, NodeEntriesPage } from '@/types/api'

const session = { tenant_id: 'tenant-a' }
vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session }) }))
vi.mock('@/api/instances', () => ({ instancesApi: { nodeEntries: vi.fn() } }))

import { instancesApi } from '@/api/instances'
import { MAX_TIMELINE_PAGES, useInstanceNodeEntries } from '@/hooks/useInstances'

const item = (seq: number, node_id: string): NodeEnteredItem => ({
  event_id: `ev-${seq}`,
  sequence_number: seq,
  created_at: '2026-11-09T10:00:00Z',
  payload: { node_id, node_type: 'HUMAN_TASK', via_edge_id: null },
})
const page = (items: NodeEnteredItem[], next_cursor: string | null): NodeEntriesPage => ({ items, next_cursor, count: items.length })

function setup() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  return { qc, wrapper }
}

const nodeEntries = vi.mocked(instancesApi.nodeEntries)
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  session.tenant_id = 'tenant-a'
})

describe('T-1635 useInstanceNodeEntries', () => {
  it('H2 follows next_cursor with page size 200, dedupes by event_id and sorts by sequence_number', async () => {
    nodeEntries.mockImplementation(async (_id, params) =>
      params?.cursor === 'c2' ? page([item(2, 'b'), item(3, 'c')], null) : page([item(1, 'a'), item(2, 'b')], 'c2'),
    )
    const { result } = renderHook(() => useInstanceNodeEntries('i1', { status: 'COMPLETED' }), { wrapper: setup().wrapper })
    await waitFor(() => expect(result.current.complete).toBe(true))
    expect(nodeEntries.mock.calls[0]).toEqual(['i1', { page_size: 200 }])
    expect(nodeEntries.mock.calls[1]).toEqual(['i1', { page_size: 200, cursor: 'c2' }])
    expect(result.current.entries.map((e) => e.sequence_number)).toEqual([1, 2, 3])
    expect(result.current.truncated).toBe(false)
  })

  it('H3 stops at MAX_TIMELINE_PAGES and reports truncated; a failed page keeps loaded pages and retries', async () => {
    let n = 0
    nodeEntries.mockImplementation(async () => {
      n += 1
      return page([item(n, `n${n}`)], `c${n + 1}`)
    })
    const { result } = renderHook(() => useInstanceNodeEntries('i1', { status: 'COMPLETED' }), { wrapper: setup().wrapper })
    await waitFor(() => expect(result.current.truncated).toBe(true), { timeout: 5000 })
    expect(nodeEntries).toHaveBeenCalledTimes(MAX_TIMELINE_PAGES)
    expect(result.current.complete).toBe(false)

    cleanup()
    vi.clearAllMocks()
    let fail = true
    nodeEntries.mockImplementation(async (_id, params) => {
      if (params?.cursor === 'c2') {
        if (fail) throw new Error('boom')
        return page([item(2, 'b')], null)
      }
      return page([item(1, 'a')], 'c2')
    })
    const second = renderHook(() => useInstanceNodeEntries('i2', { status: 'COMPLETED' }), { wrapper: setup().wrapper })
    await waitFor(() => expect(second.result.current.isError).toBe(true))
    expect(second.result.current.entries).toHaveLength(1)
    fail = false
    act(() => second.result.current.retry())
    await waitFor(() => expect(second.result.current.complete).toBe(true))
    expect(second.result.current.entries).toHaveLength(2)
  })

  it('H1 polls while ACTIVE, refetches once when the instance leaves ACTIVE, then stops', async () => {
    let items = [item(1, 'a')]
    nodeEntries.mockImplementation(async () => page(items, null))
    const { result, rerender } = renderHook(({ status }) => useInstanceNodeEntries('i1', { status }), {
      wrapper: setup().wrapper,
      initialProps: { status: 'ACTIVE' },
    })
    await waitFor(() => expect(result.current.complete).toBe(true))
    items = [...items, item(2, 'b')]
    await waitFor(() => expect(result.current.entries).toHaveLength(2), { timeout: 4000 })
    items = [...items, item(3, 'end')]
    const before = nodeEntries.mock.calls.length
    rerender({ status: 'COMPLETED' })
    await waitFor(() => expect(result.current.entries).toHaveLength(3))
    expect(nodeEntries.mock.calls.length).toBe(before + 1)
    await act(() => new Promise((r) => setTimeout(r, 2500)))
    expect(nodeEntries.mock.calls.length).toBe(before + 1)
  }, 15000)

  it('H4 the cache key carries the tenant id: another tenant reads again instead of sharing the entries', async () => {
    nodeEntries.mockResolvedValue(page([item(1, 'a')], null))
    const { qc, wrapper } = setup()
    const a = renderHook(() => useInstanceNodeEntries('i1', { status: 'COMPLETED' }), { wrapper })
    await waitFor(() => expect(a.result.current.complete).toBe(true))
    a.unmount()
    session.tenant_id = 'tenant-b'
    const b = renderHook(() => useInstanceNodeEntries('i1', { status: 'COMPLETED' }), { wrapper })
    await waitFor(() => expect(b.result.current.complete).toBe(true))
    expect(nodeEntries).toHaveBeenCalledTimes(2)
    const keys = qc.getQueryCache().findAll().map((q) => q.queryKey)
    expect(keys.some((k) => k.includes('tenant-a') && k.includes('node-entries') && k.includes('i1'))).toBe(true)
    expect(keys.some((k) => k.includes('tenant-b') && k.includes('node-entries') && k.includes('i1'))).toBe(true)
  })
})

describe('T-1635 instancesApi.nodeEntries', () => {
  it('H2b calls the history route filtered by NODE_ENTERED with page size and cursor', async () => {
    vi.resetModules()
    vi.doUnmock('@/api/instances')
    const get = vi.fn().mockResolvedValue(page([], null))
    vi.doMock('@/api/client', () => ({ client: { get } }))
    const { instancesApi: real } = await import('@/api/instances')
    await real.nodeEntries('abc', { page_size: 200, cursor: 'c9' })
    expect(get).toHaveBeenCalledWith('/api/v1/instances/abc/history', { event_type: 'NODE_ENTERED', page_size: 200, cursor: 'c9' })
    vi.doUnmock('@/api/client')
  })
})
