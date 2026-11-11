// @vitest-environment jsdom
/** T-1753: the instance page's own texts follow the UI language (en/ru/kk). The APIs are mocked; the diagram is a stub. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, act } from '@testing-library/react'
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
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { instanceDetailMessages } from '@/pages/instances/instanceDetailMessages'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('T-1753 InstanceDetailPage texts follow the UI language', () => {
  it.each(['en', 'ru', 'kk'] as const)('%s: headings, tabs and table headers come from the catalogue', async (locale) => {
    act(() => useUiLocaleStore.getState().setLocale(locale))
    const m = instanceDetailMessages[locale]
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
    expect(await screen.findByRole('heading', { name: m.title })).toBeInTheDocument()
    for (const text of [m.snapshotHeading, m.variables, m.activeTasks, m.attachments, m.dependencyVersions, m.historyHeading]) {
      expect(screen.getByRole('heading', { name: text })).toBeInTheDocument()
    }
    expect(screen.getByRole('button', { name: m.tabGraph })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: m.refresh })).toBeInTheDocument()
    expect(screen.getByText(m.noActiveTasks)).toBeInTheDocument()
    expect(screen.getByText(m.colField)).toBeInTheDocument()
    expect(screen.getByText(m.rowCorrelationKey)).toBeInTheDocument()
    if (locale !== 'en') {
      expect(screen.queryByText('Variables')).toBeNull()
      expect(screen.queryByText('Active Tasks')).toBeNull()
      expect(screen.queryByText('Definition Snapshot')).toBeNull()
    }
  })
})
