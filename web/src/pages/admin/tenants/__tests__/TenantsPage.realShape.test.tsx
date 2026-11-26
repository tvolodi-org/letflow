// @vitest-environment jsdom
/**
 * Mounts the real TenantsPage with the real GET /api/v1/tenants row shape
 * (lib/letflow/routers/tenants.ex tenant_map/1: lowercase status, inserted_at).
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false, isError: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/api/queryKeys', () => ({
  queryKeys: { admin: { tenants: vi.fn(() => ['admin', 'tenants']) } },
}))

import { useQuery } from '@tanstack/react-query'
import TenantsPage from '@/pages/admin/tenants/TenantsPage'
import { renderWithAccess } from '@/auth/access/testing'

const REAL_RESPONSE = {
  items: [
    {
      id: '0f6c9d52-6a1e-4c7a-9a43-0d2d6a1b7c11',
      slug: 'live-co',
      display_name: 'Live Co',
      status: 'active',
      idp_realm_id: 'live-co-realm',
      login_disclosure_mode: null,
      tenant_type: 'production',
      inserted_at: '2026-03-05T10:00:00Z',
      updated_at: '2026-03-06T10:00:00Z',
    },
    {
      id: '7b1d2a90-1c3e-4f55-8e21-5a9b3c4d2e22',
      slug: 'idle-co',
      display_name: 'Idle Co',
      status: 'inactive',
      idp_realm_id: 'idle-co-realm',
      login_disclosure_mode: null,
      tenant_type: 'production',
      inserted_at: '2026-04-07T10:00:00Z',
      updated_at: '2026-04-08T10:00:00Z',
    },
  ],
  next_cursor: null,
  count: 2,
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('TenantsPage with the real API row shape', () => {
  it('shows Active vs Inactive per row and the Created date', () => {
    vi.mocked(useQuery).mockReturnValue({
      data: REAL_RESPONSE,
      isLoading: false,
      isError: false,
    } as unknown as ReturnType<typeof useQuery>)

    renderWithAccess(
      <MemoryRouter>
        <TenantsPage />
      </MemoryRouter>,
      'platformAdmin',
    )

    expect(screen.getByTestId('tenant-status-live-co')).toHaveTextContent('Active')
    expect(screen.getByTestId('tenant-status-idle-co')).toHaveTextContent('Inactive')
    expect(screen.getByTestId('tenant-deactivate-live-co')).toBeInTheDocument()
    expect(screen.getByTestId('tenant-reactivate-idle-co')).toBeInTheDocument()
    expect(screen.queryByTestId('tenant-reactivate-live-co')).not.toBeInTheDocument()

    const liveRow = screen.getByTestId('tenant-status-live-co').closest('tr')!
    const idleRow = screen.getByTestId('tenant-status-idle-co').closest('tr')!
    expect(liveRow.textContent).toMatch(/2026|05|Mar/)
    expect(idleRow.textContent).toMatch(/2026|07|Apr/)
    expect(liveRow.textContent).not.toEqual(idleRow.textContent)
    expect(liveRow.textContent).not.toContain('Invalid')
  })
})
