// @vitest-environment jsdom
/**
 * Regression check for a bug discovered while verifying REQ-371's
 * `platform-definition-promotion-rollback` e2e pipeline spec (step 04):
 * the "Definition" detail row read `instance.definition_name` /
 * `instance.definition_version`, fields the backend's real
 * `GET /api/v1/instances/:id` response never sends (only `definition_id`
 * does) — so the row rendered the literal text "undefined v undefined".
 * The page already fetches the definition separately via
 * `useDefinition(instance?.definition_id)` (see the `definition` variable);
 * this asserts the row is wired to that fetched definition's `name`/
 * `version` instead, and pre-dates commit 6dd6107a (REQ-278, 2026-09-09) —
 * this bug is unrelated to REQ-371 itself, just first exposed by its spec.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const INSTANCE_ID = 'inst-1'
const DEFINITION_ID = 'def-1'

vi.mock('@/api/instances', () => ({
  instancesApi: {
    get: vi.fn(async () => ({
      instance_id: INSTANCE_ID,
      definition_id: DEFINITION_ID,
      // Deliberately NOT setting definition_name/definition_version — the
      // real backend response never includes them, and this test's point
      // is that the page must not depend on them.
      status: 'ACTIVE',
      current_nodes: ['n2'],
      variables: {},
      started_at: '2026-09-20T00:00:00Z',
    })),
    timeline: vi.fn(async () => ({ items: [], count: 0, next_cursor: null })),
    events: vi.fn(async () => ({ items: [] })),
  },
}))

vi.mock('@/api/definitions', () => ({
  definitionsApi: {
    get: vi.fn(async () => ({
      id: DEFINITION_ID,
      name: 'pl-rollback-fixture',
      version: '2.0.0',
      status: 'ACTIVE',
      graph: { nodes: [], edges: [] },
      created_by: 'admin-user',
      created_at: '2026-09-19T00:00:00Z',
      updated_at: '2026-09-19T00:00:00Z',
    })),
  },
}))

vi.mock('@/api/tasks', () => ({
  tasksApi: {
    list: vi.fn(async () => ({ items: [], next_cursor: null })),
  },
}))

vi.mock('@/hooks/usePolling', () => ({
  usePolling: vi.fn(() => ({
    lastRefreshedAt: null,
    refreshNow: vi.fn(),
    refreshCount: 0,
  })),
}))

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

vi.mock('@/components/instances/CancelInstanceDialog', () => ({
  CancelInstanceDialog: ({ instanceName }: { instanceName: string }) => (
    <div data-testid="cancel-dialog-prop" data-instance-name={instanceName}>
      {instanceName}
    </div>
  ),
}))

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 't', display_name: 'Admin', loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: null, tenant_type: null},
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

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('InstanceDetailPage — Definition detail row', () => {
  it('renders the definition name/version from the fetched definition, not the nonexistent instance fields', async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={qc}>
        <MemoryRouter initialEntries={[`/instances/${INSTANCE_ID}`]}>
          <Routes>
            <Route path="/instances/:id" element={<InstanceDetailPage />} />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
    )

    await waitFor(() => {
      const rows = screen.getAllByTestId('datatable-row')
      const definitionRow = rows.find((row) => row.textContent?.includes('Definition'))
      expect(definitionRow).toBeDefined()
      expect(definitionRow!.textContent).toContain('pl-rollback-fixture v2.0.0')
    })

    // Never the pre-fix literal-"undefined" rendering.
    expect(screen.queryByText(/undefined/i)).not.toBeInTheDocument()
  })

  it('passes the definition-based instance name into the cancel dialog, not undefined', async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={qc}>
        <MemoryRouter initialEntries={[`/instances/${INSTANCE_ID}`]}>
          <Routes>
            <Route path="/instances/:id" element={<InstanceDetailPage />} />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
    )

    await waitFor(() => {
      const trigger = screen.getByTestId('cancel-dialog-prop')
      expect(trigger).toHaveAttribute('data-instance-name', 'pl-rollback-fixture v2.0.0')
    })

    expect(screen.queryByText(/undefined/i)).not.toBeInTheDocument()
  })
})
