// @vitest-environment jsdom
/** S1..S9 — T-1174 restyle of the lots screen: states, panel (owner rule 2a), toast, permission, keyboard. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ToastContainer } from '@/components/ui/Toast'
import { dismissToast, getToastSnapshot } from '@/hooks/useToast'
import LotsPage from '../LotsPage'
import { fakeServer, findLot, problem, rec, renderLots, withoutAtom, writeCalls } from './catalogItemsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-ci-states' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ITEM1 = rec('i1', 'catalog_item', { code: 'ITEM-1', name: 'Bolt', active: true })
const LOT1 = rec('l1', 'catalog_lot', { code: 'LOT-A', item_id: 'i1', producer: 'Acme', mark: 'M1', expiry_date: '2027-01-01', active: true })
const LOT2 = rec('l2', 'catalog_lot', { code: 'LOT-B', item_id: 'i1', producer: 'Beta', mark: '', expiry_date: '', active: true })
const LOT3 = rec('l3', 'catalog_lot', { code: 'LOT-C', item_id: 'i1', active: false })

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  fakeServer(clientMock, { catalog_item: [ITEM1], catalog_lot: [LOT1, LOT2, LOT3] })
})
afterEach(() => {
  cleanup()
  for (const e of getToastSnapshot()) dismissToast(e.id)
})

describe('states', () => {
  it('S1 shows skeleton rows while loading', async () => {
    clientMock.post.mockImplementation(() => new Promise(() => undefined))
    renderLots('/admin/catalog/lots')
    expect((await screen.findAllByTestId('datatable-skeleton-row')).length).toBeGreaterThan(0)
  })

  it('S2 empty list shows the empty state with the create action', async () => {
    fakeServer(clientMock, { catalog_item: [ITEM1], catalog_lot: [] })
    renderLots('/admin/catalog/lots')
    const empty = await screen.findByTestId('datatable-empty-state')
    expect(empty).toHaveTextContent('No lots found.')
    fireEvent.click(within(empty).getByRole('button', { name: 'Create lot' }))
    expect(await screen.findByTestId('lot-panel')).toBeInTheDocument()
  })

  it('S3 load error shows a banner with retry that loads again', async () => {
    clientMock.post.mockRejectedValue(problem(500, {}))
    renderLots('/admin/catalog/lots')
    expect(await screen.findByTestId('datatable-error')).toHaveTextContent('The lots could not be loaded.')
    const calls = clientMock.post.mock.calls.length
    fireEvent.click(screen.getByTestId('datatable-retry'))
    await waitFor(() => expect(clientMock.post.mock.calls.length).toBeGreaterThan(calls))
  })

  it('S4 without the write permission the page shows the list but no action', async () => {
    const qc = new QueryClient()
    render(
      <QueryClientProvider client={qc}>
        <AccessStateProvider state={withoutAtom}>
          <LotsPage locale="en" />
        </AccessStateProvider>
      </QueryClientProvider>,
    )
    await findLot('LOT-A')
    expect(screen.queryByTestId('create-lot')).not.toBeInTheDocument()
    expect(screen.queryByTestId('edit-LOT-A')).not.toBeInTheDocument()
    expect(screen.queryByTestId('retire-LOT-A')).not.toBeInTheDocument()
  })

  it('S5 retired lots are marked and hidden until Show retired', async () => {
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    expect(screen.queryByText('LOT-C', { selector: 'td' })).not.toBeInTheDocument()
    fireEvent.click(screen.getByTestId('show-retired'))
    const row = await findLot('LOT-C')
    expect(row).toHaveClass('is-retired')
    expect(within(row).getByText('Retired')).toBeInTheDocument()
  })
})

describe('detail panel (rule 2a)', () => {
  it('S6 edit opens in a panel, not a dialog, and stays open while another row is clicked', async () => {
    renderLots('/admin/catalog/lots')
    ;(await findLot('LOT-A')).click()
    const panel = await screen.findByTestId('lot-panel')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(within(panel).getByLabelText(/^Producer/)).toHaveValue('Acme')
    expect(screen.getByTestId('master-detail')).toBeInTheDocument()
    fireEvent.click(await findLot('LOT-B'))
    await waitFor(() => expect(within(screen.getByTestId('lot-panel')).getByLabelText(/^Producer/)).toHaveValue('Beta'))
    expect(within(screen.getByTestId('lot-panel')).getByLabelText('Lot code')).toHaveValue('LOT-B')
  })

  it('S7 the close button and Escape close the panel', async () => {
    renderLots('/admin/catalog/lots')
    fireEvent.click(screen.getByTestId('create-lot'))
    await screen.findByTestId('lot-panel')
    fireEvent.click(screen.getByTestId('panel-close'))
    expect(screen.queryByTestId('lot-panel')).not.toBeInTheDocument()
    fireEvent.click(await screen.findByTestId('edit-LOT-A'))
    const producer = await screen.findByLabelText(/^Producer/)
    fireEvent.keyDown(producer, { key: 'Escape' })
    expect(screen.queryByTestId('lot-panel')).not.toBeInTheDocument()
  })

  it('S8 a saved lot shows a success toast and closes the panel', async () => {
    render_with_toasts()
    fireEvent.click(await screen.findByTestId('edit-LOT-A'))
    fireEvent.change(await screen.findByLabelText(/^Producer/), { target: { value: 'NewCo' } })
    fireEvent.click(screen.getByTestId('edit-submit'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(await screen.findByTestId('toast-message')).toHaveTextContent('Lot LOT-A saved.')
    await waitFor(() => expect(screen.queryByTestId('lot-panel')).not.toBeInTheDocument())
  })

  it('S9 a create error about the item or code sits next to its field', async () => {
    fakeServer(clientMock, { catalog_item: [ITEM1], catalog_lot: [LOT1] }, () => {
      throw problem(422, { reason: 'record_payload_invalid' })
    })
    renderLots('/admin/catalog/lots')
    fireEvent.click(await screen.findByTestId('create-lot'))
    fireEvent.change(await screen.findByLabelText('Item'), { target: { value: 'i1' } })
    fireEvent.change(screen.getByLabelText('Lot code'), { target: { value: 'LOT-A' } })
    fireEvent.click(screen.getByTestId('create-submit'))
    const msg = await screen.findByText('The lot code is already taken for this item.')
    expect(msg).toHaveClass('lf-error')
    expect(screen.getByLabelText('Lot code')).toHaveAttribute('aria-invalid', 'true')
  })

  it('S10 a retire from the panel confirms in a dialog, then toasts', async () => {
    render_with_toasts()
    fireEvent.click(await screen.findByTestId('edit-LOT-A'))
    fireEvent.click(await screen.findByTestId('panel-retire'))
    const dialog = await screen.findByRole('dialog')
    fireEvent.click(within(dialog).getByRole('button', { name: 'Retire' }))
    expect(await screen.findByText('Lot LOT-A retired.')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByTestId('lot-panel')).not.toBeInTheDocument())
  })
})

function render_with_toasts() {
  renderLots('/admin/catalog/lots')
  // The app shell mounts one ToastContainer; the route test render has none.
  render(<ToastContainer />)
}
