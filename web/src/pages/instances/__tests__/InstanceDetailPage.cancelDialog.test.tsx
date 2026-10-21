// @vitest-environment jsdom
/**
 * ISS-0824 / ISS-0837 regression test.
 *
 * CancelInstanceDialog.iss0809.test.tsx tests the dialog component in
 * isolation with a hard-coded instanceName prop, so a reversion of
 * InstanceDetailPage.tsx to reading the deprecated (and undefined at
 * runtime) instance.definition_name / instance.definition_version fields
 * would leave all three TC-ISS0809-* tests passing. This file closes that
 * gap: it mounts InstanceDetailPage with real instances and definitions APIs
 * mocked (no definition_name/version on the instance, only definition_id),
 * clicks the Cancel button to open the real CancelInstanceDialog, and
 * asserts the dialog's rendered text shows the fetched definition's
 * name/version rather than the literal text "undefined".
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const INSTANCE_ID = 'inst-cancel-test'
const DEFINITION_ID = 'def-cancel-test'

vi.mock('@/api/instances', () => ({
  instancesApi: {
    get: vi.fn(async () => ({
      instance_id: INSTANCE_ID,
      definition_id: DEFINITION_ID,
      // Deliberately NOT setting definition_name/definition_version — the
      // real backend response never includes them. The page must derive the
      // cancel dialog's instanceName from useDefinition(), not from these
      // absent fields.
      status: 'ACTIVE',
      current_nodes: ['n1'],
      variables: {},
      started_at: '2026-09-25T00:00:00Z',
    })),
    timeline: vi.fn(async () => ({ items: [], count: 0, next_cursor: null })),
    events: vi.fn(async () => ({ items: [] })),
  },
}))

vi.mock('@/api/definitions', () => ({
  definitionsApi: {
    get: vi.fn(async () => ({
      id: DEFINITION_ID,
      name: 'iss0824-fixture',
      version: '3.0.0',
      status: 'ACTIVE',
      graph: { nodes: [], edges: [] },
      created_by: 'admin-user',
      created_at: '2026-09-20T00:00:00Z',
      updated_at: '2026-09-20T00:00:00Z',
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

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 't',
        display_name: 'Admin',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: null,
        tenant_type: null,
        production_tenant_display_name: null,
      },
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

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('InstanceDetailPage — Cancel dialog instanceName (ISS-0824)', () => {
  it('Cancel button opens the real dialog showing definition name/version, not "undefined"', async () => {
    const user = userEvent.setup()
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    renderWithAccess(
      <QueryClientProvider client={qc}>
        <MemoryRouter initialEntries={[`/instances/${INSTANCE_ID}`]}>
          <Routes>
            <Route path="/instances/:id" element={<InstanceDetailPage />} />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
      'platformAdmin',
    )

    // Wait for the Cancel button to be rendered (ACTIVE instance + platform-admin role)
    const cancelButton = await screen.findByRole('button', { name: /cancel/i })
    await user.click(cancelButton)

    // The real CancelInstanceDialog is now open; assert the description text
    // shows the definition's name/version, not the literal string "undefined"
    // (the pre-ISS-0809 regression produced "undefined v undefined").
    await waitFor(() => {
      expect(screen.getByRole('dialog')).toBeInTheDocument()
    })

    const dialog = screen.getByRole('dialog')
    expect(dialog.textContent).toContain('iss0824-fixture v3.0.0')
    expect(dialog.textContent).not.toMatch(/\bundefined\b/)
  })
})
