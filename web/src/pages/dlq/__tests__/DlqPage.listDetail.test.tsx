// @vitest-environment jsdom
/** T-1893 (master-detail slice 7): the DLQ detail sits in the detail pane of ListDetail (beside the table,
 *  not below it), opens on a row click, closes on its Close button and on Escape. Data, permission and
 *  route behaviour are the ones of the pagination test (REQ-277). */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, within, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false, isError: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import DlqPage from '@/pages/dlq/DlqPage'

const SESSION = {
  token: 'tok',
  display_name: 'Operator',
  loginSource: null as null,
  tenant_slug: 'test-tenant',
  tenant_display_name: 'Test Tenant',
  tenant_id: 'tid-test-tenant',
  tenant_type: 'production' as const,
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function mockAuth() {
  vi.mocked(useAuth).mockReturnValue({
    session: SESSION,
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  })
}

function mountPage() {
  mockAuth()
  vi.mocked(useQuery).mockImplementation(
    () =>
      ({
        data: {
          items: [{ id: 'dlq-1', entry_type: 'event', reason: 'boom', retry_count: 0, created_at: '2026-01-01T00:00:00Z', status: 'pending' }],
          next_cursor: null,
          count: 1,
        },
        isLoading: false,
        isError: false,
        error: null,
        refetch: vi.fn(),
      }) as unknown as ReturnType<typeof useQuery>,
  )
  return render(
    <MemoryRouter>
      <DlqPage />
    </MemoryRouter>,
  )
}

describe('T-1893 DlqPage on ListDetail', () => {
  it('shows the empty detail state, then the record inside the details pane', () => {
    mountPage()
    const pane = screen.getByTestId('registry-details')
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed')
    expect(screen.queryByTestId('dlq-detail-panel')).not.toBeInTheDocument()
    fireEvent.click(screen.getAllByTestId('datatable-row')[0]!)
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
    expect(within(pane).getByTestId('dlq-detail-panel')).toBeInTheDocument()
  })

  it('closes the record on the Close button, and on Escape', () => {
    mountPage()
    fireEvent.click(screen.getAllByTestId('datatable-row')[0]!)
    fireEvent.click(within(screen.getByTestId('dlq-detail-panel')).getByRole('button', { name: 'Close' }))
    expect(screen.queryByTestId('dlq-detail-panel')).not.toBeInTheDocument()
    fireEvent.click(screen.getAllByTestId('datatable-row')[0]!)
    fireEvent.keyDown(screen.getByTestId('dlq-detail-panel'), { key: 'Escape' })
    expect(screen.queryByTestId('dlq-detail-panel')).not.toBeInTheDocument()
  })
})
