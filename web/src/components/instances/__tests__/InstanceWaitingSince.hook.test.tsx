// @vitest-environment jsdom
/** T-1705 (REQ-812) the "Waiting since" block with the REAL data hook (C-W6-loading-paging, C-W6-error retry, C-W7-requests).
 *  Only the API client is mocked. Real timers. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { NodeEnteredItem } from '@/types/api'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { tenant_id: 'tid' } }) }))
vi.mock('@/api/instances', () => ({ instancesApi: { nodeEntries: vi.fn(), get: vi.fn(), timeline: vi.fn() } }))

import { instancesApi } from '@/api/instances'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { InstanceWaitingSince } from '../InstanceWaitingSince'

const node = (id: string, node_type: string, label: string | null = null) => ({ id, node_type, label, attributes: null })
const GRAPH = {
  nodes: [node('start', 'START'), node('t', 'HUMAN_TASK', 'Approve'), node('u', 'HUMAN_TASK', 'Sign')],
  edges: [
    { id: 'a', source: 'start', target: 't' },
    { id: 'b', source: 't', target: 'u' },
  ],
}
const entry = (seq: number, node_id: string, node_type: string, via: string | null, at: string): NodeEnteredItem => ({
  event_id: `ev-${seq}`,
  sequence_number: seq,
  created_at: at,
  payload: { node_id, node_type, via_edge_id: via },
})
const P1 = [entry(1, 'start', 'START', null, '2026-11-09T10:00:00Z'), entry(2, 't', 'HUMAN_TASK', 'a', '2026-11-09T10:00:01Z')]
const P2 = [entry(3, 'u', 'HUMAN_TASK', 'b', '2026-11-09T10:10:00Z')]

function show() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <InstanceWaitingSince instanceId="i1" status="ACTIVE" graph={GRAPH as never} timeZone="UTC" />
    </QueryClientProvider>,
  )
}

beforeEach(() => act(() => useUiLocaleStore.getState().setLocale('en')))
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('T-1705 InstanceWaitingSince with the real hook', () => {
  it('C-W6-loading-paging page 1 has a cursor and page 2 is pending: skeleton and no rows; after page 2 the rows appear', async () => {
    let release: (v: unknown) => void = () => {}
    vi.mocked(instancesApi.nodeEntries)
      .mockResolvedValueOnce({ items: P1, count: 2, next_cursor: 'c2' } as never)
      .mockImplementationOnce(() => new Promise((r) => (release = r)) as never)
      .mockResolvedValue({ items: P2, count: 1, next_cursor: null } as never)
    show()
    await waitFor(() => expect(instancesApi.nodeEntries).toHaveBeenCalledTimes(2))
    const block = screen.getByTestId('waiting-since')
    expect(block.querySelector('[aria-busy="true"]')).not.toBeNull()
    expect(screen.queryByRole('list')).toBeNull()
    expect(screen.queryByText(/Since/)).toBeNull()
    await act(async () => release({ items: P2, count: 1, next_cursor: null }))
    await waitFor(() => expect(screen.getByRole('list')).toBeInTheDocument())
    expect(screen.getAllByRole('listitem')).toHaveLength(1)
    expect(screen.getByTestId('waiting-row-u')).toHaveTextContent('Sign')
  })

  it('C-W6-error a failed read shows the banner; Retry makes a second read and the rows come', async () => {
    vi.mocked(instancesApi.nodeEntries)
      .mockRejectedValueOnce(new Error('boom'))
      .mockResolvedValue({ items: P1.concat(P2), count: 3, next_cursor: null } as never)
    show()
    const retry = await screen.findByRole('button', { name: 'Try again' })
    expect(screen.queryByRole('list')).toBeNull()
    fireEvent.click(retry)
    await waitFor(() => expect(screen.getByRole('list')).toBeInTheDocument())
    expect(instancesApi.nodeEntries).toHaveBeenCalledTimes(2)
  })

  it('C-W7-requests the block reads only the NODE_ENTERED history of its instance', async () => {
    vi.mocked(instancesApi.nodeEntries).mockResolvedValue({ items: P1, count: 2, next_cursor: null } as never)
    show()
    await screen.findByRole('list')
    expect(instancesApi.nodeEntries).toHaveBeenCalled()
    for (const call of vi.mocked(instancesApi.nodeEntries).mock.calls) expect(call[0]).toBe('i1')
    expect(instancesApi.get).not.toHaveBeenCalled()
    expect(instancesApi.timeline).not.toHaveBeenCalled()
  })
})
