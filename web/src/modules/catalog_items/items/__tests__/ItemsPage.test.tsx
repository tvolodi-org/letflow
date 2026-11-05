// @vitest-environment jsdom
/** T-1402: the Items screen on the lf-registry layout, through the module's route objects and RequirePermission
 *  (D-098: the real path, not the component alone). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, rec, renderLots, withAtom, withoutAtom } from '../../__tests__/catalogItemsTestKit'
import { catalogItemsMessages } from '../../catalogItemsMessages'
import type { AccessState } from '@/auth/access/types'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-items' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const UOM = '11111111-1111-4111-8111-111111111111'
const LOC = '22222222-2222-4222-8222-222222222222'
const OU = '33333333-3333-4333-8333-333333333333'
const LOT = '44444444-4444-4444-8444-444444444444'
const I1 = '55555555-5555-4555-8555-555555555551'
const I2 = '55555555-5555-4555-8555-555555555552'
const I3 = '55555555-5555-4555-8555-555555555553'

function data() {
  return {
    catalog_item: [
      rec(I1, 'catalog_item', { code: 'BOLT', name: 'Steel bolt', base_uom_id: UOM, kind: 'material', tracking_policy: 'lot' }),
      rec(I2, 'catalog_item', { code: 'NUT', name: 'Hex nut', base_uom_id: UOM, kind: 'material' }),
      rec(I3, 'catalog_item', { code: 'OLD', name: 'Old part', base_uom_id: UOM, kind: 'material', active: false }),
    ],
    catalog_uom: [rec(UOM, 'catalog_uom', { code: 'PCS', name: 'Piece' })],
    location_node: [rec(LOC, 'location_node', { code: 'A-01', name: 'Aisle one' })],
    org_unit: [rec(OU, 'org_unit', { code: 'WH', name: 'Warehouse' })],
    catalog_lot: [rec(LOT, 'catalog_lot', { code: 'LOT-7' })],
  }
}

type Gets = { balances?: unknown; movements?: unknown; balancesError?: { status: number }; movementsError?: { status: number } }

function setup(gets: Gets = {}) {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  fakeServer(clientMock, data())
  clientMock.get.mockImplementation(async (path: string) => {
    if (path.endsWith('/balances')) {
      if (gets.balancesError) throw { status: gets.balancesError.status, message: 'x', code: 'x' }
      return gets.balances ?? { rows: [], next_cursor: null }
    }
    if (gets.movementsError) throw { status: gets.movementsError.status, message: 'x', code: 'x' }
    return gets.movements ?? { rows: [], next_cursor: null }
  })
}

const BAL = {
  rows: [{ sku: I1, location: LOC, org_unit: OU, lot: LOT, unit_ref: UOM, quantity: '12' }],
  next_cursor: null,
}
const MOV = {
  rows: [{ entry_id: 'e1', posting_seq: 5, cause: 'count_difference', document_type: 'stock_count', event_time: '2026-10-29T10:15:00Z' }],
  next_cursor: null,
}

const noUuid = (el: HTMLElement) => expect(el.textContent ?? '').not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)

beforeEach(() => setup())
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

const ITEMS = '/admin/catalog/items'
const row = async (code: string) => (await screen.findByText(code, { selector: 'td' })).closest('tr') as HTMLElement

describe('A1 layout and columns', () => {
  it('renders the split registry with the list before the details and the five columns', async () => {
    renderLots(ITEMS)
    await row('BOLT')
    const reg = screen.getByTestId('registry')
    expect(reg).toHaveClass('lf-reg')
    expect(reg).toHaveAttribute('data-layout', 'split')
    const kids = Array.from(reg.children)
    expect(kids[0]).toHaveClass('lf-reg__list')
    expect(kids[1]).toHaveClass('lf-reg__details')
    const heads = screen.getAllByRole('columnheader').map((h) => h.textContent)
    expect(heads).toEqual(['Code', 'Title', 'Unit', 'Tracking', 'Status'])
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Items')
  })

  it('a unit shows its code only and an absent policy shows None; retired items are hidden', async () => {
    renderLots(ITEMS)
    const r = await row('NUT')
    await waitFor(() => expect(r).toHaveTextContent('PCS'))
    expect(r).toHaveTextContent('None')
    expect(screen.queryByText('OLD', { selector: 'td' })).not.toBeInTheDocument()
    noUuid(screen.getByTestId('registry-list'))
  })
})

describe('A2 selection and back', () => {
  it('opening a row opens the details with a back button; back and Escape close it', async () => {
    renderLots(ITEMS)
    fireEvent.click(await row('BOLT'))
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
    expect(await screen.findByRole('heading', { level: 2, name: /BOLT/ })).toBeInTheDocument()
    await waitFor(() => expect(screen.getByText('BOLT', { selector: 'td' }).closest('tr')).toHaveClass('is-selected'))
    fireEvent.click(screen.getByTestId('registry-back'))
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed')
    fireEvent.click(await row('BOLT'))
    fireEvent.keyDown(await row('BOLT'), { key: 'Escape' })
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed')
  })

  it('the selected item is read from the URL; an unknown id shows not found', async () => {
    renderLots(`${ITEMS}?item=${I2}`)
    expect(await screen.findByRole('heading', { level: 2, name: /NUT/ })).toBeInTheDocument()
    cleanup()
    renderLots(`${ITEMS}?item=99999999-9999-4999-8999-999999999999`)
    expect(await screen.findByText(catalogItemsMessages.en['catalog_items.items.notFound.title'])).toBeInTheDocument()
  })

  it('arrow keys move between rows and Enter opens', async () => {
    renderLots(ITEMS)
    const first = await row('BOLT')
    first.focus()
    fireEvent.keyDown(first, { key: 'ArrowDown' })
    const second = await row('NUT')
    expect(second).toHaveFocus()
    fireEvent.keyDown(second, { key: 'Enter' })
    expect(await screen.findByRole('heading', { level: 2, name: /NUT/ })).toBeInTheDocument()
  })
})

describe('A3 search, filter, retired, sort', () => {
  it('search narrows, no match offers Clear filters', async () => {
    renderLots(ITEMS)
    await row('BOLT')
    fireEvent.change(screen.getByTestId('registry-search'), { target: { value: 'hex' } })
    expect(screen.queryByText('BOLT', { selector: 'td' })).not.toBeInTheDocument()
    await row('NUT')
    fireEvent.change(screen.getByTestId('registry-search'), { target: { value: 'zzz' } })
    expect(await screen.findByTestId('registry-nomatch')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('registry-clear-empty'))
    await row('BOLT')
  })

  it('the tracking filter shows a chip; Show retired adds the retired row; sort flips', async () => {
    renderLots(ITEMS)
    await row('BOLT')
    fireEvent.change(screen.getByLabelText('Tracking'), { target: { value: 'lot' } })
    expect(screen.queryByText('NUT', { selector: 'td' })).not.toBeInTheDocument()
    expect(screen.getByText('Tracking: Lot')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('registry-clear'))
    await row('NUT')
    fireEvent.click(screen.getByLabelText('Show retired'))
    const retired = await row('OLD')
    expect(retired).toHaveClass('is-retired')
    expect(retired).toHaveTextContent('Retired')
    fireEvent.click(screen.getByTestId('registry-sort-code'))
    const codes = () => screen.getAllByTestId('registry-row').map((r) => r.querySelector('td')?.textContent)
    expect(codes()).toEqual(['OLD', 'NUT', 'BOLT'])
  })
})

describe('A4/A6 details: references, Related, History', () => {
  it('shows code and title references, stock by location and movements without any id', async () => {
    setup({ balances: BAL, movements: MOV })
    renderLots(`${ITEMS}?item=${I1}`)
    const related = await screen.findByTestId('registry-related')
    expect(related).toHaveTextContent('A-01 - Aisle one')
    expect(related).toHaveTextContent('WH - Warehouse')
    expect(related).toHaveTextContent('LOT-7')
    expect(related).toHaveTextContent('12 PCS')
    const hist = await screen.findByTestId('registry-history')
    expect(hist).toHaveTextContent('Count adjustment')
    expect(hist).toHaveTextContent('2026-10-29 15:15')
    const overview = screen.getByTestId('registry-section-overview')
    await waitFor(() => expect(overview).toHaveTextContent('PCS'))
    expect(overview).toHaveTextContent('Lot')
    noUuid(screen.getByTestId('registry-details'))
    const calls = clientMock.get.mock.calls.map(([p, q]) => [p, q])
    expect(calls).toContainEqual(['/api/v1/modules/stock/balances', { sku: I1, limit: '200' }])
    expect(calls).toContainEqual(['/api/v1/modules/stock/movements', { sku: I1, limit: '20' }])
  })

  it('shows the date as DD-MM-YYYY in Russian', async () => {
    vi.stubGlobal('navigator', { ...navigator, languages: ['ru'], language: 'ru' })
    setup({ balances: BAL, movements: MOV })
    renderLots(`${ITEMS}?item=${I1}`)
    expect(await screen.findByTestId('registry-history')).toHaveTextContent('29-10-2026 15:15')
  })

  it('empty stock and history show their lines; a 403 shows the no-permission line', async () => {
    renderLots(`${ITEMS}?item=${I1}`)
    expect(await screen.findByTestId('registry-related-empty')).toBeInTheDocument()
    expect(await screen.findByTestId('registry-history-empty')).toBeInTheDocument()
    cleanup()
    setup({ balancesError: { status: 403 } })
    renderLots(`${ITEMS}?item=${I1}`)
    expect(await screen.findByTestId('registry-related-noperm')).toBeInTheDocument()
  })

  it('a 400 on the movements shows the history error line, not the empty line', async () => {
    setup({ movementsError: { status: 400 } })
    renderLots(`${ITEMS}?item=${I1}`)
    expect(await screen.findByTestId('registry-history-error')).toBeInTheDocument()
    expect(screen.queryByTestId('registry-history-empty')).not.toBeInTheDocument()
  })

  it('the Unit cell is mono so a code never wraps', async () => {
    renderLots(ITEMS)
    const tr = await row('BOLT')
    const unit = Array.from(tr.querySelectorAll('td')).find((td) => td.textContent === 'PCS')
    expect(unit).toHaveClass('mono')
  })

  it('a 500 on the balances shows a section error, not a crash', async () => {
    setup({ balancesError: { status: 500 } })
    renderLots(`${ITEMS}?item=${I1}`)
    expect(await screen.findByTestId('registry-related-error')).toBeInTheDocument()
  })

  it('notes that more rows exist when the balances page has a next cursor', async () => {
    setup({ balances: { ...BAL, next_cursor: 'c2' } })
    renderLots(`${ITEMS}?item=${I1}`)
    expect(await screen.findByTestId('registry-related-more')).toBeInTheDocument()
  })
})

describe('A5 view only, no modal', () => {
  it('the head has no Edit or Retire button and says why; nothing is a dialog', async () => {
    renderLots(`${ITEMS}?item=${I1}`)
    const head = await screen.findByTestId('registry-head')
    expect(within(head).queryByRole('button', { name: /edit|retire/i })).not.toBeInTheDocument()
    expect(screen.getByTestId('registry-reason')).toHaveTextContent('cannot be edited here')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByTestId('registry-import-link')).toHaveAttribute('href', '/admin/import')
  })
})

describe('A7 states', () => {
  it('shows the empty state, the load error with Retry, and the loading skeleton', async () => {
    clientMock.post.mockReset()
    fakeServer(clientMock, {})
    renderLots(ITEMS)
    expect(await screen.findByTestId('registry-empty')).toBeInTheDocument()
    cleanup()
    clientMock.post.mockReset()
    clientMock.post.mockRejectedValue({ status: 500, message: 'x', code: 'x' })
    renderLots(ITEMS)
    expect(screen.getByTestId('registry-loading')).toBeInTheDocument()
    expect(await screen.findByTestId('registry-error')).toBeInTheDocument()
    clientMock.post.mockReset()
    fakeServer(clientMock, data())
    fireEvent.click(screen.getByTestId('registry-retry'))
    await row('BOLT')
  })

  it('pages a long list by 25', async () => {
    clientMock.post.mockReset()
    const many = Array.from({ length: 30 }, (_, i) => rec(`id-${i}`, 'catalog_item', { code: `C${String(i).padStart(2, '0')}`, name: `Item ${i}` }))
    fakeServer(clientMock, { catalog_item: many })
    renderLots(ITEMS)
    await row('C00')
    expect(screen.getAllByTestId('registry-row')).toHaveLength(25)
    expect(screen.getByTestId('registry-range')).toHaveTextContent('1-25 of 30')
    fireEvent.click(screen.getByTestId('registry-next'))
    await row('C29')
    expect(screen.getAllByTestId('registry-row')).toHaveLength(5)
  })
})

describe('A9 languages', () => {
  for (const locale of ['ru', 'kk'] as const) {
    it(`renders the title in ${locale}`, async () => {
      vi.stubGlobal('navigator', { ...navigator, languages: [locale], language: locale })
      renderLots(ITEMS)
      expect(await screen.findByRole('heading', { level: 1 })).toHaveTextContent(catalogItemsMessages[locale]['catalog_items.items.title'])
      expect((await screen.findAllByRole('columnheader'))[0]).toHaveTextContent(catalogItemsMessages[locale]['catalog_items.items.col.code'])
    })
  }
})

describe('A10 permission through the real route', () => {
  it('StockRead granted shows the screen; missing shows the forbidden page and sends no query', async () => {
    renderLots(ITEMS, withAtom)
    await row('BOLT')
    cleanup()
    clientMock.post.mockClear()
    const noStock: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['CatalogLotsWrite'] } }
    renderLots(ITEMS, noStock)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    renderLots(ITEMS, withoutAtom)
    expect(clientMock.post).not.toHaveBeenCalledWith('/api/v1/entities/query', expect.anything())
  })
})
