// @vitest-environment jsdom
/**
 * T-1874 — ReportsIndexPage (the Reports menu entry).
 *  P1 grouped by module   P2 link opens the report screen (deep link)   P3 localized name
 *  P4 shows only what the server returned   P5 loading / error / retry   P6 route guard
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { P, RequirePermission } from '@/auth/access'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import type { ReportView } from '@/types/api'
import { ReportsIndexPage } from '../ReportsIndexPage'
import { ReportBuilderPage } from '../ReportBuilderPage'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: { token: 'tok', display_name: 'T', loginSource: null, tenant_slug: 'fx', tenant_display_name: 'Fx', tenant_id: 'tid-fx', tenant_type: 'production' },
    isAuthenticated: true,
    logout: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  }),
}))
vi.mock('@/api/entityViews', () => ({
  reportViewsApi: { list: vi.fn(), listAll: vi.fn(), get: vi.fn(), create: vi.fn(), update: vi.fn(), remove: vi.fn() },
}))
vi.mock('@/api/entities', () => ({
  entitiesApi: { getActiveDefinition: vi.fn(), aggregateRecords: vi.fn(), queryRecords: vi.fn() },
}))
vi.mock('@/api/me', () => ({
  meApi: { listInstalledModules: vi.fn() },
}))

import { reportViewsApi } from '@/api/entityViews'
import { entitiesApi } from '@/api/entities'
import { meApi } from '@/api/me'

const api = vi.mocked(reportViewsApi)
const me = vi.mocked(meApi)

const mk = (id: string, entity_type: string, name: string): ReportView => ({
  id, entity_type, name, kind: 'report', columns: [], filter: [], sort: [], group_by: [], aggregates: [{ fn: 'count' }],
})
const ASSET_LIST = mk('r1', 'assets_card', 'Asset list')
const COMMISSION = mk('r2', 'assets_commission', 'Commissions per month')
const CORE = mk('r3', 'orders', 'Totals')

function renderAt(path: string, access = accessState('tenantAdmin')) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes>
            <Route path="/reports" element={<RequirePermission permission={P.EntitiesQuery}><ReportsIndexPage /></RequirePermission>} />
            <Route path="/entities/:entityType/reports" element={<ReportBuilderPage />} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  useUiLocaleStore.setState({ choice: 'en' })
  me.listInstalledModules.mockResolvedValue({ installed_modules: [{ module_id: 'assets', version: '1' }] } as never)
  api.listAll.mockResolvedValue({ items: [CORE, COMMISSION, ASSET_LIST] })
  api.list.mockResolvedValue({ items: [] })
  api.get.mockResolvedValue(ASSET_LIST)
  vi.mocked(entitiesApi.getActiveDefinition).mockRejectedValue(Object.assign(new Error('x'), { status: 404 }))
})
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  useUiLocaleStore.setState({ choice: null })
})

describe('T-1874 ReportsIndexPage', () => {
  it('P1 groups reports by module, other reports last', async () => {
    renderAt('/reports')
    const groups = await screen.findAllByTestId('reports-index-group')
    expect(groups.map((g) => g.getAttribute('aria-label'))).toEqual(['Assets', 'Other reports'])
    expect(within(groups[0]).getAllByRole('link').map((l) => l.textContent)).toEqual(['Asset list', 'Commissions per month'])
    expect(within(groups[1]).getAllByRole('link').map((l) => l.textContent)).toEqual(['Totals'])
  })

  it('P1 a module that is not installed claims nothing: everything is in Other reports', async () => {
    me.listInstalledModules.mockResolvedValue({ installed_modules: [] } as never)
    renderAt('/reports')
    const groups = await screen.findAllByTestId('reports-index-group')
    expect(groups.map((g) => g.getAttribute('aria-label'))).toEqual(['Other reports'])
  })

  it('P2 a link points at the report screen and opening it loads that report', async () => {
    renderAt('/reports')
    const link = await screen.findByTestId('reports-index-link-r1')
    expect(link.getAttribute('href')).toBe('/entities/assets_card/reports?open=r1')
    fireEvent.click(link)
    await waitFor(() => expect(api.get).toHaveBeenCalledWith('r1'))
    expect(api.get).toHaveBeenCalledTimes(1)
    expect(await screen.findByTestId('report-run-panel')).toBeInTheDocument()
  })

  it('P3 the shipped name is localized (ru, kk); a tenant-made name is not', async () => {
    useUiLocaleStore.setState({ choice: 'ru' })
    const ru = renderAt('/reports')
    expect(await screen.findByText('Список активов')).toBeInTheDocument()
    expect(screen.getByText('Commissions per month')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Отчёты' })).toBeInTheDocument()
    ru.unmount()
    useUiLocaleStore.setState({ choice: 'kk' })
    renderAt('/reports')
    expect(await screen.findByText('Активтер тізімі')).toBeInTheDocument()
  })

  it('P4 shows only what the server returned: an empty answer shows the empty state', async () => {
    api.listAll.mockResolvedValue({ items: [] })
    renderAt('/reports')
    expect(await screen.findByTestId('reports-index-empty')).toBeInTheDocument()
    expect(screen.queryByText(/asset/i)).toBeNull()
    expect(screen.queryAllByTestId('reports-index-group')).toHaveLength(0)
  })

  it('P5 loading, error and retry', async () => {
    let resolve: (v: { items: ReportView[] }) => void = () => undefined
    api.listAll.mockImplementationOnce(() => new Promise((r) => { resolve = r }))
    renderAt('/reports')
    expect(await screen.findByTestId('reports-index-loading')).toBeInTheDocument()
    await act(async () => resolve({ items: [CORE] }))
    expect(await screen.findByText('Totals')).toBeInTheDocument()
    cleanup()

    api.listAll.mockRejectedValueOnce(Object.assign(new Error('boom'), { status: 500 }))
    renderAt('/reports')
    const retry = await screen.findByRole('button', { name: /retry/i })
    fireEvent.click(retry)
    expect(await screen.findByText('Totals')).toBeInTheDocument()
    expect(api.listAll).toHaveBeenCalledTimes(3)
  })

  it('P6 without EntitiesQuery the route shows no list and makes no request', async () => {
    const base = accessState('tenantAdmin')
    if (base.status !== 'ready') throw new Error('fixture not ready')
    const noQuery = { status: 'ready', info: { ...base.info, permissions: base.info.permissions.filter((p) => p !== P.EntitiesQuery) } } as typeof base
    renderAt('/reports', noQuery)
    await waitFor(() => expect(screen.queryByTestId('reports-index-group')).toBeNull())
    expect(api.listAll).not.toHaveBeenCalled()
  })
})
