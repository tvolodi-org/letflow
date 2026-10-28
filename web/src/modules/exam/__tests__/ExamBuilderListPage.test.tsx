// @vitest-environment jsdom
/**
 * GH 3355 / REQ-602 — the exam builder list page, the BilimBagaAdminPage link (N1) and the route guard.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useLocation, useRoutes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'
import type { AccessState } from '@/auth/access/types'
import BilimBagaAdminPage from '../BilimBagaAdminPage'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-list' }, isAuthenticated: true }),
}))

const clientMock = vi.hoisted(() => ({ post: vi.fn(), putWithHeaders: vi.fn(), delete: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

import { examRouteObjects } from '../examRoutes'

const writer: AccessState = { status: 'ready', info: ACCESS_FIXTURES.tenantAdmin }
const reader: AccessState = {
  status: 'ready',
  info: {
    ...ACCESS_FIXTURES.tenantAdmin,
    permissions: ACCESS_FIXTURES.tenantAdmin.permissions.filter((p) => p !== 'ExamAuthoringWrite'),
  },
}

function Routes() {
  return useRoutes(examRouteObjects)
}
function Where() {
  return <span data-testid="where">{useLocation().pathname}</span>
}

function renderAt(path: string, access: AccessState = writer) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
          <Where />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  clientMock.post.mockReset()
})
afterEach(() => cleanup())

describe('list page', () => {
  it('lists exams as links to the builder', async () => {
    clientMock.post.mockResolvedValue({
      items: [{ record_id: 'e-1', field_values: { title: { en: 'Safety exam' } } }],
      next_cursor: null,
    })
    renderAt('/admin/bilimbaga/exam-builder')
    const link = await screen.findByRole('link', { name: 'Safety exam' })
    expect(link).toHaveAttribute('href', '/admin/bilimbaga/exam-builder/e-1')
    expect(clientMock.post.mock.calls[0][1]).toMatchObject({ entity_type: 'exam' })
  })

  it('Create exam posts a default exam through the authoring route and opens it', async () => {
    clientMock.post.mockImplementation(async (path: string) =>
      path === '/api/v1/entities/query'
        ? { items: [], next_cursor: null }
        : { record_id: 'created-id', field_values: {} },
    )
    renderAt('/admin/bilimbaga/exam-builder')
    fireEvent.click(await screen.findByTestId('exam-builder-create'))
    await waitFor(() => expect(screen.getByTestId('where')).toHaveTextContent('/admin/bilimbaga/exam-builder/created-id'))
    const [path, body] = clientMock.post.mock.calls.find(([p]) => p !== '/api/v1/entities/query') as [string, { field_values: Record<string, unknown> }]
    expect(path).toBe('/api/v1/modules/exam/authoring/exam')
    expect(body.field_values).toMatchObject({ status: 'draft', max_attempts: 1 })
  })

  it('shows the forbidden state without ExamAuthoringWrite and sends no request', async () => {
    renderAt('/admin/bilimbaga/exam-builder', reader)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    expect(clientMock.post).not.toHaveBeenCalled()
  })
})

describe('N1 BilimBagaAdminPage link', () => {
  function renderAdmin(access?: AccessState) {
    const page = (
      <MemoryRouter>
        <BilimBagaAdminPage />
      </MemoryRouter>
    )
    return render(access ? <AccessStateProvider state={access}>{page}</AccessStateProvider> : page)
  }

  it('shows one link to the builder for a holder of ExamAuthoringWrite', () => {
    renderAdmin(writer)
    expect(screen.getByTestId('bilimbaga-nav-exam-builder')).toHaveAttribute('href', '/admin/bilimbaga/exam-builder')
  })

  it('hides it without the permission and without any access provider', () => {
    renderAdmin(reader)
    expect(screen.queryByTestId('bilimbaga-nav-exam-builder')).not.toBeInTheDocument()
    cleanup()
    renderAdmin()
    expect(screen.queryByTestId('bilimbaga-nav-exam-builder')).not.toBeInTheDocument()
  })
})
