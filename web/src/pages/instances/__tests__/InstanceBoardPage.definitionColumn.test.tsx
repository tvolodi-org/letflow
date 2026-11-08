// @vitest-environment jsdom
/**
 * T-1495: the board's Definition column showed "undefined vundefined" because it read
 * definition_name/definition_version, which GET /api/v1/instances never sends (only
 * definition_id). The page now resolves name/version from the definition detail answer.
 * The mocked api answers use the real wire shapes.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)


// Real list item shape: definition_id only, no name/version, no updated_at.
const listItem = (instance_id: string, definition_id: string) => ({
  instance_id,
  definition_id,
  correlation_key: null,
  scope_node_id: 'root',
  status: 'ACTIVE',
  started_at: '2026-11-08T09:00:00Z',
})

vi.mock('@/api/instances', () => ({
  instancesApi: {
    list: vi.fn(async () => ({
      items: [listItem('inst-0001-aaaa', 'def-ok'), listItem('inst-0002-bbbb', 'def-gone')],
      next_cursor: null,
    })),
  },
}))

vi.mock('@/api/definitions', () => ({
  definitionsApi: {
    list: vi.fn(async () => ({ items: [], next_cursor: null })),
    get: vi.fn(async (id: string) => {
      if (id === 'def-ok') {
        return { id, name: 'Order', version: '3', status: 'ACTIVE', graph: { nodes: [], edges: [] } }
      }
      throw new Error('not found')
    }),
  },
}))

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 't', display_name: 'Admin', loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: null, tenant_type: null },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import { definitionsApi } from '@/api/definitions'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function renderBoard() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={['/instances']}>
        <InstanceBoardPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('InstanceBoardPage — Definition column (T-1495)', () => {
  it('W1: shows "Order v3" resolved from definition_id, never "undefined"', async () => {
    renderBoard()
    await waitFor(() => expect(screen.getByText('Order v3')).toBeInTheDocument())
    expect(document.body.textContent).not.toContain('undefined')
  })

  it('W2: an unresolvable definition shows an em dash, not "undefined"', async () => {
    renderBoard()
    await waitFor(() => expect(screen.getByText('Order v3')).toBeInTheDocument())
    expect(screen.getAllByText('—').length).toBeGreaterThan(0)
    expect(document.body.textContent).not.toContain('undefined')
  })

  it('W3: a loaded list shows its load time instead of "Not yet refreshed"', async () => {
    renderBoard()
    expect(screen.getByText(/Not yet refreshed/)).toBeInTheDocument()
    await waitFor(() => expect(screen.getByText('Order v3')).toBeInTheDocument())
    expect(screen.queryByText(/Not yet refreshed/)).not.toBeInTheDocument()
  })

  it('W4: while a definition is still loading the cell is a skeleton, not an em dash', async () => {
    let release: (v: unknown) => void = () => {}
    vi.mocked(definitionsApi.get).mockImplementation(
      () => new Promise((resolve) => { release = resolve }) as never,
    )
    renderBoard()
    await waitFor(() => expect(screen.getAllByTestId('skeleton').length).toBeGreaterThan(0))
    expect(screen.queryByText('—', { selector: 'td' })).toBeNull()
    release({ id: 'def-ok', name: 'Order', version: '3', status: 'ACTIVE', graph: { nodes: [], edges: [] } })
  })
})
