// @vitest-environment jsdom
/** T-1435 D1/D2: the dashboard of a role without DefinitionsRead (storekeeper) shows its working tiles and no
 *  no-access message, and sends no definitions request. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderWithAccess } from '@/auth/access/testing'
import TenantDashboardPage from '../TenantDashboardPage'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: { token: 'tok', display_name: 'U', loginSource: null, tenant_slug: 't', tenant_display_name: 'T Co', tenant_id: 'tid-1', tenant_type: 'production' },
  }),
}))
const m = vi.hoisted(() => ({ defs: vi.fn(), inst: vi.fn(), tasks: vi.fn() }))
vi.mock('@/api/definitions', () => ({ definitionsApi: { list: m.defs } }))
vi.mock('@/api/instances', () => ({ instancesApi: { list: m.inst } }))
vi.mock('@/api/tasks', () => ({ tasksApi: { list: m.tasks } }))

function renderDash(fixture: 'storekeeper' | 'tenantAdmin') {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <TenantDashboardPage />
    </QueryClientProvider>,
    fixture,
  )
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('T-1435 dashboard', () => {
  it('D1 without DefinitionsRead: no access text, tasks tile present, no definitions request', async () => {
    m.inst.mockResolvedValue({ items: [] })
    m.tasks.mockResolvedValue({ items: [{ id: 't1' }] })
    renderDash('storekeeper')
    expect(await screen.findByTestId('tile-tasks')).toBeInTheDocument()
    expect(screen.queryByText(/do not have access/i)).toBeNull()
    expect(screen.queryByTestId('tile-definitions')).toBeNull()
    expect(m.defs).not.toHaveBeenCalled()
  })

  it('D2 with DefinitionsRead: the definitions tile still renders', async () => {
    m.defs.mockResolvedValue({ items: [{ id: 'd1', name: 'Onboarding' }] })
    m.inst.mockResolvedValue({ items: [] })
    m.tasks.mockResolvedValue({ items: [] })
    renderDash('tenantAdmin')
    expect(await screen.findByText('Onboarding')).toBeInTheDocument()
    expect(screen.getByTestId('tile-definitions')).toBeInTheDocument()
  })
})
