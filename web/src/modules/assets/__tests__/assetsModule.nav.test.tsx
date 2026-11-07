// @vitest-environment jsdom
/** M1–M4 — T-1333 / C13, T-1334 / C14 (N1): the module definition, nav items, install guard and permission guard. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { UserSession } from '@/types/api'
import type { AccessState } from '@/auth/access/types'
import { withoutAtom } from './assetsTestKit'

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

const withAtom: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['AssetsCardWrite', 'AssetsRead'] },
}
const onlyCardWrite: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['AssetsCardWrite'] },
}
const LOC = [{ module_id: 'assets', version: '1.0.0' }]
/** label, path, the atom the nav item and the route need. */
const LINKS: [string, string, string][] = [
  ['Asset cards', '/admin/assets/cards', 'AssetsCardWrite'],
  ['Asset documents', '/admin/assets/documents', 'AssetsRead'],
  ['Asset balances', '/admin/assets/balances', 'AssetsRead'],
  ['Asset movements', '/admin/assets/movements', 'AssetsRead'],
]

describe('M1 definition', () => {
  it('is registered with the card item on AssetsCardWrite and the three register items on AssetsRead (N1)', async () => {
    const { assetsModuleDefinition } = await import('../index')
    const { REGISTERED_MODULES } = await import('@/modules/registry')
    expect(REGISTERED_MODULES.map((m) => m.id)).toContain('assets')
    expect(assetsModuleDefinition.id).toBe('assets')
    expect(assetsModuleDefinition.navItems.map((n) => [n.label, n.to, n.permission])).toEqual(
      LINKS.map(([l, to, atom]) => [l, to, atom]),
    )
  })
})

describe('M2 nav', () => {
  it('shows only the card link with AssetsCardWrite alone (N1)', async () => {
    await renderShell(onlyCardWrite, LOC)
    await waitFor(() => expect(screen.getByRole('link', { name: 'Asset cards' })).toBeInTheDocument())
    for (const [name] of LINKS.slice(1)) expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
  })

  it('shows the link with the atom when assets is installed', async () => {
    await renderShell(withAtom, LOC)
    for (const [name, href] of LINKS) {
      await waitFor(() => expect(screen.getByRole('link', { name })).toHaveAttribute('href', href))
    }
  })

  it('shows no link without the atom or without the module installed', async () => {
    await renderShell(withoutAtom, LOC)
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

describe('M3 install guard', () => {
  for (const [, path] of LINKS) {
    it(`${path} is not found when assets is not installed`, async () => {
      await renderRegistryAt(path, withAtom, [])
      await waitFor(() => expect(screen.getByTestId('not-found-page')).toBeInTheDocument())
    })
  }
})

describe('M4 permission guard', () => {
  for (const [, path] of LINKS) {
    it(`${path} shows the forbidden page without the atom and sends no request`, async () => {
      clientMock.post.mockReset()
      await renderRegistryAt(path, withoutAtom, LOC)
      expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
      expect(clientMock.post).not.toHaveBeenCalledWith('/api/v1/entities/query', expect.anything())
    })
  }
})
