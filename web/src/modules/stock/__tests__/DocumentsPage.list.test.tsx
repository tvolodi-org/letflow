// @vitest-environment jsdom
/** C2 — GH 3769 / REQ-722: the stock document list (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { DOCS, LIST, fakeMasters, queryBodies, refusal, renderStock, withAtom, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ROW = { id: 'd1', kind: 'receipt', state: 'posted', number: 'RC-1', org_unit_id: 'u1', event_time: '2026-11-04T05:00:00Z' }
const DRAFT = { id: 'd2', kind: 'issue', state: 'draft', number: null, org_unit_id: 'u-gone', event_time: '2026-11-04T06:00:00Z' }

function listCalls(): Record<string, string>[] {
  return clientMock.get.mock.calls.filter(([p]) => p === DOCS).map(([, q]) => (q ?? {}) as Record<string, string>)
}

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ next_cursor: null, rows: [ROW, DRAFT] })
})
afterEach(() => cleanup())

describe('C2-a rows', () => {
  it('shows number, draft mark, kind, time in Asia/Almaty, org unit name and state word', async () => {
    renderStock(LIST)
    await screen.findByText('RC-1')
    expect(listCalls()).toEqual([{}])
    expect(screen.getByText('Nov 4, 2026 10:00')).toBeInTheDocument()
    await waitFor(() => expect(screen.getAllByTestId('document-row')[0]).toHaveTextContent('Main store'))
    expect(screen.getByText('u-gone')).toBeInTheDocument()
    expect(screen.getAllByText('Draft').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Posted').length).toBeGreaterThan(0)
  })
})

describe('C2-b0 kinds (REQ-723)', () => {
  it('offers the six kinds and the new ones send only kind', async () => {
    renderStock(LIST)
    await screen.findByText('RC-1')
    const opts = within(screen.getByLabelText('Kind')).getAllByRole('option').map((o) => (o as HTMLOptionElement).value)
    expect(opts).toEqual(expect.arrayContaining(['receipt', 'issue', 'write_off', 'transfer', 'hand_over', 'return']))
    for (const k of ['transfer', 'hand_over', 'return']) {
      fireEvent.change(screen.getByLabelText('Kind'), { target: { value: k } })
      await waitFor(() => expect(listCalls().at(-1)).toEqual({ kind: k }))
    }
  })
})

describe('C2-b filters', () => {
  it('each filter sends only its own key and clearing removes it', async () => {
    renderStock(LIST)
    await screen.findByText('RC-1')
    await screen.findByRole('option', { name: 'Main store' })
    fireEvent.change(screen.getByLabelText('Kind'), { target: { value: 'write_off' } })
    await waitFor(() => expect(listCalls().at(-1)).toEqual({ kind: 'write_off' }))
    fireEvent.change(screen.getByLabelText('State'), { target: { value: 'issued' } })
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u1' } })
    await waitFor(() => expect(listCalls().at(-1)).toEqual({ kind: 'write_off', state: 'issued', org_unit_id: 'u1' }))
    fireEvent.change(screen.getByLabelText('Kind'), { target: { value: '' } })
    await waitFor(() => expect(listCalls().at(-1)).toEqual({ state: 'issued', org_unit_id: 'u1' }))
  })
})

describe('C2-c paging', () => {
  it('Load more sends the cursor with the same filters, appends, and hides at the end', async () => {
    clientMock.get.mockResolvedValueOnce({ next_cursor: 'c2', rows: [ROW] })
    clientMock.get.mockResolvedValueOnce({ next_cursor: null, rows: [{ ...DRAFT, id: 'd3', number: 'IS-2' }] })
    renderStock(LIST)
    await screen.findByText('RC-1')
    fireEvent.click(screen.getByTestId('load-more'))
    await screen.findByText('IS-2')
    expect(listCalls()).toEqual([{}, { cursor: 'c2' }])
    expect(screen.getByText('RC-1')).toBeInTheDocument()
    expect(screen.queryByTestId('load-more')).not.toBeInTheDocument()
  })
})

describe('C2-d names', () => {
  it('reads org unit names with record_id in the ids of each page, once per page', async () => {
    clientMock.get.mockResolvedValueOnce({ next_cursor: 'c2', rows: [ROW, { ...ROW, id: 'dx', number: 'RC-9' }] })
    clientMock.get.mockResolvedValueOnce({ next_cursor: null, rows: [DRAFT] })
    renderStock(LIST)
    await screen.findByText('RC-9')
    fireEvent.click(screen.getByTestId('load-more'))
    await screen.findByText('u-gone')
    const ins = queryBodies(clientMock, 'org_unit').filter((b) => JSON.stringify(b).includes('"in"'))
    expect(ins.map((b) => b['filters'])).toEqual([
      [{ field: 'record_id', op: 'in', value: ['u1'] }],
      [{ field: 'record_id', op: 'in', value: ['u-gone'] }],
    ])
  })
})

describe('C2-e states', () => {
  it('empty state, error with retry, not found, and the New button by atom', async () => {
    clientMock.get.mockResolvedValue({ next_cursor: null, rows: [] })
    renderStock(LIST, withPost)
    expect(await screen.findByText('No stock documents found.')).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'New document' }).length).toBeGreaterThan(0)
    cleanup()
    renderStock(LIST, withAtom)
    await screen.findByText('No stock documents found.')
    expect(screen.queryByRole('button', { name: 'New document' })).not.toBeInTheDocument()
    cleanup()
    clientMock.get.mockReset()
    clientMock.get.mockRejectedValueOnce(refusal(500))
    clientMock.get.mockResolvedValue({ next_cursor: null, rows: [ROW] })
    renderStock(LIST)
    fireEvent.click(await screen.findByRole('button', { name: 'Retry' }))
    await screen.findByText('RC-1')
    cleanup()
    clientMock.get.mockReset()
    clientMock.get.mockRejectedValue(refusal(404))
    renderStock(LIST)
    expect(await screen.findByText('This view is not available to you.')).toBeInTheDocument()
  })
})
