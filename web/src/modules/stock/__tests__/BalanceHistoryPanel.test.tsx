// @vitest-environment jsdom
/** P1–P4 — T-1430: the history panel behind a stock balance row (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { BAL, fakeMasters, problem, renderStock, routeCalls } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ROW = { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: '12.500' }
const leg = (over: Record<string, unknown> = {}) => ({ leg_no: 1, quantity: '10', unit_ref: 'm1', sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, ...over })
const MOVES = {
  next_cursor: null,
  rows: [
    { entry_id: 'e1', posting_seq: 1, cause: 'receipt', document_type: 'stock_receipt', document_id: 'd1', document_number: 'RCP-2026-000001', event_time: '2026-11-04T10:30:00Z', legs: [leg()] },
    { entry_id: 'e2', posting_seq: 2, cause: 'issue', document_type: 'stock_issue', document_id: 'd2', document_number: null, event_time: '2026-11-05T10:30:00Z', legs: [leg({ quantity: '-2.5' })] },
  ],
}

function serve(movements: unknown | (() => Promise<unknown>)) {
  clientMock.get.mockImplementation(async (path: string) => {
    if (path.endsWith('/movements')) return typeof movements === 'function' ? (movements as () => Promise<unknown>)() : movements
    return { ledger_seq: 42, next_cursor: null, rows: [ROW] }
  })
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  fakeMasters(clientMock)
  useUiLocaleStore.getState().reloadFromEnvironment()
})
afterEach(() => cleanup())

async function openPanel() {
  renderStock(BAL)
  await within(await screen.findByRole('table')).findByText('Bolt M8')
  fireEvent.click(screen.getByTestId('datatable-row'))
  return screen.findByTestId('balance-history')
}

describe('P1 request', () => {
  it('opens on a row click and asks for exactly the five slots of the row', async () => {
    serve(MOVES)
    await openPanel()
    await waitFor(() => expect(routeCalls(clientMock, 'movements')).toEqual([{ sku: 'i1', location: 'l1', org_unit: 'u1', responsible: '', lot: '' }]))
  })
})

describe('P2 lines', () => {
  it('shows date-time, linked document, cause, in and out', async () => {
    serve(MOVES)
    const panel = await openPanel()
    const link = await within(panel).findByTestId('history-doc-link')
    expect(link).toHaveTextContent('RCP-2026-000001 - Receipt')
    expect(link).toHaveAttribute('href', '/admin/stock/documents/d1')
    expect(within(panel).getAllByTestId('history-doc-link')).toHaveLength(1)
    expect(panel).toHaveTextContent('Receipt')
    expect(panel).toHaveTextContent('10')
    expect(panel).toHaveTextContent('2.5')
    const outs = within(panel).getAllByTestId('datatable-cell-out').map((c) => c.textContent)
    expect(outs[0]).toBe('-')
    expect(outs[1]).toMatch(/^2\.5/)
    expect(panel).toHaveTextContent('Nov 4, 2026')
  })

  it('formats the time per language', async () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    serve(MOVES)
    const panel = await openPanel()
    await waitFor(() => expect(within(panel).getAllByTestId('datatable-cell-time')[0].textContent).toMatch(/^04-11-2026 \d\d:\d\d$/))
  })
})

describe('P3 states', () => {
  it('empty', async () => {
    serve({ next_cursor: null, rows: [] })
    const panel = await openPanel()
    expect(await within(panel).findByText('No movements for this balance')).toBeInTheDocument()
  })

  it('error with retry', async () => {
    serve(() => Promise.reject(problem(500)))
    const panel = await openPanel()
    expect(await within(panel).findByText(/Something went wrong/)).toBeInTheDocument()
    expect(within(panel).getByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })

  it('load more follows next_cursor', async () => {
    serve({ ...MOVES, next_cursor: '2' })
    const panel = await openPanel()
    fireEvent.click(await within(panel).findByTestId('load-more'))
    await waitFor(() => expect(routeCalls(clientMock, 'movements').at(-1)).toMatchObject({ cursor: '2', sku: 'i1' }))
  })
})

describe('P4 closing', () => {
  it('the close button and Escape clear the selection', async () => {
    serve(MOVES)
    const panel = await openPanel()
    fireEvent.click(within(panel).getByTestId('history-close'))
    await waitFor(() => expect(screen.queryByTestId('balance-history')).not.toBeInTheDocument())
    await openPanelAgain()
    fireEvent.keyDown(screen.getByTestId('balance-history'), { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('balance-history')).not.toBeInTheDocument())
  })
})

async function openPanelAgain() {
  await within(await screen.findByRole('table')).findByText('Bolt M8')
  fireEvent.click(screen.getByTestId('datatable-row'))
  await screen.findByTestId('balance-history')
}
