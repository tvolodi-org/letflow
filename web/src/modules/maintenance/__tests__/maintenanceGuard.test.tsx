// @vitest-environment jsdom
/** GH 4802 / REQ-898 (AC5): the routes of the maintenance module render the not-found page where the module is
 *  not installed, and the screen itself where it is. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { REGISTERED_MODULE_ROUTE_OBJECTS } from '@/modules/registry'
import { WITH_ALL, fakeServer, type ClientMock } from './maintenanceTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-m' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const client = clientMock as unknown as ClientMock
const access: AccessState = WITH_ALL

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeServer(client)
})
afterEach(() => cleanup())

function Pages() {
  return useRoutes(REGISTERED_MODULE_ROUTE_OBJECTS)
}

function renderAt(path: string) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Pages />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

describe('AC5 the install guard', () => {
  it('the requests route is the not-found page where the module is not installed', async () => {
    fakeServer(client, { installed: [] })
    renderAt('/admin/maintenance/requests')
    await waitFor(() => expect(screen.getByTestId('not-found-page')).toBeInTheDocument())
  })

  it('the form of a request is the not-found page where the module is not installed', async () => {
    fakeServer(client, { installed: [] })
    renderAt('/admin/maintenance/requests/new')
    await waitFor(() => expect(screen.getByTestId('not-found-page')).toBeInTheDocument())
  })

  it('the request page is the not-found page where the module is not installed', async () => {
    fakeServer(client, { installed: [] })
    renderAt('/admin/maintenance/requests/r-1')
    await waitFor(() => expect(screen.getByTestId('not-found-page')).toBeInTheDocument())
  })

  it.each([
    '/admin/maintenance/orders',
    '/admin/maintenance/orders/new',
    '/admin/maintenance/orders/o-1',
    '/maintenance/my-orders',
  ])('REQ-899: %s is the not-found page where the module is not installed', async (path) => {
    fakeServer(client, { installed: [] })
    renderAt(path)
    await waitFor(() => expect(screen.getByTestId('not-found-page')).toBeInTheDocument())
  })

  it('the requests route renders the screen where the module is installed', async () => {
    renderAt('/admin/maintenance/requests')
    await waitFor(() => expect(screen.getByTestId('page-header')).toBeInTheDocument())
    expect(screen.queryByTestId('not-found-page')).not.toBeInTheDocument()
  })
})
