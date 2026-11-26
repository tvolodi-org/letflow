// @vitest-environment jsdom
/** GH 4802 / REQ-898 (CMMS slice 1 part 6): the work request screens of the maintenance module.
 *
 *  AC1 — the card action "Report a problem" (the assets module opens the form of a request).
 *  AC4 — the list and the request page: the columns, the status filter, the actions and the reject.
 *  AC5 — the routes render the not-found page where the module is not installed.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { AssetCardActionsMenu } from '@/modules/assets/AssetCardActionsMenu'
import { AssetsIntlProvider } from '@/modules/assets/AssetsIntlProvider'
import {
  API,
  WITH_ALL,
  WITH_MANAGE,
  fakeServer,
  rec,
  renderMaintenance,
  request,
  type ClientMock,
} from './maintenanceTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-m' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const client = clientMock as unknown as ClientMock

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeServer(client)
})
afterEach(() => cleanup())

const card = rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Press machine', kind: 'fixed' })
const retiredCard = rec('c-9', 'assets_card', { inventory_number: 'FA-9', name: 'Old press', kind: 'fixed', active: false })

function renderMenu(c: typeof card, access: AccessState) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <AccessStateProvider state={access}>
        <MemoryRouter>
          <AssetsIntlProvider>
            <AssetCardActionsMenu card={c} initialOpen />
          </AssetsIntlProvider>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

describe('AC1 the card action "Report a problem"', () => {
  const withPermission: AccessState = {
    status: 'ready',
    info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsPost', 'MaintenanceRequestCreate'] },
  }
  const withoutPermission: AccessState = {
    status: 'ready',
    info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsPost'] },
  }

  it('is on an active card when the module is installed and the caller may report', async () => {
    renderMenu(card, withPermission)
    const action = await screen.findByTestId('card-action-reportProblem')
    expect(action).toHaveAttribute('href', '/admin/maintenance/requests/new?card=c-1')
    expect(action).toHaveTextContent('Report a problem')
  })

  it('is absent when the module is not installed', async () => {
    fakeServer(client, { installed: ['assets'] })
    renderMenu(card, withPermission)
    await waitFor(() => expect(screen.getByTestId('card-actions-panel-c-1')).toBeInTheDocument())
    expect(screen.queryByTestId('card-action-reportProblem')).not.toBeInTheDocument()
  })

  it('is absent without the permission', async () => {
    renderMenu(card, withoutPermission)
    await waitFor(() => expect(screen.getByTestId('card-actions-panel-c-1')).toBeInTheDocument())
    expect(screen.queryByTestId('card-action-reportProblem')).not.toBeInTheDocument()
  })

  it('is absent on a retired card', async () => {
    renderMenu(retiredCard, withPermission)
    await waitFor(() => expect(screen.getByTestId('card-actions-panel-c-9')).toBeInTheDocument())
    expect(screen.queryByTestId('card-action-reportProblem')).not.toBeInTheDocument()
  })
})

describe('AC4 the list and the request page', () => {
  it('the list shows the number, the equipment, the urgency and the status', async () => {
    renderMaintenance('/admin/maintenance/requests')
    const row = await screen.findByTestId('request-row-asset-r-1')
    expect(row).toHaveTextContent('FA-1')
    expect(row).toHaveTextContent('Press machine')
    expect(await screen.findByText('WR-2026-000001')).toBeInTheDocument()
    expect(await screen.findByTestId('request-row-status-r-1')).toHaveTextContent('New')
    expect(await screen.findByText('Normal')).toBeInTheDocument()
  })

  it('the status filter sends status=rejected', async () => {
    renderMaintenance('/admin/maintenance/requests')
    await screen.findByText('WR-2026-000001')
    fireEvent.change(screen.getByLabelText('Status'), { target: { value: 'rejected' } })
    await waitFor(() =>
      expect(clientMock.get.mock.calls.some(([p]) => String(p).includes('status=rejected'))).toBe(true),
    )
  })

  it('the request page shows the fields of the request', async () => {
    renderMaintenance('/admin/maintenance/requests/r-1')
    const detail = await screen.findByTestId('maintenance-request-detail')
    expect(within(detail).getByTestId('request-description')).toHaveTextContent('The press does not start.')
    expect(within(detail).getByTestId('request-asset')).toHaveTextContent('FA-1')
  })

  it('Reject and Make work order belong to a holder of MaintenanceOrderManage and to a new request', async () => {
    renderMaintenance('/admin/maintenance/requests/r-1', WITH_MANAGE)
    await screen.findByTestId('maintenance-request-detail')
    expect(screen.getByTestId('request-reject')).toBeInTheDocument()
    expect(screen.getByTestId('request-make-order')).toBeInTheDocument()
    cleanup()

    renderMaintenance('/admin/maintenance/requests/r-1', WITH_ALL)
    await screen.findByTestId('maintenance-request-detail')
    expect(screen.getByTestId('request-reject')).toBeInTheDocument()
    expect(screen.getByTestId('request-make-order')).toBeInTheDocument()
  })

  it('a reader without MaintenanceOrderManage sees no action', async () => {
    const reader: AccessState = {
      status: 'ready',
      info: { roles: [], platform_tenant: false, permissions: ['MaintenanceRead'] },
    }
    renderMaintenance('/admin/maintenance/requests/r-1', reader)
    await screen.findByTestId('maintenance-request-detail')
    expect(screen.queryByTestId('request-reject')).not.toBeInTheDocument()
    expect(screen.queryByTestId('request-make-order')).not.toBeInTheDocument()
  })

  it('an ordered request shows no action', async () => {
    fakeServer(client, { requests: [request({ status: 'ordered', order: { id: 'o-1', number: 'WO-2026-000001' } })] })
    renderMaintenance('/admin/maintenance/requests/r-1', WITH_ALL)
    await screen.findByTestId('maintenance-request-detail')
    expect(screen.queryByTestId('request-reject')).not.toBeInTheDocument()
    expect(screen.queryByTestId('request-make-order')).not.toBeInTheDocument()
    expect(screen.getByTestId('request-order')).toHaveTextContent('WO-2026-000001')
  })

  it('Reject without a reason sends nothing', async () => {
    renderMaintenance('/admin/maintenance/requests/r-1', WITH_ALL)
    await screen.findByTestId('maintenance-request-detail')
    fireEvent.click(screen.getByTestId('request-reject'))
    const dialog = await screen.findByTestId('reject-dialog')
    fireEvent.click(within(dialog).getByRole('button', { name: 'Reject' }))
    await waitFor(() => expect(screen.getByText('Give a reason of the rejection.')).toBeInTheDocument())
    expect(clientMock.post.mock.calls.some(([p]) => String(p).endsWith('/reject'))).toBe(false)
  })

  it('Reject with a reason sends it', async () => {
    renderMaintenance('/admin/maintenance/requests/r-1', WITH_ALL)
    await screen.findByTestId('maintenance-request-detail')
    fireEvent.click(screen.getByTestId('request-reject'))
    const dialog = await screen.findByTestId('reject-dialog')
    fireEvent.change(within(dialog).getByTestId('reject-reason'), { target: { value: 'Not a fault of ours' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Reject' }))
    await waitFor(() =>
      expect(clientMock.post.mock.calls.some(([p, b]) => String(p) === `${API}/requests/r-1/reject` && (b as { reason: string }).reason === 'Not a fault of ours')).toBe(true),
    )
  })
})
