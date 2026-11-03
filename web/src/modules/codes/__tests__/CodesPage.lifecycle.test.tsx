// @vitest-environment jsdom
/** L1–L3 — GH 3606 / REQ-672: list filters, row actions, retire warning, history. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, problem, queryBodies, rec, renderCodes, withAtom, withoutAtom, writeCalls } from './codesTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-codes' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const BASE = '/api/v1/modules/codes'
const DATA = () => ({
  code_tag: [
    rec('c1', 'code_tag', { value: 'FREE-1', kind: 'barcode', status: 'not_assigned' }),
    rec('c2', 'code_tag', { value: 'USED-1', kind: 'qr', status: 'assigned' }),
    rec('c3', 'code_tag', { value: 'GONE-1', kind: 'epc', status: 'retired' }),
  ],
  location_node: [rec('l1', 'location_node', { code: 'A-01', name: 'Aisle' })],
  catalog_item: [rec('i1', 'catalog_item', { code: 'ITEM-1', name: 'Bolt' })],
  catalog_lot: [],
  code_assignment: [
    rec('a2', 'code_assignment', { code_id: 'c2', target_type: 'catalog_item', target_id: 'i1', assigned_at: '2026-02-01T10:00:00Z' }),
    rec('a1', 'code_assignment', {
      code_id: 'c2', target_type: 'location_node', target_id: 'l1',
      assigned_at: '2026-01-01T10:00:00Z', released_at: '2026-01-15T10:00:00Z',
    }),
  ],
})

beforeEach(() => {
  clientMock.post.mockReset()
  fakeServer(clientMock, DATA())
})
afterEach(() => cleanup())

/** The table row of a code, found by its value (the first match is the list row). */
const row = async (v: string) => (await screen.findAllByText(v))[0].closest('tr') as HTMLElement
const panel = () => screen.findByTestId('codes-detail')
const openPanel = async (v: string) => {
  fireEvent.click(await row(v))
  return panel()
}

describe('L1 row actions', () => {
  it('lists status, kind and the open target of an assigned code; a retired code is behind "Show retired"', async () => {
    renderCodes('/admin/codes')
    const used = await row('USED-1')
    await waitFor(() => expect(used).toHaveTextContent('ITEM-1'))
    expect(used).toHaveTextContent('Item')
    expect(used).toHaveTextContent('Assigned')
    expect(screen.queryByText('GONE-1')).toBeNull()
    fireEvent.click(screen.getByTestId('codes-show-retired').closest('label')!.querySelector('input')!)
    const gone = await row('GONE-1')
    expect(within(gone).queryByRole('button')).toBeNull()
    const detail = await openPanel('GONE-1')
    expect(within(detail).queryByRole('button', { name: 'Retire' })).toBeNull()
    expect(within(detail).queryByRole('button', { name: 'Assign' })).toBeNull()
    expect(within(detail).getByText('Assignment history')).toBeInTheDocument()
  })

  it('assigns a code to a target and reloads the list', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('FREE-1')).getByRole('button', { name: 'Assign' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByRole('radio', { name: 'Location' })).toBeChecked()
    fireEvent.click(within(dialog).getByRole('radio', { name: 'Item' }))
    fireEvent.click(within(dialog).getByRole('radio', { name: 'Location' }))
    await within(dialog).findByRole('option', { name: 'A-01 - Aisle' })
    fireEvent.change(within(dialog).getByLabelText('Target'), { target: { value: 'l1' } })
    const before = queryBodies(clientMock, 'code_tag').length
    fireEvent.click(screen.getByTestId('assign-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.path).toBe(`${BASE}/c1/assign`)
    expect(call.body).toMatchObject({ target_type: 'location_node', target_id: 'l1' })
    expect(call.body['idempotency_key']).toBeTruthy()
    await waitFor(() => expect(queryBodies(clientMock, 'code_tag').length).toBeGreaterThan(before))
  })

  it('releases an assigned code', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('USED-1')).getByRole('button', { name: 'Release' }))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].path).toBe(`${BASE}/c2/release`)
    expect(Object.keys(writeCalls(clientMock)[0].body)).toEqual(['idempotency_key'])
  })

  it('shows the warning before retiring and posts only after the confirmation', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await openPanel('FREE-1')).getByRole('button', { name: 'Retire' }))
    expect(await screen.findByText(/A retired code never comes back/)).toBeInTheDocument()
    expect(writeCalls(clientMock)).toHaveLength(0)
    const dialog = screen.getByRole('dialog')
    fireEvent.click(within(dialog).getByRole('button', { name: 'Retire' }))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].path).toBe(`${BASE}/c1/retire`)
  })

  it('rewrites the value', async () => {
    renderCodes('/admin/codes')
    await openPanel('FREE-1')
    const input = await screen.findByLabelText('New value')
    expect(input).toHaveValue('FREE-1')
    fireEvent.change(input, { target: { value: 'FREE-2' } })
    fireEvent.click(screen.getByTestId('value-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].path).toBe(`${BASE}/c1/value`)
    expect(writeCalls(clientMock)[0].body).toMatchObject({ value: 'FREE-2' })
  })
})

describe('L2 history', () => {
  it('shows the assignments of the code in time order with an open end', async () => {
    renderCodes('/admin/codes')
    const detail = await openPanel('USED-1')
    await waitFor(() => expect(within(detail).getAllByTestId('datatable-row')).toHaveLength(2))
    const rows = within(detail).getAllByTestId('datatable-row')
    expect(rows[0]).toHaveTextContent('A-01')
    expect(rows[0]).toHaveTextContent('Location')
    expect(rows[1]).toHaveTextContent('ITEM-1')
    expect(rows[1]).toHaveTextContent('open')
    const q = queryBodies(clientMock, 'code_assignment').find((b) =>
      (b['filters'] as { field: string }[]).some((f) => f.field === 'code_id'),
    )
    expect(q?.['filters']).toContainEqual({ field: 'code_id', op: 'eq', value: 'c2' })
    expect(q?.['sort']).toEqual([{ field: 'assigned_at', dir: 'asc' }])
  })
})

describe('L4 detail panel (owner rule 2a)', () => {
  it('stays open while other rows are clicked, has a close button and closes on Escape', async () => {
    renderCodes('/admin/codes')
    await openPanel('FREE-1')
    expect(screen.getByTestId('master-detail')).toBeInTheDocument()
    fireEvent.click(await row('USED-1'))
    expect(within(await panel()).getByRole('heading', { level: 2, name: 'USED-1' })).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('codes-detail-close'))
    expect(screen.queryByTestId('codes-detail')).toBeNull()
    await openPanel('FREE-1')
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByTestId('codes-detail')).toBeNull()
  })

  it('does not close the panel on Escape while a dialog is open', async () => {
    renderCodes('/admin/codes')
    await openPanel('FREE-1')
    fireEvent.click(within(await panel()).getByRole('button', { name: 'Retire' }))
    await screen.findByRole('dialog')
    fireEvent.keyDown(window, { key: 'Escape' })
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull())
    expect(screen.getByTestId('codes-detail')).toBeInTheDocument()
  })

  it('shows no write action without the permission', async () => {
    renderCodes('/admin/codes', withAtom)
    await row('FREE-1')
    cleanup()
    // the route guard hides the whole screen without the atom; the page itself also hides actions
    const { default: CodesPage } = await import('../CodesPage')
    const { AccessStateProvider } = await import('@/auth/access/AccessContext')
    const { render } = await import('@testing-library/react')
    const { QueryClient, QueryClientProvider } = await import('@tanstack/react-query')
    render(
      <QueryClientProvider client={new QueryClient()}>
        <AccessStateProvider state={withoutAtom}>
          <CodesPage />
        </AccessStateProvider>
      </QueryClientProvider>,
    )
    const r = await row('FREE-1')
    expect(within(r).queryByRole('button')).toBeNull()
    expect(screen.queryByTestId('receive-open')).toBeNull()
  })
})

describe('L5 states and toast', () => {
  it('shows an empty state with the receive action', async () => {
    fakeServer(clientMock, {})
    renderCodes('/admin/codes')
    const empty = await screen.findByTestId('datatable-empty-state')
    fireEvent.click(within(empty).getByRole('button', { name: 'Receive codes' }))
    expect(await screen.findByRole('dialog')).toBeInTheDocument()
  })

  it('shows a skeleton while loading', async () => {
    clientMock.post.mockImplementation(() => new Promise(() => {}))
    renderCodes('/admin/codes')
    expect((await screen.findAllByTestId('datatable-skeleton-row')).length).toBeGreaterThan(0)
  })

  it('shows a load error with a retry that reloads', async () => {
    clientMock.post.mockRejectedValue(problem(500, {}))
    renderCodes('/admin/codes')
    expect(await screen.findByText('The codes could not be loaded.')).toBeInTheDocument()
    fakeServer(clientMock, DATA())
    fireEvent.click(screen.getByTestId('datatable-retry'))
    await row('FREE-1')
  })

  it('shows the shared no-access message when the list answers 403', async () => {
    clientMock.post.mockRejectedValue(problem(403, {}))
    renderCodes('/admin/codes')
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
  })

  it('shows a success toast after a release', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('USED-1')).getByRole('button', { name: 'Release' }))
    expect(await screen.findByText('Code released')).toBeInTheDocument()
  })

  it('shows the error of a release as a banner', async () => {
    fakeServer(clientMock, DATA(), () => {
      throw problem(422, { reason: 'code_not_assigned' })
    })
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('USED-1')).getByRole('button', { name: 'Release' }))
    expect(await screen.findByText('The code is not assigned.')).toBeInTheDocument()
  })
})

describe('L3 list filters', () => {
  it('puts the status and the exact value into the query', async () => {
    renderCodes('/admin/codes')
    await row('FREE-1')
    fireEvent.change(screen.getByLabelText('Status filter'), { target: { value: 'assigned' } })
    await waitFor(() =>
      expect(queryBodies(clientMock, 'code_tag').some((b) =>
        (b['filters'] as unknown[]).some((f) => JSON.stringify(f) === JSON.stringify({ field: 'status', op: 'eq', value: 'assigned' })),
      )).toBe(true),
    )
    fireEvent.change(screen.getByLabelText('Exact value'), { target: { value: 'USED-1' } })
    fireEvent.click(screen.getByTestId('codes-search'))
    await waitFor(() =>
      expect(queryBodies(clientMock, 'code_tag').some((b) =>
        (b['filters'] as unknown[]).some((f) => JSON.stringify(f) === JSON.stringify({ field: 'value', op: 'eq', value: 'USED-1' })),
      )).toBe(true),
    )
  })
})
