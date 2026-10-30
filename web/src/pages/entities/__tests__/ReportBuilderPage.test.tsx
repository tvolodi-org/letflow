// @vitest-environment jsdom
/**
 * REQ-634 part A — ReportBuilderPage (list, create, edit, delete).
 *
 *   B1 create sends one create call   B2 no aggregate: field message, no request
 *   B3 edit sends one update          B4/B5 delete confirm / cancel
 *   B6 save errors 400/403/404/409/422 (role=alert, input kept, 422 mapped through i18n)
 *   B7 network failure: generic message and retry
 *   B8 404 on open                    B9 no EntitiesViewsManage: no controls
 *   B10 empty list                    B11 loading and double submit
 *   B12 sort without columns is blocked
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { P } from '@/auth/access'
import type { AccessState } from '@/auth/access'
import type { ReportView } from '@/types/api'
import { ReportBuilderPage } from '../ReportBuilderPage'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: null,
      tenant_slug: 'fixture-co',
      tenant_display_name: 'Fixture Co',
      tenant_id: 'tid-fixture-co',
      tenant_type: 'production',
    },
    logout: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  }),
}))

vi.mock('@/api/entityViews', () => ({
  reportViewsApi: {
    list: vi.fn(),
    get: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    remove: vi.fn(),
  },
}))

vi.mock('@/api/entities', () => ({
  entitiesApi: { getActiveDefinition: vi.fn() },
}))

import { reportViewsApi } from '@/api/entityViews'
import { entitiesApi } from '@/api/entities'

const api = vi.mocked(reportViewsApi)
const defs = vi.mocked(entitiesApi)

const REPORT: ReportView = {
  id: 'r1',
  entity_type: 'orders',
  name: 'Totals',
  kind: 'report',
  columns: ['status'],
  filter: [],
  sort: [{ field: 'status', dir: 'asc' }],
  group_by: [{ field: 'status' }],
  aggregates: [{ fn: 'sum', field: 'total' }],
}

function accessWith(extra: string[]): AccessState {
  const s = accessState('tenantAdmin')
  if (s.status !== 'ready') throw new Error('fixture not ready')
  const base = s.info.permissions.filter((p) => p !== P.EntitiesViewsManage)
  return { status: 'ready', info: { ...s.info, permissions: [...base, ...extra] } }
}
const MANAGE = accessWith([P.EntitiesViewsManage])
const READ_ONLY = accessWith([])

function renderPage(access: AccessState = MANAGE) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={['/entities/orders/reports']}>
          <Routes>
            <Route path="/entities/:entityType/reports" element={<ReportBuilderPage />} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

const apiError = (status: number, detail?: string) =>
  Object.assign(new Error('x'), { status, details: detail ? { detail } : {} })

const alerts = () => screen.queryAllByRole('alert').map((a) => a.textContent ?? '')

async function openNew() {
  fireEvent.click(await screen.findByTestId('report-new'))
  return screen.findByLabelText('Report name')
}

function fillValid() {
  fireEvent.change(screen.getByLabelText('Report name'), { target: { value: 'Totals' } })
  fireEvent.change(screen.getByTestId('report-agg-fn-0'), { target: { value: 'sum' } })
  fireEvent.change(screen.getByTestId('report-agg-field-0'), { target: { value: 'total' } })
}

async function openExisting() {
  fireEvent.click(await screen.findByTestId('report-open-r1'))
  return screen.findByLabelText('Report name')
}

beforeEach(() => {
  api.list.mockResolvedValue({ items: [REPORT] })
  api.get.mockResolvedValue(REPORT)
  api.create.mockResolvedValue(REPORT)
  api.update.mockResolvedValue(REPORT)
  api.remove.mockResolvedValue(undefined)
  defs.getActiveDefinition.mockRejectedValue(apiError(404))
})
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-634 ReportBuilderPage', () => {
  it('B1 create sends one create call with the draft', async () => {
    api.list.mockResolvedValue({ items: [] })
    renderPage()
    await openNew()
    fillValid()
    fireEvent.change(screen.getByLabelText('Columns'), { target: { value: 'status, total' } })
    fireEvent.click(screen.getByTestId('report-group-add'))
    fireEvent.change(screen.getByTestId('report-group-0'), { target: { value: 'status' } })
    fireEvent.change(screen.getByLabelText('Sort by', { selector: 'input' }), { target: { value: 'status' } })
    fireEvent.click(screen.getByTestId('report-save'))
    await waitFor(() => expect(api.create).toHaveBeenCalledTimes(1))
    expect(api.create).toHaveBeenCalledWith({
      entity_type: 'orders',
      name: 'Totals',
      filter: [],
      group_by: [{ field: 'status' }],
      aggregates: [{ fn: 'sum', field: 'total' }],
      columns: ['status', 'total'],
      sort: [{ field: 'status', dir: 'asc' }],
    })
    expect(api.update).not.toHaveBeenCalled()
  })

  it('B2 save without an aggregate shows a field message and sends nothing', async () => {
    renderPage()
    await openNew()
    fireEvent.change(screen.getByLabelText('Report name'), { target: { value: 'Totals' } })
    fireEvent.click(screen.getByText('Remove aggregate'))
    fireEvent.click(screen.getByTestId('report-save'))
    expect(await screen.findByTestId('report-aggregates-error')).toHaveAttribute('role', 'alert')
    expect(api.create).not.toHaveBeenCalled()
  })

  it('B3 edit opens with one get and saves with one update without kind', async () => {
    renderPage()
    await openExisting()
    expect(api.get).toHaveBeenCalledTimes(1)
    expect(api.get).toHaveBeenCalledWith('r1')
    fireEvent.change(screen.getByLabelText('Report name'), { target: { value: 'Totals 2' } })
    fireEvent.click(screen.getByTestId('report-save'))
    await waitFor(() => expect(api.update).toHaveBeenCalledTimes(1))
    const [id, body] = api.update.mock.calls[0]
    expect(id).toBe('r1')
    expect(body).toEqual({
      name: 'Totals 2',
      filter: [],
      group_by: [{ field: 'status' }],
      aggregates: [{ fn: 'sum', field: 'total' }],
      columns: ['status'],
      sort: [{ field: 'status', dir: 'asc' }],
    })
    expect('kind' in body).toBe(false)
    expect(api.create).not.toHaveBeenCalled()
  })

  it('B4 delete confirms then sends one remove', async () => {
    renderPage()
    await openExisting()
    fireEvent.click(screen.getByTestId('report-delete'))
    expect(api.remove).not.toHaveBeenCalled()
    const dialog = await screen.findByRole('dialog')
    fireEvent.click(within(dialog).getByText('Delete'))
    await waitFor(() => expect(api.remove).toHaveBeenCalledTimes(1))
    expect(api.remove).toHaveBeenCalledWith('r1')
    await waitFor(() => expect(screen.queryByTestId('report-editor')).not.toBeInTheDocument())
  })

  it('B5 cancelling the confirmation sends no remove', async () => {
    renderPage()
    await openExisting()
    fireEvent.click(screen.getByTestId('report-delete'))
    const dialog = await screen.findByRole('dialog')
    fireEvent.click(within(dialog).getByText('Cancel'))
    expect(api.remove).not.toHaveBeenCalled()
  })

  it.each([
    [400, undefined, 'The request was not understood'],
    [403, undefined, 'You are not allowed'],
    [404, undefined, 'The report or entity type was not found'],
    [409, undefined, 'A report with this name already exists'],
    [422, 'aggregates_invalid', 'The aggregates are not valid'],
    [422, 'brand_new_code', 'The report is not valid. Check it'],
  ])('B6 save error %s %s shows an alert and keeps the input', async (status, detail, text) => {
    api.update.mockRejectedValue(apiError(status, detail))
    renderPage()
    await openExisting()
    fireEvent.change(screen.getByLabelText('Report name'), { target: { value: 'Keep me' } })
    fireEvent.click(screen.getByTestId('report-save'))
    const alert = await screen.findByTestId('report-error')
    expect(alert).toHaveAttribute('role', 'alert')
    expect(alert.textContent).toContain(text)
    expect(screen.getByLabelText('Report name')).toHaveValue('Keep me')
    expect(screen.queryByTestId('report-retry')).not.toBeInTheDocument()
  })

  it('B7 network failure shows the generic message and Retry re-sends once', async () => {
    api.update.mockRejectedValueOnce(new TypeError('Failed to fetch'))
    renderPage()
    await openExisting()
    fireEvent.change(screen.getByLabelText('Report name'), { target: { value: 'Keep me' } })
    fireEvent.click(screen.getByTestId('report-save'))
    expect((await screen.findByTestId('report-error')).textContent).toContain('The server could not be reached')
    expect(screen.getByLabelText('Report name')).toHaveValue('Keep me')
    fireEvent.click(screen.getByTestId('report-retry'))
    await waitFor(() => expect(api.update).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(screen.queryByTestId('report-error')).not.toBeInTheDocument())
    expect(api.update.mock.calls[1][1].name).toBe('Keep me')
  })

  it('B8 404 on open shows not-found and keeps the list', async () => {
    api.get.mockRejectedValue(apiError(404))
    renderPage()
    fireEvent.click(await screen.findByTestId('report-open-r1'))
    expect(await screen.findByTestId('report-not-found')).toBeInTheDocument()
    expect(screen.queryByTestId('report-editor')).not.toBeInTheDocument()
    expect(screen.getByTestId('report-open-r1')).toBeInTheDocument()
  })

  it('B9 without EntitiesViewsManage no create, save or delete control is rendered', async () => {
    renderPage(READ_ONLY)
    await openExisting()
    expect(screen.getByTestId('report-readonly')).toBeInTheDocument()
    expect(screen.queryByTestId('report-new')).not.toBeInTheDocument()
    expect(screen.queryByTestId('report-save')).not.toBeInTheDocument()
    expect(screen.queryByTestId('report-delete')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Report name')).toBeDisabled()
  })

  it('B10 empty list shows the empty state; the create control needs EntitiesViewsManage', async () => {
    api.list.mockResolvedValue({ items: [] })
    const first = renderPage()
    expect(await screen.findByTestId('reports-empty')).toBeInTheDocument()
    expect(screen.getByTestId('report-empty-create')).toBeInTheDocument()
    first.unmount()
    renderPage(READ_ONLY)
    expect(await screen.findByTestId('reports-empty')).toBeInTheDocument()
    expect(screen.queryByTestId('report-empty-create')).not.toBeInTheDocument()
  })

  it('B11 loading state shows while the list is pending', async () => {
    api.list.mockReturnValue(new Promise(() => {}))
    renderPage()
    expect(await screen.findByTestId('reports-loading')).toBeInTheDocument()
  })

  it('B11 a second submission while create is pending makes one call', async () => {
    let release: (v: ReportView) => void = () => {}
    api.create.mockReturnValue(new Promise<ReportView>((r) => (release = r)))
    renderPage()
    await openNew()
    fillValid()
    const save = screen.getByTestId('report-save')
    fireEvent.click(save)
    fireEvent.click(save)
    expect(api.create).toHaveBeenCalledTimes(1)
    expect(save).toBeDisabled()
    await act(async () => release(REPORT))
    await waitFor(() => expect(save).not.toBeDisabled())
    expect(api.create).toHaveBeenCalledTimes(1)
  })

  it('B11 opening a report shows a loading state and blocks the list', async () => {
    let release: (v: ReportView) => void = () => {}
    api.get.mockReturnValue(new Promise<ReportView>((r) => (release = r)))
    renderPage()
    fireEvent.click(await screen.findByTestId('report-open-r1'))
    expect(await screen.findByTestId('report-opening')).toBeInTheDocument()
    expect(screen.getByTestId('report-open-r1')).toBeDisabled()
    await act(async () => release(REPORT))
    expect(await screen.findByLabelText('Report name')).toHaveValue('Totals')
  })

  it('B12 a sort without columns is blocked with a field message', async () => {
    renderPage()
    await openNew()
    fillValid()
    fireEvent.change(screen.getByLabelText('Sort by', { selector: 'input' }), { target: { value: 'status' } })
    fireEvent.click(screen.getByTestId('report-save'))
    expect(await screen.findByTestId('report-sort-error')).toHaveAttribute('role', 'alert')
    expect(api.create).not.toHaveBeenCalled()
    expect(alerts().length).toBeGreaterThan(0)
  })
})
