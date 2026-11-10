// @vitest-environment jsdom
/** T-1635 (REQ-799) P1: the instance page's Graph tab opens on Live (the inferred path, unchanged) and a Live | Replay
 *  switch shows the recorded-steps replay. The APIs are mocked; the diagram itself is a stub. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

// The page's own read-only React Flow (the Overview graph) needs ResizeObserver, which jsdom lacks.
class NoopResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver ??= NoopResizeObserver as unknown as typeof ResizeObserver

const GRAPH = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [{ id: 'e1', source: 'start', target: 'end' }],
}

vi.mock('@/api/instances', () => ({
  instancesApi: {
    get: vi.fn(async () => ({
      instance_id: 'i-replay',
      definition_id: 'd-replay',
      status: 'COMPLETED',
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
        { event_id: 'b', sequence_number: 2, created_at: '2026-11-09T10:00:01Z', payload: { node_id: 'end', node_type: 'END', via_edge_id: 'e1' } },
      ],
      count: 2,
      next_cursor: null,
    })),
  },
}))
vi.mock('@/api/definitions', () => ({
  definitionsApi: { get: vi.fn(async () => ({ id: 'd-replay', name: 'replay-fixture', version: '1.0.0', status: 'ACTIVE', graph: GRAPH })) },
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

describe('T-1635 InstanceDetailPage Graph tab: Live | Replay', () => {
  it('P1 Live is the default; Replay shows the recorded steps; Live comes back', async () => {
    act(() => useUiLocaleStore.getState().setLocale('en'))
    const user = userEvent.setup()
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    renderWithAccess(
      <QueryClientProvider client={qc}>
        <MemoryRouter initialEntries={['/instances/i-replay']}>
          <Routes>
            <Route path="/instances/:id" element={<InstanceDetailPage />} />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
      'platformAdmin',
    )
    await user.click(await screen.findByRole('button', { name: 'Graph' }))
    const live = await screen.findByTestId('graph-mode-live')
    expect(live).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('instance-process-diagram')).toBeInTheDocument()
    expect(screen.queryByTestId('instance-replay')).toBeNull()
    expect(instancesApi.nodeEntries).not.toHaveBeenCalled()

    await user.click(screen.getByTestId('graph-mode-replay'))
    await waitFor(() => expect(screen.getByTestId('replay-position')).toHaveTextContent('Step 2 of 2'))
    expect(screen.getByTestId('graph-mode-replay')).toHaveAttribute('aria-pressed', 'true')
    expect(screen.queryByTestId('instance-process-diagram')).toBeNull()
    expect(screen.getByRole('group', { name: 'Graph view' })).toBeInTheDocument()

    await user.click(screen.getByTestId('graph-mode-live'))
    expect(screen.getByTestId('instance-process-diagram')).toBeInTheDocument()
  })
})
