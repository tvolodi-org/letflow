// @vitest-environment jsdom
/** T-1520 useInstanceTimelineAll (I3..I7): every timeline page is read, so a completion on page 2 counts; new
 *  events arrive by refetch while ACTIVE; one final refetch when the instance ends; a failed page leaves the
 *  history incomplete with a retry; a duplicate event_id across pages counts once. The API is mocked. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor, cleanup, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import type { TimelineEntry, TimelinePage } from '@/types/api'

vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { tenant_id: 'tid' } }) }))
vi.mock('@/api/instances', () => ({ instancesApi: { timeline: vi.fn() } }))

import { instancesApi } from '@/api/instances'
import { useInstanceTimelineAll } from '@/hooks/useInstances'
import { deriveInstancePath, timelineEvidence } from '@/utils/canvas/instancePath'

const ev = (id: string, seq: number, event_type: string, node_id: string | null): TimelineEntry => ({
  event_id: id,
  event_type,
  sequence_num: seq,
  instance_id: 'i1',
  timestamp: '2026-11-09T10:00:00Z',
  node_id,
  task_id: null,
  metadata: {},
  actor_display_name: 'A',
  description: event_type,
})
const page = (items: TimelineEntry[], next_cursor: string | null): TimelinePage => ({ items, next_cursor, count: items.length })

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const timeline = vi.mocked(instancesApi.timeline)
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.useRealTimers()
})

const GRAPH = {
  nodes: [
    { id: 's', node_type: 'START' as const, label: null, attributes: null },
    { id: 'a', node_type: 'HUMAN_TASK' as const, label: 'A', attributes: null },
    { id: 'b', node_type: 'HUMAN_TASK' as const, label: 'B', attributes: null },
  ],
  edges: [
    { id: 'e1', source: 's', target: 'a' },
    { id: 'e2', source: 'a', target: 'b' },
  ],
}

describe('useInstanceTimelineAll', () => {
  it('I3 a completion on page 2 turns its node done; I7 a duplicate event_id across pages counts once', async () => {
    timeline.mockImplementation(async (_id, params) =>
      params?.cursor === 'c2'
        ? page([ev('x2', 2, 'TASK_COMPLETED', 'a'), ev('x3', 3, 'TASK_CREATED', null)], null)
        : page([ev('x1', 1, 'INSTANCE_STARTED', null), ev('x2', 2, 'TASK_COMPLETED', 'a')], 'c2'),
    )
    const { result } = renderHook(() => useInstanceTimelineAll('i1', { status: 'COMPLETED', pageSize: 2 }), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.complete).toBe(true))
    expect(timeline).toHaveBeenCalledTimes(2)
    expect(timeline.mock.calls[1][1]).toEqual({ page_size: 2, cursor: 'c2' })
    expect(result.current.entries.map((e) => e.event_id)).toEqual(['x1', 'x2', 'x3'])
    const ev2 = timelineEvidence(result.current.entries, { complete: result.current.complete })
    expect(ev2.completions.get('a')).toBe(1)
    const path = deriveInstancePath(GRAPH, { status: 'ACTIVE', current_nodes: ['b'] }, ev2)
    expect(path.nodes.get('a')?.state).toBe('done')
    expect(path.edges.get('e2')).toBe('taken')
  })

  it('I4/I5 polls while ACTIVE (a new event arrives), refetches once when the instance ends, then stops', async () => {
    let items = [ev('x1', 1, 'INSTANCE_STARTED', null)]
    timeline.mockImplementation(async () => page(items, null))
    const { result, rerender } = renderHook(({ status }) => useInstanceTimelineAll('i1', { status }), {
      wrapper: wrapper(),
      initialProps: { status: 'ACTIVE' },
    })
    await waitFor(() => expect(result.current.complete).toBe(true))
    items = [...items, ev('x2', 2, 'TASK_COMPLETED', 'a')]
    await waitFor(() => expect(result.current.entries).toHaveLength(2), { timeout: 4000 })
    items = [...items, ev('x3', 3, 'INSTANCE_COMPLETED', null)]
    const before = timeline.mock.calls.length
    rerender({ status: 'COMPLETED' })
    await waitFor(() => expect(result.current.entries).toHaveLength(3))
    expect(timeline.mock.calls.length).toBe(before + 1)
    await act(() => new Promise((r) => setTimeout(r, 2500)))
    expect(timeline.mock.calls.length).toBe(before + 1)
  }, 15000)

  it('I6 a failed page keeps the loaded pages, marks the history incomplete and retries', async () => {
    let fail = true
    timeline.mockImplementation(async (_id, params) => {
      if (params?.cursor === 'c2') {
        if (fail) throw new Error('boom')
        return page([ev('x2', 2, 'TASK_COMPLETED', 'a')], null)
      }
      return page([ev('x1', 1, 'INSTANCE_STARTED', null)], 'c2')
    })
    const { result } = renderHook(() => useInstanceTimelineAll('i1', { status: 'COMPLETED' }), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.complete).toBe(false)
    expect(result.current.entries.map((e) => e.event_id)).toEqual(['x1'])
    const path = deriveInstancePath(GRAPH, { status: 'ACTIVE', current_nodes: ['b'] }, timelineEvidence(result.current.entries, { complete: false }))
    expect(path.notes).toContain('historyIncomplete')
    fail = false
    act(() => result.current.retry())
    await waitFor(() => expect(result.current.complete).toBe(true))
    expect(result.current.entries).toHaveLength(2)
  })
})
