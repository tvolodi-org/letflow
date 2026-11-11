// @vitest-environment jsdom
/** T-1705 (REQ-812) P-W1 / P-W10: the instance page shows "Waiting since" for an ACTIVE instance only, directly below the
 *  unchanged "Active tokens" line. The APIs are mocked. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, act } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

class NoopResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver ??= NoopResizeObserver as unknown as typeof ResizeObserver

const STATUS = vi.hoisted(() => ({ value: 'ACTIVE' }))
const GRAPH = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'task', node_type: 'HUMAN_TASK', label: 'Approve request', attributes: null },
  ],
  edges: [{ id: 'e1', source: 'start', target: 'task' }],
}

vi.mock('@/api/instances', () => ({
  instancesApi: {
    get: vi.fn(async () => ({
      instance_id: 'i-wait',
      definition_id: 'd-wait',
      status: STATUS.value,
      current_nodes: [],
      variables: {},
      definition_snapshot: GRAPH,
      started_at: '2026-11-09T10:00:00Z',
    })),
    timeline: vi.fn(async () => ({ items: [], count: 0, next_cursor: null })),
    events: vi.fn(async () => ({ items: [] })),
    nodeEntries: vi.fn(async () => ({
      items: [
        { event_id: 'a', sequence_number: 1, created_at: '2026-11-09T10:00:00Z', payload: { node_id: 'start', node_type: 'START', via_edge_id: null } },
        { event_id: 'b', sequence_number: 2, created_at: '2026-11-09T10:00:01Z', payload: { node_id: 'task', node_type: 'HUMAN_TASK', via_edge_id: 'e1' } },
      ],
      count: 2,
      next_cursor: null,
    })),
  },
}))
vi.mock('@/api/definitions', () => ({
  definitionsApi: { get: vi.fn(async () => ({ id: 'd-wait', name: 'wait-fixture', version: '1.0.0', status: 'ACTIVE', graph: GRAPH })) },
}))
vi.mock('@/api/tasks', () => ({ tasksApi: { list: vi.fn(async () => ({ items: [], next_cursor: null })) } }))
vi.mock('@/hooks/usePolling', () => ({ usePolling: vi.fn(() => ({ lastRefreshedAt: null, refreshNow: vi.fn(), refreshCount: 0 })) }))
vi.mock('@/hooks/useHistoryScrubber', () => ({
  useHistoryScrubber: vi.fn(() => ({
    currentSeqNum: 0,
    totalEvents: 0,
    reconstructedState: null,
    isLoading: false,
    isLiveMode: true,
    error: null,
    goToEvent: vi.fn(),
    resumeLive: vi.fn(),
  })),
}))
vi.mock('@/components/diagram/ProcessDiagramLazy', () => ({ ProcessDiagramLazy: () => <div data-testid="diagram-stub" /> }))
vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 't', display_name: 'Admin', loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: 'tid', tenant_type: null },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import InstanceDetailPage from '@/pages/instances/InstanceDetailPage'
import { renderWithAccess } from '@/auth/access/testing'
import { instancesApi } from '@/api/instances'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function open() {
  act(() => useUiLocaleStore.getState().setLocale('en'))
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={['/instances/i-wait']}>
        <Routes>
          <Route path="/instances/:id" element={<InstanceDetailPage />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
    'platformAdmin',
  )
}

describe('T-1705 InstanceDetailPage: Waiting since', () => {
  it('P-W1 / P-W10 an ACTIVE instance shows the block below the unchanged Active tokens line', async () => {
    STATUS.value = 'ACTIVE'
    open()
    const block = await screen.findByTestId('waiting-since')
    await waitFor(() => expect(screen.getByTestId('waiting-row-task')).toHaveTextContent('Approve request'))
    const tokens = screen.getByText(/Active tokens:/)
    expect(tokens).toHaveTextContent('Active tokens: —')
    expect(tokens.compareDocumentPosition(block) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('P-W1 a COMPLETED instance has no block and the page makes no step read', async () => {
    STATUS.value = 'COMPLETED'
    open()
    await screen.findByText(/Active tokens:/)
    expect(screen.queryByTestId('waiting-since')).toBeNull()
    expect(instancesApi.nodeEntries).not.toHaveBeenCalled()
  })
})
