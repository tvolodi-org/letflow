// @vitest-environment jsdom
/** M1–M5 — GH 3767 / REQ-724; M7–M9, JP — T-1422 (GATE B R12): the movements screen on the journal component (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { QueryClientProvider, QueryClient } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import MovementsPage from '../register/MovementsPage'
import { MOV, fakeMasters, renderStock, routeCalls } from './stockTestKit'
import { saveBlob } from '../register/saveBlob'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('../register/saveBlob', () => ({ saveBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const LEG = { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: 't1', unit_ref: 'm1' }
const ENTRY = {
  entry_id: 'en1',
  posting_seq: 17,
  cause: 'transfer',
  reason_code: 'wrong_quantity',
  document_type: 'stock_transfer',
  document_id: 'd1',
  event_time: '2026-11-04T18:00:00Z',
  legs: [
    { ...LEG, leg_no: 1, quantity: '-5' },
    { ...LEG, leg_no: 2, location: 'l1', quantity: '5' },
  ],
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  clientMock.getBlob.mockReset()
  vi.mocked(saveBlob).mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ next_cursor: null, rows: [ENTRY] })
})
afterEach(() => cleanup())

const DOC_UUID = '5b58a738-1c2d-4e3f-8a9b-000000000010'
const rowsOf = async () => await screen.findAllByTestId('journal-row')
const stockGet = (routes: Record<string, unknown>) =>
  clientMock.get.mockImplementation(async (path: string) => {
    if (path in routes) return routes[path]
    throw { status: 404, message: 'x', code: '404' }
  })

describe('T-1439 filters drawer at first render', () => {
  it('initialFiltersOpen opens the filters; closed by default', async () => {
    const view = (open: boolean) => (
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter><MovementsPage initialFiltersOpen={open} /></MemoryRouter>
      </QueryClientProvider>
    )
    const first = render(view(false))
    await rowsOf()
    expect(document.querySelector('[data-filters]')?.getAttribute('data-filters')).toBe('closed')
    first.unmount()
    render(view(true))
    await rowsOf()
    expect(document.querySelector('[data-filters]')?.getAttribute('data-filters')).toBe('open')
  })
})

describe('M1 query keys', () => {
  it('filters send only cause, document_type, document_id, from_seq and to_seq', async () => {
    renderStock(MOV)
    await rowsOf()
    expect(routeCalls(clientMock, 'movements')).toEqual([{}])
    fireEvent.change(screen.getByLabelText('Cause'), { target: { value: 'receipt' } })
    await waitFor(() => expect(routeCalls(clientMock, 'movements').at(-1)).toEqual({ cause: 'receipt' }))
    fireEvent.change(screen.getByLabelText('Document type'), { target: { value: 'stock_receipt' } })
    fireEvent.change(screen.getByLabelText('Document'), { target: { value: 'doc-9' } })
    fireEvent.change(screen.getByLabelText('From posting no.'), { target: { value: '3x' } })
    fireEvent.change(screen.getByLabelText('To posting no.'), { target: { value: '9' } })
    await waitFor(() =>
      expect(routeCalls(clientMock, 'movements').at(-1)).toEqual({
        cause: 'receipt', document_type: 'stock_receipt', document_id: 'doc-9', from_seq: '3', to_seq: '9',
      }),
    )
  })

  it('presets the document from the URL query key', async () => {
    renderStock(`${MOV}?document_id=d1`)
    await rowsOf()
    expect(screen.getByLabelText('Document')).toHaveValue('d1')
    expect(routeCalls(clientMock, 'movements')).toEqual([{ document_id: 'd1' }])
  })
})

describe('M2 range', () => {
  it('a from above to is not sent and the field is marked', async () => {
    renderStock(MOV)
    await rowsOf()
    fireEvent.change(screen.getByLabelText('From posting no.'), { target: { value: '9' } })
    fireEvent.change(screen.getByLabelText('To posting no.'), { target: { value: '3' } })
    expect((await screen.findAllByText('The first number is above the last.')).length).toBeGreaterThan(0)
    expect(screen.getByLabelText('From posting no.')).toHaveAttribute('aria-invalid', 'true')
    expect(routeCalls(clientMock, 'movements').some((p) => 'from_seq' in p && 'to_seq' in p)).toBe(false)
  })
})

describe('M3 rows and legs (J1: list left, legs of the selected row in the pane)', () => {
  it('shows the row cells, then the legs of the clicked row in the pane with names and signs', async () => {
    renderStock(MOV)
    const [row] = await rowsOf()
    expect(screen.getByTestId('journal')).toHaveAttribute('data-layout', 'split')
    expect(screen.getByTestId('journal')).toHaveAttribute('data-variant', 'v1')
    expect(within(row).getAllByText('Transfer')).toHaveLength(2)
    expect(row).toHaveTextContent('Nov 4, 2026 23:00')
    expect(row).toHaveTextContent('5 pcs')
    expect(row).not.toHaveTextContent('-5')
    expect(screen.getByTestId('journal-blank')).toBeInTheDocument()
    fireEvent.click(row)
    const legs = await screen.findAllByTestId('journal-leg')
    expect(legs).toHaveLength(2)
    await waitFor(() => expect(legs[0]).toHaveTextContent('Bolt M8'))
    expect(legs[0]).toHaveTextContent('Shelf A')
    expect(legs[0]).toHaveTextContent('Held by Aigul B.')
    expect(legs[0]).toHaveTextContent('−5 pcs')
    expect(legs[1]).toHaveTextContent('+5 pcs')
    expect(row).toHaveAttribute('aria-selected', 'true')
  })
})

describe('M-2 document number and kind', () => {
  it('shows "number - kind" as a link to the document; no number keeps the kind only', async () => {
    clientMock.get.mockResolvedValue({
      next_cursor: null,
      rows: [
        { ...ENTRY, document_type: 'stock_receipt', document_id: 'd1', document_number: 'RCP-2026-000001' },
        { ...ENTRY, entry_id: 'en2', posting_seq: 18, document_type: 'stock_receipt', document_id: null, document_number: null },
      ],
    })
    renderStock(MOV)
    const link = await screen.findByTestId('journal-doc-link')
    expect(link).toHaveTextContent('RCP-2026-000001 - Receipt')
    expect(link).toHaveAttribute('href', '/admin/stock/documents/d1')
    const plain = (await rowsOf())[1]
    expect(plain).toHaveTextContent('Receipt')
    expect(within(plain).queryByTestId('journal-doc-link')).not.toBeInTheDocument()
  })

  it('Q-2: a leg quantity shows at most 3 decimals, trailing zeros trimmed', async () => {
    clientMock.get.mockResolvedValue({
      next_cursor: null,
      rows: [{ ...ENTRY, legs: [{ ...LEG, leg_no: 1, quantity: '40.000000000' }, { ...LEG, leg_no: 2, quantity: '-12.500000000' }] }],
    })
    renderStock(MOV)
    fireEvent.click((await rowsOf())[0])
    const legs = await screen.findAllByTestId('journal-leg')
    await waitFor(() => expect(legs[0]).toHaveTextContent(/\+40 pcs$/))
    expect(legs[0]).not.toHaveTextContent('40.0')
    expect(legs[1]).toHaveTextContent('−12.5 pcs')
    expect(legs[1]).not.toHaveTextContent('12.50')
  })
})

describe('M4 masked leg', () => {
  it('shows quantity, unit and the hidden unit text and no slot', async () => {
    clientMock.get.mockResolvedValue({
      next_cursor: null,
      rows: [{ ...ENTRY, legs: [{ leg_no: 1, quantity: '-4', unit_ref: 'm1', masked: true }] }],
    })
    renderStock(MOV)
    fireEvent.click((await rowsOf())[0])
    const leg = await screen.findByTestId('journal-leg')
    expect(leg).toHaveTextContent('Hidden unit')
    expect(leg).toHaveTextContent('−4')
    await waitFor(() => expect(leg).toHaveTextContent('pcs'))
    expect(leg).not.toHaveTextContent('Bolt M8')
  })
})

describe('M5 paging', () => {
  it('Load more sends the cursor and appends', async () => {
    clientMock.get.mockImplementation(async (_p: string, params: Record<string, string>) =>
      params?.cursor === 'c2'
        ? { next_cursor: null, rows: [{ ...ENTRY, entry_id: 'en2', posting_seq: 16 }] }
        : { next_cursor: 'c2', rows: [ENTRY] },
    )
    renderStock(MOV)
    fireEvent.click(await screen.findByTestId('load-more'))
    await waitFor(() => expect(screen.getAllByTestId('journal-row')).toHaveLength(2))
    expect(routeCalls(clientMock, 'movements').at(-1)).toEqual({ cursor: 'c2' })
    expect(screen.queryByTestId('load-more')).not.toBeInTheDocument()
  })
})

describe('W5 REQ-718 the count.differences document type', () => {
  const WORD = { en: 'Count differences', ru: 'Расхождения инвентаризации', kk: 'Түгендеу айырмашылықтары' } as const
  afterEach(() => useUiLocaleStore.getState().reloadFromEnvironment())

  for (const lang of ['en', 'ru', 'kk'] as const) {
    it(`the Document column shows the word, not the raw type, in ${lang}`, async () => {
      useUiLocaleStore.getState().setLocaleTransient(lang)
      clientMock.get.mockResolvedValue({ next_cursor: null, rows: [{ ...ENTRY, cause: 'count_difference', document_type: 'count.differences' }] })
      renderStock(MOV)
      const row = (await rowsOf())[0]
      expect(within(row).getByText(WORD[lang])).toBeInTheDocument()
      expect(within(row).queryByText('count.differences')).toBeNull()
    })
  }
})

describe('M6 REQ-718 the count_difference cause', () => {
  const EXPECTED = { en: 'Count difference', ru: 'Расхождение по инвентаризации', kk: 'Түгендеу айырмасы' } as const
  afterEach(() => useUiLocaleStore.getState().reloadFromEnvironment())

  for (const lang of ['en', 'ru', 'kk'] as const) {
    it(`is a filter option and a table label in ${lang}`, async () => {
      useUiLocaleStore.getState().setLocaleTransient(lang)
      clientMock.get.mockResolvedValue({ next_cursor: null, rows: [{ ...ENTRY, cause: 'count_difference', document_type: 'count.differences' }] })
      renderStock(MOV)
      const row = (await rowsOf())[0]
      expect(within(row).getByText(EXPECTED[lang])).toBeInTheDocument()
      const option = screen.getAllByRole('option').find((o) => (o as HTMLOptionElement).value === 'count_difference')
      expect(option).toHaveTextContent(EXPECTED[lang])
    })
  }
})

describe('R1 / M4 date format per language (T-1381, real row shape)', () => {
  afterEach(() => useUiLocaleStore.getState().reloadFromEnvironment())
  // event_time 2026-11-04T18:00:00Z is 23:00 on the same day in Asia/Almaty (UTC+5).
  const EXPECTED = { en: 'Nov 4, 2026 23:00', ru: '04-11-2026 23:00', kk: '04-11-2026 23:00' } as const
  for (const lang of ['en', 'ru', 'kk'] as const) {
    it(`${lang}: the time cell reads ${EXPECTED[lang]}`, async () => {
      useUiLocaleStore.getState().setLocaleTransient(lang)
      renderStock(MOV)
      expect((await rowsOf())[0]).toHaveTextContent(EXPECTED[lang])
    })
  }
})

describe('M5x xlsx export', () => {
  it('sends the current filters with format xlsx and no cursor, then saves the file', async () => {
    clientMock.getBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x', contentDisposition: null })
    renderStock(MOV)
    await rowsOf()
    fireEvent.change(screen.getByLabelText('Cause'), { target: { value: 'receipt' } })
    await waitFor(() => expect(routeCalls(clientMock, 'movements').at(-1)).toEqual({ cause: 'receipt' }))
    fireEvent.click(screen.getByTestId('journal-export'))
    await waitFor(() => expect(saveBlob).toHaveBeenCalledTimes(1))
    expect(clientMock.getBlob).toHaveBeenCalledWith('/api/v1/modules/stock/movements', { cause: 'receipt', format: 'xlsx' })
    expect(vi.mocked(saveBlob).mock.calls[0][1]).toBe('stock-movements.xlsx')
  })

  it('a failed export shows a banner', async () => {
    clientMock.getBlob.mockRejectedValue({ status: 500, message: 'x', code: '500' })
    renderStock(MOV)
    await rowsOf()
    fireEvent.click(screen.getByTestId('journal-export'))
    expect(await screen.findByText('The file could not be exported. Try again.')).toBeInTheDocument()
  })
})

describe('M3p people and references: names, never ids', () => {
  it('Posted by comes from the document read; absent shows a dash; no id and no "Another user"', async () => {
    const row = { ...ENTRY, document_id: DOC_UUID, document_number: 'TRF-2026-000002' }
    stockGet({
      '/api/v1/modules/stock/movements': { next_cursor: null, rows: [row] },
      [`/api/v1/modules/stock/documents/${DOC_UUID}`]: { id: DOC_UUID, posted_by: 'u-1', posted_by_label: 'Aigul B. (E-1)' },
    })
    const { container } = renderStock(MOV)
    fireEvent.click((await rowsOf())[0])
    const by = await screen.findByText('Aigul B. (E-1)')
    expect(by.closest('[data-field="by"]')).toBeInTheDocument()
    expect(container.textContent).not.toContain(DOC_UUID)
    expect(container.textContent).not.toContain('Another user')
  })

  it('without a poster label (no permission, or not a numbered document) the field is a dash', async () => {
    stockGet({ '/api/v1/modules/stock/movements': { next_cursor: null, rows: [{ ...ENTRY, document_id: DOC_UUID }] } })
    renderStock(MOV)
    fireEvent.click((await rowsOf())[0])
    const field = await waitFor(() => {
      const f = document.querySelector('[data-field="by"]')
      if (!f) throw new Error('no field')
      return f
    })
    expect(field).toHaveTextContent('—')
  })
})

describe('M7 states', () => {
  it('empty: text; filtered empty: no match with a clear button', async () => {
    clientMock.get.mockResolvedValue({ next_cursor: null, rows: [] })
    renderStock(MOV)
    expect(await screen.findByTestId('journal-empty')).toHaveTextContent('No movements found.')
    fireEvent.change(screen.getByLabelText('Cause'), { target: { value: 'issue' } })
    expect(await screen.findByTestId('journal-nomatch')).toHaveTextContent('No movement matches the filters.')
    fireEvent.click(screen.getByTestId('journal-clear-empty'))
    await waitFor(() => expect(screen.getByLabelText('Cause')).toHaveValue(''))
  })

  it('error: banner with Retry that loads again', async () => {
    clientMock.get.mockRejectedValueOnce({ status: 500, message: 'x', code: '500' })
    renderStock(MOV)
    const state = await screen.findByTestId('journal-error')
    fireEvent.click(within(state).getByRole('button', { name: 'Retry' }))
    expect((await rowsOf()).length).toBe(1)
  })

  it('loading: a skeleton before the first answer', async () => {
    clientMock.get.mockImplementation(() => new Promise(() => undefined))
    renderStock(MOV)
    expect(await screen.findByTestId('journal-loading')).toBeInTheDocument()
  })
})

describe('M8 reversal status and links', () => {
  it('shows Reversed / Reversal pills with the other document number and walks to it', async () => {
    clientMock.get.mockResolvedValue({
      next_cursor: null,
      rows: [
        { ...ENTRY, entry_id: 'rv', posting_seq: 19, cause: 'reversal', reverses_entry_id: 'en1', document_number: 'REV-2026-000001', document_type: 'stock_reversal' },
        { ...ENTRY, entry_id: 'en1', document_number: 'TRF-2026-000002' },
      ],
    })
    renderStock(MOV)
    const [rev, orig] = await rowsOf()
    expect(rev).toHaveTextContent('Reversal')
    expect(rev.querySelector('[title="Reversal of TRF-2026-000002"]')).not.toBeNull()
    expect(orig).toHaveTextContent('Reversed')
    expect(orig.querySelector('[title="Reversed by REV-2026-000001"]')).not.toBeNull()
    fireEvent.click(orig)
    fireEvent.click(await screen.findByTestId('journal-goto'))
    await waitFor(() => expect(rev).toHaveAttribute('aria-selected', 'true'))
  })
})

/** jsdom has no layout: give the journal element a width. */
function areaWidth(w: number) {
  const real = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'clientWidth')
  vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockImplementation(function (this: HTMLElement) {
    return this.getAttribute('data-testid') === 'journal' ? w : ((real?.get?.call(this) as number) ?? 0)
  })
}

describe('J3 wide: operations and legs table side by side', () => {
  afterEach(() => vi.restoreAllMocks())
  it('J3-2 a row click at a wide area only selects (no inline legs), the legs table shows in the pane', async () => {
    areaWidth(1200)
    renderStock(MOV)
    const [row] = await rowsOf()
    fireEvent.click(row)
    expect(row).toHaveAttribute('aria-selected', 'true')
    expect(screen.queryByTestId('journal-legsrow')).not.toBeInTheDocument()
    const table = await screen.findByTestId('journal-legtable')
    expect(within(table).getAllByTestId('journal-legrow')).toHaveLength(2)
    expect(screen.getAllByRole('separator').length).toBeGreaterThan(0)
  })

  it('J3-2 an area of 800 px expands inline even when the window is wide (matchMedia says wide)', async () => {
    vi.stubGlobal('matchMedia', (q: string) => ({ matches: false, media: q, addEventListener: vi.fn(), removeEventListener: vi.fn() }))
    areaWidth(800)
    renderStock(MOV)
    const [row] = await rowsOf()
    fireEvent.click(row)
    expect(await screen.findByTestId('journal-legsrow')).toBeInTheDocument()
    vi.unstubAllGlobals()
  })

  it('J3-7 the operations table has a Location column with the first place', async () => {
    renderStock(MOV)
    const [row] = await rowsOf()
    await waitFor(() => expect(row.querySelector('.c-loc')).toHaveTextContent('Shelf A'))
    expect(screen.getByRole('columnheader', { name: /Location/ })).toBeInTheDocument()
  })
})

describe('JP narrow behaviour (V1 inline legs, Details opens the full-screen pane)', () => {
  afterEach(() => vi.restoreAllMocks())
  // the layout follows the journal AREA (container query), not the window: no matchMedia is involved
  const narrow = () => areaWidth(500)

  it('a row click expands the legs inline; Details opens the pane; Back closes it and focuses the row', async () => {
    narrow()
    renderStock(MOV)
    const [row] = await rowsOf()
    fireEvent.click(row)
    expect(row).toHaveAttribute('aria-expanded', 'true')
    expect(await screen.findByTestId('journal-legsrow')).toBeInTheDocument()
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'closed')
    fireEvent.click(screen.getByTestId('journal-details-btn'))
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'open')
    fireEvent.click(screen.getByTestId('journal-back'))
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'closed')
    await waitFor(() => expect(row).toHaveFocus())
  })

  it('previous / next walk the loaded rows and stop at the ends', async () => {
    narrow()
    clientMock.get.mockResolvedValue({ next_cursor: null, rows: [ENTRY, { ...ENTRY, entry_id: 'en2', posting_seq: 16 }] })
    renderStock(MOV)
    const [first] = await rowsOf()
    fireEvent.click(first)
    fireEvent.click(await screen.findByTestId('journal-details-btn'))
    expect(screen.getByTestId('journal-pos')).toHaveTextContent('1 of 2')
    expect(screen.getByTestId('journal-prev')).toBeDisabled()
    fireEvent.click(screen.getByTestId('journal-next'))
    expect(screen.getByTestId('journal-pos')).toHaveTextContent('2 of 2')
    expect(screen.getByTestId('journal-next')).toBeDisabled()
    fireEvent.click(screen.getByTestId('journal-prev'))
    expect(screen.getByTestId('journal-pos')).toHaveTextContent('1 of 2')
  })

  it('Escape closes the open details', async () => {
    narrow()
    renderStock(MOV)
    fireEvent.click((await rowsOf())[0])
    fireEvent.click(await screen.findByTestId('journal-details-btn'))
    fireEvent.keyDown(screen.getByTestId('journal-back'), { key: 'Escape' })
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'closed')
  })
})

describe('JW wide screen (T-1439 R12b: Details button opens the full-screen view)', () => {
  const TWO = { next_cursor: null, rows: [ENTRY, { ...ENTRY, entry_id: 'en2', posting_seq: 16 }] }

  it('D2 Details opens the pane with Back focused; Back closes it and focuses the row', async () => {
    clientMock.get.mockResolvedValue(TWO)
    renderStock(MOV)
    const [row] = await rowsOf()
    fireEvent.click(row)
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'closed')
    fireEvent.click(await screen.findByTestId('journal-open-full'))
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'open')
    await waitFor(() => expect(screen.getByTestId('journal-back')).toHaveFocus())
    fireEvent.click(screen.getByTestId('journal-back'))
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'closed')
    await waitFor(() => expect(row).toHaveFocus())
  })

  it('D3 previous / next walk the rows and stop at the ends', async () => {
    clientMock.get.mockResolvedValue(TWO)
    renderStock(MOV)
    fireEvent.click((await rowsOf())[0])
    fireEvent.click(await screen.findByTestId('journal-open-full'))
    expect(screen.getByTestId('journal-pos')).toHaveTextContent('1 of 2')
    expect(screen.getByTestId('journal-prev')).toBeDisabled()
    fireEvent.click(screen.getByTestId('journal-next'))
    expect(screen.getByTestId('journal-pos')).toHaveTextContent('2 of 2')
    expect(screen.getByTestId('journal-next')).toBeDisabled()
  })

  it('D4 Escape closes the full-screen view', async () => {
    renderStock(MOV)
    fireEvent.click((await rowsOf())[0])
    fireEvent.click(await screen.findByTestId('journal-open-full'))
    fireEvent.keyDown(screen.getByTestId('journal-back'), { key: 'Escape' })
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'closed')
  })

  it('D5 the view closes when the selected operation leaves the list', async () => {
    clientMock.get.mockImplementation(async (_p: string, params?: Record<string, string>) =>
      params?.['cause'] === 'receipt' ? { next_cursor: null, rows: [] } : { next_cursor: null, rows: [ENTRY] })
    renderStock(MOV)
    fireEvent.click((await rowsOf())[0])
    fireEvent.click(await screen.findByTestId('journal-open-full'))
    expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'open')
    fireEvent.change(screen.getByLabelText('Cause'), { target: { value: 'receipt' } })
    await waitFor(() => expect(screen.getByTestId('journal')).toHaveAttribute('data-detail', 'closed'))
  })
})
