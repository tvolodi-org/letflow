// @vitest-environment jsdom
/** M1, M2, M3 — GH 3609 / REQ-669: the module definition, nav items, install guard and permission guard. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { UserSession } from '@/types/api'
import type { AccessState } from '@/auth/access/types'
import { withAtom, withoutAtom } from './orgTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/hooks/useInstalledModules', () => ({ useInstalledModules: vi.fn() }))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(async () => ({ items: [] })) }))
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

const ORG = [{ module_id: 'org', version: '1.0.0' }]
const LINKS: [string, string][] = [
  ['Legal companies', '/admin/org/legal-entities'],
  ['Sites', '/admin/org/sites'],
  ['Org units', '/admin/org/units'],
]

describe('M1 definition and nav', () => {
  it('is registered with three nav items on OrgStructureWrite', async () => {
    const { orgModuleDefinition } = await import('../index')
    const { REGISTERED_MODULES } = await import('@/modules/registry')
    expect(REGISTERED_MODULES.map((m) => m.id)).toContain('org')
    expect(orgModuleDefinition.id).toBe('org')
    expect(orgModuleDefinition.navItems.map((n) => [n.label, n.to, n.permission])).toEqual(
      LINKS.map(([l, to]) => [l, to, 'OrgStructureWrite']),
    )
  })

  it('shows the three links to a holder of the atom when org is installed', async () => {
    await renderShell(withAtom, ORG)
    for (const [name, href] of LINKS) {
      await waitFor(() => expect(screen.getByRole('link', { name })).toHaveAttribute('href', href))
    }
  })

  it('shows no org link without the atom or without the module installed', async () => {
    await renderShell(withoutAtom, ORG)
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    for (const [name] of LINKS) expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
    cleanup()
    await renderShell(withAtom, [])
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    for (const [name] of LINKS) expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
  })
})

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

describe('M2 install guard', () => {
  for (const [, path] of LINKS) {
    it(`${path} is not found when org is not installed`, async () => {
      await renderRegistryAt(path, withAtom, [])
      await waitFor(() => expect(screen.getByTestId('not-found-page')).toBeInTheDocument())
    })
  }
})

describe('M3 permission guard', () => {
  for (const [, path] of LINKS) {
    it(`${path} shows the forbidden page without the atom and sends no request`, async () => {
      clientMock.post.mockReset()
      await renderRegistryAt(path, withoutAtom, ORG)
      expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
      expect(clientMock.post).not.toHaveBeenCalledWith('/api/v1/entities/query', expect.anything())
    })
  }
})
