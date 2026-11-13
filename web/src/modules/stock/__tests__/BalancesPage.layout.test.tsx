// @vitest-environment jsdom
/** T-1445 (GATE B I4): the balances screen on the registry layout with a splitter, resizable columns and
 *  remembered sizes. jsdom has no layout, so widths are stubbed (host 1200 px, every th visible). Tests S1-S4, P1, P3, C1-C3. */
import { act, cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { BAL, fakeMasters, renderStock } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ROW = { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: '12.500' }
const leg = { leg_no: 1, quantity: '10', unit_ref: 'm1', sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null }
const MOVES = {
  next_cursor: null,
  rows: [{ entry_id: 'e1', posting_seq: 1, cause: 'receipt', document_type: 'stock_receipt', document_id: 'd1', document_number: 'RCP-1', event_time: '2026-11-04T10:30:00Z', legs: [leg] }],
}

let wide = 1200
const realClientWidth = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'clientWidth')
beforeEach(() => {
  localStorage.clear()
  wide = 1200
  Object.defineProperty(HTMLElement.prototype, 'clientWidth', { configurable: true, get: () => wide })
  Element.prototype.getClientRects = () => [{}] as unknown as DOMRectList
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockImplementation(async (path: string) =>
    path.endsWith('/movements') ? MOVES : { ledger_seq: 42, next_cursor: null, rows: [ROW] },
  )
  useUiLocaleStore.getState().reloadFromEnvironment()
})
afterEach(() => {
  cleanup()
  if (realClientWidth) Object.defineProperty(HTMLElement.prototype, 'clientWidth', realClientWidth)
})

async function loaded() {
  renderStock(BAL)
  await within(await screen.findByRole('table')).findByText('Bolt M8')
}
const key = (el: Element, k: string) => act(() => void el.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true })))

describe('S layout', () => {
  it('S1 two panes with nothing selected: the hint, no history request', async () => {
    await loaded()
    const grid = screen.getByTestId('registry')
    expect(grid).toHaveAttribute('data-layout', 'split')
    expect(grid).toHaveAttribute('data-detail', 'closed')
    expect(grid.querySelector(':scope > .lf-reg__list')).not.toBeNull()
    expect(within(screen.getByTestId('registry-details')).getByTestId('balances-pick-row')).toBeInTheDocument()
    expect(clientMock.get.mock.calls.some((c) => String(c[0]).endsWith('/movements'))).toBe(false)
  })

  it('S2 a row opens the history inside the one registry-details, no nested details pane', async () => {
    await loaded()
    fireEvent.click(screen.getByTestId('datatable-row'))
    const panel = await screen.findByTestId('balance-history')
    const details = screen.getByTestId('registry-details')
    expect(details).toContainElement(panel)
    expect(details.querySelector('.lf-reg__details')).toBeNull()
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
  })

  it('S3 Escape and the close button clear the selection', async () => {
    await loaded()
    fireEvent.click(screen.getByTestId('datatable-row'))
    const panel = await screen.findByTestId('balance-history')
    fireEvent.keyDown(panel, { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('balance-history')).toBeNull())
    fireEvent.click(screen.getByTestId('datatable-row'))
    fireEvent.click(await screen.findByTestId('history-close'))
    await waitFor(() => expect(screen.queryByTestId('balance-history')).toBeNull())
  })

  it('S4 the back row clears the selection', async () => {
    await loaded()
    fireEvent.click(screen.getByTestId('datatable-row'))
    await screen.findByTestId('balance-history')
    fireEvent.click(screen.getByTestId('list-detail-back'))
    await waitFor(() => expect(screen.queryByTestId('balance-history')).toBeNull())
  })
})

describe('P splitter', () => {
  it('P1 the list keeps 60 percent by default', async () => {
    await loaded()
    await waitFor(() => expect(screen.getByTestId('registry').style.getPropertyValue('--lf-pane-1')).toBe('60%'))
    const sep = document.querySelector('.lf-splitter') as HTMLElement
    expect(sep).toHaveAttribute('aria-label', 'Balances')
  })

  it('P1b no separator on a narrow host', async () => {
    wide = 600
    await loaded()
    expect(document.querySelector('.lf-splitter')).toBeNull()
  })

  it('P3 a key press changes the size and a remount keeps it', async () => {
    await loaded()
    const sep = (await waitFor(() => {
      const s = document.querySelector('.lf-splitter')
      expect(s).not.toBeNull()
      return s
    })) as HTMLElement
    key(sep, 'Home')
    const stored = screen.getByTestId('registry').style.getPropertyValue('--lf-pane-1')
    expect(stored).not.toBe('60%')
    expect(stored).toMatch(/%$/)
    cleanup()
    await loaded()
    await waitFor(() => expect(screen.getByTestId('registry').style.getPropertyValue('--lf-pane-1')).toBe(stored))
  })
})

describe('C columns', () => {
  it('C1 list table: data-col on all 7 headers, handles on all but the last', async () => {
    await loaded()
    const table = screen.getAllByRole('table')[0]
    expect(Array.from(table.querySelectorAll('thead th')).map((t) => t.getAttribute('data-col'))).toEqual([
      'sku', 'location', 'org_unit', 'responsible', 'lot', 'unit', 'quantity',
    ])
    await waitFor(() => expect(table).toHaveClass('lf-colresize'))
    expect(table.querySelectorAll('.lf-colhandle')).toHaveLength(6)
  })

  it('C5 minTable: both tables get a min width from the column minimums (scroll, not a cut value)', async () => {
    await loaded()
    const list = screen.getAllByRole('table')[0]
    await waitFor(() => expect(list.style.minWidth).toBe('690px'))
    fireEvent.click(screen.getByTestId('datatable-row'))
    const panel = await screen.findByTestId('balance-history')
    await waitFor(() => expect((panel.querySelector('table') as HTMLElement).style.minWidth).toBe('506px'))
  })

  it('C2 history table: 4 handles; Enter resets a changed width', async () => {
    await loaded()
    fireEvent.click(screen.getByTestId('datatable-row'))
    const panel = await screen.findByTestId('balance-history')
    await within(panel).findByText('RCP-1 - Receipt')
    await waitFor(() => expect(panel.querySelectorAll('.lf-colhandle')).toHaveLength(4))
    const th = panel.querySelector('th[data-col=time]') as HTMLElement
    const h = th.querySelector('.lf-colhandle') as HTMLElement
    expect(th.style.width).toBe('32%')
    key(h, 'ArrowRight')
    expect(th.style.width).not.toBe('32%')
    key(h, 'Enter')
    expect(th.style.width).toBe('32%')
  })

  it('C3 a handle press does not sort a sortable header', async () => {
    await loaded()
    const th = screen.getAllByRole('table')[0].querySelector('th[data-col=sku]') as HTMLElement
    const h = await waitFor(() => {
      const x = th.querySelector('.lf-colhandle')
      expect(x).not.toBeNull()
      return x as HTMLElement
    })
    const before = th.getAttribute('aria-sort')
    fireEvent.click(h)
    expect(th.getAttribute('aria-sort')).toBe(before)
  })
})
