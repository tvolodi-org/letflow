// @vitest-environment jsdom
/** T-1635 (REQ-799) the Replay view of the instance Graph tab (C1..C8). The API is mocked; the diagram is a stub that
 *  prints each node's state and each taken edge (ProcessDiagram has its own suite). Times are pinned to UTC. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { InstancePath } from '@/utils/canvas/instancePath'
import type { NodeEnteredItem } from '@/types/api'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { tenant_id: 'tid' } }) }))
vi.mock('@/api/instances', () => ({ instancesApi: { get: vi.fn(), nodeEntries: vi.fn(), timeline: vi.fn() } }))
vi.mock('@/api/definitions', () => ({ definitionsApi: { get: vi.fn() } }))
vi.mock('@/components/diagram/ProcessDiagramLazy', () => ({
  ProcessDiagramLazy: ({ path }: { path: InstancePath | null }) => (
    <ul data-testid="diagram-stub">
      {path
        ? [...path.nodes.entries()].map(([id, s]) => (
            <li key={id} data-testid={`state-${id}`}>
              {s.state}
            </li>
          ))
        : null}
      {path ? <li data-testid="taken">{[...path.edges.keys()].sort().join(' ')}</li> : null}
    </ul>
  ),
}))

import { instancesApi } from '@/api/instances'
import { definitionsApi } from '@/api/definitions'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { InstanceReplay } from '../InstanceReplay'

const GRAPH = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'split', node_type: 'PARALLEL_GATEWAY', label: null, attributes: null },
    { id: 'x', node_type: 'HUMAN_TASK', label: 'Check stock', attributes: null },
    { id: 'y', node_type: 'HUMAN_TASK', label: 'Approve budget', attributes: null },
    { id: 'join', node_type: 'PARALLEL_GATEWAY', label: 'Join', attributes: null },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'split' },
    { id: 'e2', source: 'split', target: 'x' },
    { id: 'e3', source: 'split', target: 'y' },
    { id: 'e4', source: 'x', target: 'join' },
    { id: 'e5', source: 'y', target: 'join' },
    { id: 'e6', source: 'join', target: 'end' },
  ],
}

const entry = (seq: number, node_id: string, node_type: string, via: string | null, at: string): NodeEnteredItem => ({
  event_id: `ev-${seq}`,
  sequence_number: seq,
  created_at: at,
  payload: { node_id, node_type, via_edge_id: via },
})

const FULL = [
  entry(1, 'start', 'START', null, '2026-11-09T10:00:00Z'),
  entry(2, 'split', 'PARALLEL_GATEWAY', 'e1', '2026-11-09T10:00:00Z'),
  entry(3, 'x', 'HUMAN_TASK', 'e2', '2026-11-09T10:00:00Z'),
  entry(4, 'y', 'HUMAN_TASK', 'e3', '2026-11-09T10:00:00Z'),
  entry(5, 'join', 'PARALLEL_GATEWAY', 'e4', '2026-11-09T10:05:30Z'),
  entry(6, 'join', 'PARALLEL_GATEWAY', 'e5', '2026-11-09T11:10:30Z'),
  entry(7, 'end', 'END', 'e6', '2026-11-09T11:10:30Z'),
]

const instance = (status = 'COMPLETED') => ({ id: 'i1', definition_id: 'd1', status, current_nodes: [], definition_snapshot: GRAPH, error_detail: null })
const page = (items: NodeEnteredItem[]) => ({ items, next_cursor: null, count: items.length })

function renderReplay() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <InstanceReplay instanceId="i1" timeZone="UTC" />
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  act(() => useUiLocaleStore.getState().setLocale('en'))
  vi.mocked(definitionsApi.get).mockResolvedValue({ id: 'd1', graph: GRAPH } as never)
})
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const state = (id: string) => screen.queryByTestId(`state-${id}`)?.textContent ?? null

describe('T-1635 InstanceReplay', () => {
  it('C1/C3 a finished instance opens on its last step (END done, nothing active); stepping changes the drawn states', async () => {
    vi.mocked(instancesApi.get).mockResolvedValue(instance() as never)
    vi.mocked(instancesApi.nodeEntries).mockResolvedValue(page(FULL) as never)
    renderReplay()
    await waitFor(() => expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 7 of 7'))
    expect(state('end')).toBe('done')
    expect(screen.queryAllByText('active')).toHaveLength(0)
    expect(screen.getByTestId('taken')).toHaveTextContent('e1 e2 e3 e4 e5 e6')

    fireEvent.click(screen.getByTestId('replay-first'))
    expect(state('start')).toBe('active')
    expect(state('split')).toBeNull()
    for (let i = 0; i < 4; i++) fireEvent.click(screen.getByTestId('replay-next'))
    // Step 5: the first arrival at the join; the join waits (active), y is still active.
    expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 5 of 7')
    expect(state('join')).toBe('active')
    expect(state('x')).toBe('done')
    expect(state('y')).toBe('active')
    expect(state('end')).toBeNull()
  })

  it('C2 each step shows its time and the time since the previous step; join arrivals name their branch', async () => {
    vi.mocked(instancesApi.get).mockResolvedValue(instance() as never)
    vi.mocked(instancesApi.nodeEntries).mockResolvedValue(page(FULL) as never)
    renderReplay()
    const list = await screen.findByTestId('replay-steps')
    expect(within(list).getAllByRole('listitem')).toHaveLength(7)
    const s5 = screen.getByTestId('replay-step-5')
    expect(s5).toHaveTextContent('Join')
    expect(s5).toHaveTextContent('from Check stock')
    expect(s5).toHaveTextContent('10:05:30')
    expect(s5).toHaveTextContent('+5 min 30 s since previous step')
    expect(screen.getByTestId('replay-step-6')).toHaveTextContent('from Approve budget')
    expect(screen.getByTestId('replay-step-6')).toHaveTextContent('+1 h 5 min since previous step')
    expect(screen.getByTestId('replay-step-2')).toHaveTextContent('+less than 1 s since previous step')
    expect(screen.getByTestId('replay-step-1')).not.toHaveTextContent('since previous step')
  })

  it('C4 a running instance follows the last step, but stays on the step the user chose', async () => {
    let items = FULL.slice(0, 4)
    vi.mocked(instancesApi.get).mockResolvedValue(instance('ACTIVE') as never)
    vi.mocked(instancesApi.nodeEntries).mockImplementation(async () => page(items) as never)
    renderReplay()
    await waitFor(() => expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 4 of 4'))
    items = FULL.slice(0, 5)
    await waitFor(() => expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 5 of 5'), { timeout: 4000 })
    fireEvent.click(screen.getByTestId('replay-step-3').querySelector('button')!)
    expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 3 of 5')
    items = FULL.slice(0, 6)
    await waitFor(() => expect(screen.getByTestId('replay-steps').children).toHaveLength(6), { timeout: 4000 })
    expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 3 of 6')
    fireEvent.click(screen.getByTestId('replay-last'))
    expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 6 of 6')
  }, 15000)

  it('C5 no recorded steps: an info banner and the Live view', async () => {
    vi.mocked(instancesApi.get).mockResolvedValue(instance() as never)
    vi.mocked(instancesApi.nodeEntries).mockResolvedValue(page([]) as never)
    vi.mocked(instancesApi.timeline).mockResolvedValue({ items: [], next_cursor: null, count: 0 } as never)
    renderReplay()
    await waitFor(() => expect(screen.getByTestId('instance-replay')).toHaveAttribute('data-coverage', 'none'))
    expect(screen.getByText(/No path was recorded for this instance/)).toBeInTheDocument()
    expect(screen.getByTestId('instance-process-diagram')).toBeInTheDocument()
    expect(screen.queryByTestId('replay-range')).toBeNull()
  })

  it('C6 first recorded step is not START: a "not recorded before" banner with the first time', async () => {
    vi.mocked(instancesApi.get).mockResolvedValue(instance() as never)
    vi.mocked(instancesApi.nodeEntries).mockResolvedValue(page(FULL.slice(4)) as never)
    renderReplay()
    await waitFor(() => expect(screen.getByTestId('instance-replay')).toHaveAttribute('data-coverage', 'partial'))
    expect(screen.getByText(/Steps before .*10:05:30.* were not recorded\./)).toBeInTheDocument()
    expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 3 of 3')
  })

  it('C7 buttons and the range input move the step; aria-current marks the row; the live region follows', async () => {
    vi.mocked(instancesApi.get).mockResolvedValue(instance() as never)
    vi.mocked(instancesApi.nodeEntries).mockResolvedValue(page(FULL) as never)
    renderReplay()
    await screen.findByTestId('replay-steps')
    expect(screen.getByTestId('replay-step-7')).toHaveAttribute('aria-current', 'step')
    expect(screen.getByTestId('replay-next')).toBeDisabled()
    fireEvent.click(screen.getByTestId('replay-previous'))
    expect(screen.getByTestId('replay-step-6')).toHaveAttribute('aria-current', 'step')
    expect(screen.getByTestId('replay-step-7')).not.toHaveAttribute('aria-current')
    fireEvent.change(screen.getByTestId('replay-range'), { target: { value: '3' } })
    expect(screen.getByTestId('replay-step-3')).toHaveAttribute('aria-current', 'step')
    const live = screen.getByTestId('replay-status')
    expect(live).toHaveAttribute('aria-live', 'polite')
    expect(live).toHaveTextContent('Step 3 of 7: Check stock')
    fireEvent.click(screen.getByTestId('replay-first'))
    expect(screen.getByTestId('replay-first')).toBeDisabled()
    expect(live).toHaveTextContent('Step 1 of 7: Start')
    expect(screen.getByRole('group', { name: 'Replay steps' })).toBeInTheDocument()
    expect(screen.getByRole('list', { name: 'Recorded steps' })).toBeInTheDocument()
  })

  it('C9 a load error with nothing read shows the error banner with retry', async () => {
    vi.mocked(instancesApi.get).mockResolvedValue(instance() as never)
    vi.mocked(instancesApi.nodeEntries).mockRejectedValue(new Error('boom'))
    renderReplay()
    expect(await screen.findByText('The recorded steps could not be loaded.')).toBeInTheDocument()
    vi.mocked(instancesApi.nodeEntries).mockResolvedValue(page(FULL) as never)
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    await waitFor(() => expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 7 of 7'))
  })

  it.each(['ru', 'kk'] as const)('C8 renders in %s with no missing or broken message', async (loc) => {
    const errors = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    act(() => useUiLocaleStore.getState().setLocale(loc))
    vi.mocked(instancesApi.get).mockResolvedValue(instance() as never)
    vi.mocked(instancesApi.nodeEntries).mockResolvedValue(page(FULL) as never)
    renderReplay()
    await screen.findByTestId('replay-steps')
    const text = screen.getByTestId('instance-replay').textContent ?? ''
    expect(text).not.toMatch(/processDiagram\./)
    expect(text).not.toMatch(/Step \d of/)
    expect(errors.mock.calls.map((c) => String(c[0]))).not.toContainEqual(expect.stringMatching(/FORMAT_ERROR|MISSING_TRANSLATION/))
    errors.mockRestore()
  })
})
