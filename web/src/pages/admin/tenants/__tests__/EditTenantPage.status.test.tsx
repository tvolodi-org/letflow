// @vitest-environment jsdom
/** T-2752: Edit Tenant has Deactivate / Reactivate (POST /tenants/:slug/deactivate|reactivate). */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

vi.mock('@/api/tenants', () => ({
  tenantsApi: { getBySlug: vi.fn(), patch: vi.fn(), deactivate: vi.fn(), reactivate: vi.fn() },
}))

import { tenantsApi } from '@/api/tenants'
import EditTenantPage from '@/pages/admin/tenants/EditTenantPage'
import { renderWithAccess } from '@/auth/access/testing'

const api = vi.mocked(tenantsApi)
const base = {
  slug: 'known-co', display_name: 'Known', idp_realm_id: 'known-realm', tenant_type: 'production' as const,
}

function mount(access: 'platformAdmin' | 'tenantAdmin' = 'platformAdmin') {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={['/admin/tenants/known-co/edit']}>
        <Routes>
          <Route path="/admin/tenants/:slug/edit" element={<EditTenantPage />} />
          <Route path="*" element={<div data-testid="elsewhere" />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
    access,
  )
}

afterEach(() => { cleanup(); vi.clearAllMocks() })

describe('EditTenantPage deactivate / reactivate', () => {
  it('deactivates after confirmation and shows the new status', async () => {
    api.getBySlug.mockResolvedValueOnce({ ...base, status: 'active' })
    api.getBySlug.mockResolvedValue({ ...base, status: 'inactive' })
    api.deactivate.mockResolvedValue({ ...base, status: 'inactive' })
    mount()
    const btn = await screen.findByText('Deactivate')
    fireEvent.click(btn)
    expect(api.deactivate).not.toHaveBeenCalled()
    const confirm = await screen.findAllByText('Deactivate')
    fireEvent.click(confirm[confirm.length - 1])
    await waitFor(() => expect(api.deactivate).toHaveBeenCalledWith('known-co'))
    await waitFor(() => expect(screen.getByTestId('edit-tenant-status')).toHaveTextContent('inactive'))
    expect(screen.getByText('Reactivate')).toBeInTheDocument()
  })

  it('offers Reactivate for an inactive tenant and calls the API', async () => {
    api.getBySlug.mockResolvedValue({ ...base, status: 'inactive' })
    api.reactivate.mockResolvedValue({ ...base, status: 'active' })
    mount()
    fireEvent.click(await screen.findByText('Reactivate'))
    const confirm = await screen.findAllByText('Reactivate')
    fireEvent.click(confirm[confirm.length - 1])
    await waitFor(() => expect(api.reactivate).toHaveBeenCalledWith('known-co'))
  })

  it('hides the button without TenantsManage', async () => {
    api.getBySlug.mockResolvedValue({ ...base, status: 'active' })
    mount('tenantAdmin')
    await waitFor(() => expect(screen.getByTestId('elsewhere')).toBeInTheDocument())
    expect(screen.queryByText('Deactivate')).not.toBeInTheDocument()
  })
})
