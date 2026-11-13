// @vitest-environment jsdom
/** B1, MV1 — T-1334 / C14: the asset balances (with the history panel) and movements screens (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import {
  API, BAL, MOV, fakeMasters, queryBodies, refusal, renderAssets, routeCalls,
} from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ROW = { asset: 'a1', org_unit: 'u1', location: 'l1', material_responsible: 'e1', actual_user: null, unit_ref: 'pcs', quantity: '12.500000000', last_posting_seq: 4 }
const ROW2 = { asset: 'a2', org_unit: 'u2', location: null, material_responsible: 'e2', actual_user: 'e1', unit_ref: 'pcs', quantity: '1.000000000' }

function serve(handlers: Partial<Record<'balances' | 'movements', unknown>>) {
  clientMock.get.mockImplementation(async (path: string) => {
    if (path === `${API}/balances`) return handlers.balances ?? { rows: [], next_cursor: null }
    if (path === `${API}/movements`) return handlers.movements ?? { rows: [], next_cursor: null }
    return { rows: [], next_cursor: null }
  })
}

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
})
afterEach(() => cleanup())

const firstAsset = async () => (await screen.findAllByTestId('datatable-cell-asset'))[0]

describe('B1 balances', () => {
  it('shows names and a dash for a null location or user, and the quantity text as formatted from the string', async () => {
    serve({ balances: { ledger_seq: 9, rows: [ROW, ROW2], next_cursor: null } })
    renderAssets(BAL)
    await waitFor(() => expect(screen.getAllByTestId('datatable-cell-asset')[0]).toHaveTextContent('FA-0001 - Delivery van'))
    const rows = screen.getAllByRole('row')
    expect(within(rows[1]).getByText('12.5')).toBeInTheDocument()
    expect(within(rows[1]).getByText('WH - Warehouse')).toBeInTheDocument()
    expect(within(rows[1]).getAllByText('—').length).toBeGreaterThan(0)
    expect(within(rows[2]).getByText('IT - IT dept')).toBeInTheDocument()
    expect(screen.getByTestId('ledger-seq')).toHaveTextContent('9')
    expect(routeCalls(clientMock, 'balances')[0]).toEqual({})
  })
  it('the first read sends no key; a filter sends exactly its key and never basis, cutoff_seq, format or a tenant', async () => {
    serve({ balances: { rows: [ROW], next_cursor: null } })
    renderAssets(BAL)
    await firstAsset()
    fireEvent.change(screen.getByLabelText('Asset'), { target: { value: 'a1' } }).valueOf()
    // the picker options arrive asynchronously; wait for them and pick the org unit subtree as well
    await waitFor(() => expect(screen.getByLabelText('Org unit and below')).toBeInTheDocument())
    await waitFor(() => expect(within(screen.getByLabelText('Org unit and below')).getAllByRole('option').length).toBeGreaterThan(1))
    fireEvent.change(screen.getByLabelText('Org unit and below'), { target: { value: 'u1' } })
    await waitFor(() => expect(routeCalls(clientMock, 'balances').some((p) => p['scope_subtree'] === 'u1')).toBe(true))
    const allowed = ['asset', 'org_unit', 'location', 'material_responsible', 'actual_user', 'scope_subtree', 'cursor']
    for (const p of routeCalls(clientMock, 'balances')) {
      for (const k of Object.keys(p)) expect(allowed, k).toContain(k)
      for (const v of Object.values(p)) expect(v).not.toBe('')
    }
    expect(JSON.stringify(clientMock.get.mock.calls)).not.toContain('tid-assets')
  })
  it('coverage visible_only with a subtree shows the banner; complete shows none; without a subtree none', async () => {
    serve({ balances: { rows: [ROW], next_cursor: null, coverage: 'visible_only' } })
    renderAssets(BAL)
    await firstAsset()
    expect(screen.queryByText('Showing only your units inside the chosen unit.')).not.toBeInTheDocument()
    await waitFor(() => expect(within(screen.getByLabelText('Org unit and below')).getAllByRole('option').length).toBeGreaterThan(1))
    fireEvent.change(screen.getByLabelText('Org unit and below'), { target: { value: 'u1' } })
    expect(await screen.findByText('Showing only your units inside the chosen unit.')).toBeInTheDocument()
    cleanup()
    serve({ balances: { rows: [ROW], next_cursor: null, coverage: 'complete' } })
    renderAssets(BAL)
    await firstAsset()
    await waitFor(() => expect(within(screen.getByLabelText('Org unit and below')).getAllByRole('option').length).toBeGreaterThan(1))
    fireEvent.change(screen.getByLabelText('Org unit and below'), { target: { value: 'u1' } })
    await waitFor(() => expect(routeCalls(clientMock, 'balances').some((p) => p['scope_subtree'] === 'u1')).toBe(true))
    expect(screen.queryByText('Showing only your units inside the chosen unit.')).not.toBeInTheDocument()
  })
  it('Load more sends the cursor; empty, error with Retry and 422 are drawn', async () => {
    clientMock.get.mockResolvedValueOnce({ rows: [ROW], next_cursor: 'c1' })
    clientMock.get.mockResolvedValue({ rows: [ROW2], next_cursor: null })
    renderAssets(BAL)
    fireEvent.click(await screen.findByTestId('load-more'))
    await waitFor(() => expect(routeCalls(clientMock, 'balances')[1]).toEqual({ cursor: 'c1' }))
    cleanup()
    clientMock.get.mockReset()
    serve({})
    renderAssets(BAL)
    expect(await screen.findByText('No balances yet')).toBeInTheDocument()
    cleanup()
    clientMock.get.mockReset()
    clientMock.get.mockRejectedValue(refusal(422))
    renderAssets(BAL)
    expect(await screen.findByText(/filter value is not valid/)).toBeInTheDocument()
  })
  it('a row opens the history: the movements call carries no slot key, and only the legs of the row are listed', async () => {
    serve({
      balances: { rows: [ROW, ROW2], next_cursor: null },
      movements: {
        next_cursor: null,
        rows: [
          { entry_id: 'e-1', posting_seq: 1, cause: 'commission', document_type: 'assets_commission', document_id: 'd1', event_time: '2026-11-04T05:00:00Z',
            legs: [
              { leg_no: 1, asset: 'a1', org_unit: 'u1', location: 'l1', material_responsible: 'e1', actual_user: null, quantity: '13', unit_ref: 'pcs' },
              { leg_no: 2, asset: 'a2', org_unit: 'u2', location: null, material_responsible: 'e2', actual_user: 'e1', quantity: '1', unit_ref: 'pcs' },
            ] },
          { entry_id: 'e-2', posting_seq: 2, cause: 'writeoff', document_type: 'assets_writeoff', document_id: 'd2', event_time: '2026-11-05T05:00:00Z',
            legs: [{ leg_no: 1, asset: 'a1', org_unit: 'u1', location: 'l1', material_responsible: 'e1', actual_user: null, quantity: '-0.5', unit_ref: 'pcs' }] },
        ],
      },
    })
    renderAssets(BAL)
    fireEvent.click(((await firstAsset()) as HTMLElement).closest('tr') as HTMLElement)
    const panel = await screen.findByTestId('balance-history')
    await waitFor(() => expect(within(panel).getAllByRole('row')).toHaveLength(3))
    expect(within(panel).getAllByTestId('history-doc-link').map((a) => a.getAttribute('href'))).toEqual(['/admin/assets/documents/d1', '/admin/assets/documents/d2'])
    expect(within(panel).getByText('13 pcs')).toBeInTheDocument()
    expect(within(panel).getByText('0.5 pcs')).toBeInTheDocument()
    for (const p of routeCalls(clientMock, 'movements')) expect(Object.keys(p)).toEqual([])
  })
})

describe('T1 as-of date and export', () => {
  const download = () => {
    const create = vi.fn(() => 'blob:x')
    Object.assign(URL, { createObjectURL: create, revokeObjectURL: vi.fn() })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    return { create, click }
  }
  const body = { as_of_date: '2026-11-03', timezone: 'Asia/Almaty', cutoff_seq: 17, ledger_seq: 42, next_cursor: null, rows: [ROW] }
  it('sends as_of_date only, shows the server day, zone and cutoff, and clearing drops it', async () => {
    serve({ balances: body })
    renderAssets(BAL)
    await firstAsset()
    fireEvent.change(screen.getByLabelText('As of date'), { target: { value: '2026-11-03' } })
    await screen.findByTestId('as-of-read')
    expect(screen.getByTestId('as-of-read')).toHaveTextContent('Balance at the end of 2026-11-03 (Asia/Almaty), through posting number 17')
    expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({ as_of_date: '2026-11-03' })
    fireEvent.click(screen.getByRole('button', { name: 'Clear filters' }))
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({}))
  })
  it('shows the future message and sends no as_of_date', async () => {
    serve({ balances: { rows: [ROW], next_cursor: null } })
    renderAssets(BAL)
    await firstAsset()
    const input = screen.getByLabelText('As of date')
    fireEvent.change(input, { target: { value: '2999-01-01' } })
    expect(await screen.findByText('The date cannot be in the future.')).toBeInTheDocument()
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({}))
  })
  it('exports the xlsx with the current filters and day, no cursor, and saves the file', async () => {
    const { create, click } = download()
    clientMock.getBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x' })
    serve({ balances: body })
    renderAssets(BAL)
    await firstAsset()
    fireEvent.change(screen.getByLabelText('As of date'), { target: { value: '2026-11-03' } })
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({ as_of_date: '2026-11-03' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Export to Excel' })).toBeEnabled())
    fireEvent.click(screen.getByRole('button', { name: 'Export to Excel' }))
    await waitFor(() => expect(click).toHaveBeenCalled())
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${API}/balances`, { as_of_date: '2026-11-03', format: 'xlsx' })
    expect(create).toHaveBeenCalled()
  })
  it('shows an error and saves nothing when the export fails', async () => {
    const { click } = download()
    clientMock.getBlob.mockRejectedValue({ status: 403 })
    serve({ balances: body })
    renderAssets(BAL)
    await firstAsset()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Export to Excel' })).toBeEnabled())
    fireEvent.click(screen.getByRole('button', { name: 'Export to Excel' }))
    expect(await screen.findByText('The file could not be exported. Try again.')).toBeInTheDocument()
    expect(click).not.toHaveBeenCalled()
  })
})

describe('MV1 movements', () => {
  const MOVEMENTS = {
    next_cursor: null,
    rows: [
      { entry_id: 'm-1', posting_seq: 1, cause: 'handover', document_type: 'assets_handover', document_id: 'd7', event_time: '2026-11-04T05:00:00Z', posting_time: '2026-11-04T05:01:00Z',
        legs: [
          { leg_no: 1, asset: 'a1', org_unit: 'u1', location: 'l1', material_responsible: 'e1', actual_user: null, quantity: '-1', unit_ref: 'pcs' },
          { leg_no: 2, asset: 'a1', org_unit: 'u2', location: null, material_responsible: 'e2', actual_user: null, quantity: '1', unit_ref: 'pcs' },
        ] },
      { entry_id: 'm-2', posting_seq: 2, cause: 'commission', document_type: 'assets_commission', document_id: 'd8', event_time: '2026-11-05T05:00:00Z',
        legs: [{ leg_no: 1, masked: true, quantity: '1', unit_ref: 'pcs' }] },
    ],
  }
  it('lists the entries with the cause, the kind word linked to the document and the time; filters send only their four keys', async () => {
    serve({ movements: MOVEMENTS })
    renderAssets(MOV)
    const rows = await screen.findAllByTestId('journal-row')
    expect(rows).toHaveLength(2)
    expect(rows[0]).toHaveTextContent('Hand over')
    expect(rows[0]).toHaveTextContent('Nov 4, 2026 10:00')
    expect(routeCalls(clientMock, 'movements')[0]).toEqual({})
    fireEvent.click(screen.getAllByRole('button', { name: /Filters/ })[0])
    fireEvent.change(await screen.findByLabelText('Cause'), { target: { value: 'writeoff' } })
    fireEvent.change(screen.getByLabelText('From posting number'), { target: { value: '5' } })
    fireEvent.change(screen.getByLabelText('To posting number'), { target: { value: '3' } })
    await waitFor(() => expect(routeCalls(clientMock, 'movements').some((p) => p['cause'] === 'writeoff')).toBe(true))
    for (const p of routeCalls(clientMock, 'movements')) {
      for (const k of Object.keys(p)) expect(['cause', 'document_id', 'from_seq', 'to_seq', 'cursor']).toContain(k)
    }
    expect(routeCalls(clientMock, 'movements').some((p) => 'from_seq' in p && 'to_seq' in p)).toBe(false)
    expect(screen.getAllByText('The first number must not be above the second.').length).toBeGreaterThan(0)
  })
  it('a masked leg shows Hidden and its quantity, and no master name is requested for its slots', async () => {
    serve({ movements: { next_cursor: null, rows: [MOVEMENTS.rows[1]] } })
    renderAssets(MOV)
    const row = await screen.findByTestId('journal-row')
    fireEvent.click(row)
    await waitFor(() => expect(screen.getAllByText('Hidden').length).toBeGreaterThan(0))
    for (const t of ['assets_card', 'org_unit', 'location_node', 'org_employee']) expect(queryBodies(clientMock, t), t).toEqual([])
  })
  it('opens the legs of an entry with the asset, place and holder names, and links the document', async () => {
    serve({ movements: { next_cursor: null, rows: [MOVEMENTS.rows[0]] } })
    renderAssets(`${MOV}?document_id=d7`)
    expect(routeCalls(clientMock, 'movements')[0] ?? { document_id: 'd7' }).toEqual({ document_id: 'd7' })
    fireEvent.click(await screen.findByTestId('journal-row'))
    await waitFor(() => expect(screen.getAllByText(/FA-0001/).length).toBeGreaterThan(0))
    expect(screen.getAllByText(/Aigul B\./).length).toBeGreaterThan(0)
    expect(screen.getAllByRole('link', { name: 'Hand over' })[0]).toHaveAttribute('href', '/admin/assets/documents/d7')
  })
  it('empty and error states are drawn', async () => {
    serve({})
    renderAssets(MOV)
    expect(await screen.findByText('No movements yet')).toBeInTheDocument()
    cleanup()
    clientMock.get.mockReset()
    clientMock.get.mockRejectedValue(refusal(500))
    renderAssets(MOV)
    expect(await screen.findByText('The data could not be loaded.')).toBeInTheDocument()
  })
})
