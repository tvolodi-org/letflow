// @vitest-environment jsdom
/** T-1520 (D-114 item 2) the instance detail's Graph tab. I1: the states drawn come from the fixture instance and its
 *  timeline through the real hooks (useInstance, useInstanceTimelineAll, deriveInstancePath); I2: while the instance
 *  is ACTIVE the tab polls, and a completion that arrives later flips the step from active to done. The API is mocked;
 *  the diagram is a stub that prints each node's state (ProcessDiagram has its own suite). */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { InstancePath } from '@/utils/canvas/instancePath'
import type { TimelineEntry } from '@/types/api'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { tenant_id: 'tid' } }) }))
vi.mock('@/api/instances', () => ({ instancesApi: { get: vi.fn(), timeline: vi.fn() } }))
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
    </ul>
  ),
}))

import { instancesApi } from '@/api/instances'
import { ProcessGraphWithTokens } from '../ProcessGraphWithTokens'

const GRAPH = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'review', node_type: 'HUMAN_TASK', label: 'Review', attributes: null },
    { id: 'approve', node_type: 'HUMAN_TASK', label: 'Approve', attributes: null },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'review' },
    { id: 'e2', source: 'review', target: 'approve' },
    { id: 'e3', source: 'approve', target: 'end' },
  ],
}

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

const instance = (current_nodes: string[], status = 'ACTIVE') => ({
  id: 'i1',
  definition_id: 'd1',
  status,
  current_nodes,
  definition_snapshot: GRAPH,
  error_detail: null,
})

function renderTab() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <ProcessGraphWithTokens instanceId="i1" />
    </QueryClientProvider>,
  )
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('T-1520 instance Graph tab', () => {
  it('I1 draws the states derived from the instance and its timeline', async () => {
    vi.mocked(instancesApi.get).mockResolvedValue(instance(['approve']) as never)
    vi.mocked(instancesApi.timeline).mockResolvedValue({
      items: [ev('x1', 1, 'INSTANCE_STARTED', null), ev('x2', 2, 'TASK_COMPLETED', 'review')],
      next_cursor: null,
      count: 2,
    } as never)
    renderTab()
    await waitFor(() => expect(screen.getByTestId('state-review')).toHaveTextContent('done'))
    expect(screen.getByTestId('state-start')).toHaveTextContent('done')
    expect(screen.getByTestId('state-approve')).toHaveTextContent('active')
    expect(screen.getByTestId('state-end')).toHaveTextContent('pending')
    expect(screen.getByTestId('instance-process-diagram')).toBeInTheDocument()
  })

  it('I2 polls while ACTIVE: a later completion flips the step from active to done', async () => {
    let current = ['review']
    let items = [ev('x1', 1, 'INSTANCE_STARTED', null)]
    vi.mocked(instancesApi.get).mockImplementation(async () => instance(current) as never)
    vi.mocked(instancesApi.timeline).mockImplementation(async () => ({ items, next_cursor: null, count: items.length }) as never)
    renderTab()
    await waitFor(() => expect(screen.getByTestId('state-review')).toHaveTextContent('active'))
    current = ['approve']
    items = [...items, ev('x2', 2, 'TASK_COMPLETED', 'review')]
    await waitFor(() => expect(screen.getByTestId('state-review')).toHaveTextContent('done'), { timeout: 6000 })
    expect(screen.getByTestId('state-approve')).toHaveTextContent('active')
  }, 15000)
})
