// @vitest-environment jsdom
/** C1 — GH 3769 / REQ-722: the stock document routes and nav item, the install guard and the permission guard. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { UserSession } from '@/types/api'
import type { AccessState } from '@/auth/access/types'
import { withAtom, withoutAtom } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/hooks/useInstalledModules', () => ({ useInstalledModules: vi.fn() }))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(async () => ({ rows: [], next_cursor: null })) }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const session: UserSession = {
  token: 'tok',
  display_name: 'Test User',
  loginSource: null,
  tenant_slug: 'fixture-tenant',
  tenant_display_name: 'Fixture Tenant',
  tenant_id: 'tid-fixture',
  tenant_type: 'production',
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

async function mockEnv(installed: { module_id: string; version: string }[]) {
  const { useAuth } = await import('@/auth/AuthContext')
  const { useInstalledModules } = await import('@/hooks/useInstalledModules')
  vi.mocked(useAuth).mockReturnValue({
    session, isAuthenticated: true, isLoading: false, loginSource: null, login: vi.fn(), logout: vi.fn(),
    setSession: vi.fn(), switchTenant: vi.fn(), switchingToTenantSlug: null,
  })
  vi.mocked(useInstalledModules).mockReturnValue({ data: installed, isLoading: false } as never)
}

async function renderShell(access: AccessState, installed: { module_id: string; version: string }[]) {
  await mockEnv(installed)
  const { BrandingProvider } = await import('@/theming/BrandingProvider')
  const { AppShell } = await import('@/components/layout/AppShell')
  const { AccessStateProvider } = await import('@/auth/access/AccessContext')
  render(
    <QueryClientProvider client={new QueryClient()}>
      <MemoryRouter initialEntries={['/instances']}>
        <BrandingProvider>
          <AccessStateProvider state={access}>
            <AppShell />
          </AccessStateProvider>
        </BrandingProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

async function renderRegistryAt(path: string, access: AccessState, installed: { module_id: string; version: string }[]) {
  await mockEnv(installed)
  clientMock.post.mockResolvedValue({ items: [], next_cursor: null })
  const { REGISTERED_MODULE_ROUTE_OBJECTS } = await import('@/modules/registry')
  const { AccessStateProvider } = await import('@/auth/access/AccessContext')
  function Routes() {
    return useRoutes(REGISTERED_MODULE_ROUTE_OBJECTS)
  }
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

const STK = [{ module_id: 'stock', version: '1.0.0' }]
const DOC_LIST = '/admin/stock/documents'
const PATHS = [DOC_LIST, `${DOC_LIST}/new`, `${DOC_LIST}/d1`]

describe('C1-a definition', () => {
  it('has the three document routes and the Stock documents nav item on StockRead', async () => {
    const { stockModuleDefinition } = await import('../index')
    const paths = stockModuleDefinition.routeObjects.map((r) => r.path)
    expect(paths).toEqual(expect.arrayContaining(['admin/stock/documents', 'admin/stock/documents/new', 'admin/stock/documents/:id']))
    expect(paths.indexOf('admin/stock/documents/new')).toBeLessThan(paths.indexOf('admin/stock/documents/:id'))
    expect(stockModuleDefinition.navItems).toContainEqual({ to: DOC_LIST, label: 'Stock documents', permission: 'StockRead' })
  })
})

describe('C1-b nav and guards', () => {
  it('shows the link with the atom when installed, none without the atom or the module', async () => {
    await renderShell(withAtom, STK)
    await waitFor(() => expect(screen.getByRole('link', { name: 'Stock documents' })).toHaveAttribute('href', DOC_LIST))
    cleanup()
    await renderShell(withoutAtom, STK)
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    expect(screen.queryByRole('link', { name: 'Stock documents' })).not.toBeInTheDocument()
    cleanup()
    await renderShell(withAtom, [])
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    expect(screen.queryByRole('link', { name: 'Stock documents' })).not.toBeInTheDocument()
  })

  for (const path of PATHS) {
    it(`${path} is not found when stock is not installed`, async () => {
      await renderRegistryAt(path, withAtom, [])
      await waitFor(() => expect(screen.getByTestId('not-found-page')).toBeInTheDocument())
    })
    it(`${path} shows the forbidden page without the atom and sends no request`, async () => {
      clientMock.get.mockClear()
      await renderRegistryAt(path, withoutAtom, STK)
      expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
      expect(clientMock.get).not.toHaveBeenCalled()
    })
  }
})
