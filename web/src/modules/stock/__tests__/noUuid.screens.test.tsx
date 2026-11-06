// @vitest-environment jsdom
/** T-1378 — no stock screen shows a record id. Every screen is rendered with REAL-SHAPED data: uuid ids, masters with code +
 *  name, a names lookup that answers like the fixed server (record_id values are uuids; anything else is a 500), and a second
 *  pass where the names lookup fails: the text is then "Unknown record", still no uuid. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { noUuidInDom, uuidsInDom } from '@/test-utils/noUuidInDom'
import { isUuid } from '@/lib/references/referenceLabel'
import type { EntityRecord } from '@/types/api'
import { BAL, DOCS, LIST as DOC_LIST, MOV, fakeMasters, rec, renderStock, stockDoc, withPost } from './stockTestKit'
import { LIST as COUNT_LIST, fakeCounts, line, order, renderCounts } from './countsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-nouuid' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), put: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const U = (n: number) => `5b58a738-1c2d-4e3f-8a9b-${String(n).padStart(12, '0')}`
const ID = {
  item1: U(1), item2: U(2), unit: U(3), loc: U(4), uom: U(5), emp: U(6), emp2: U(7), lot: U(8), cp: U(9),
  doc: U(10), order: U(11), entry: U(12), user: U(13),
}

const MASTERS: Record<string, EntityRecord[]> = {
  catalog_item: [rec(ID.item1, { code: 'ITM-1', name: 'Bolt M8', base_uom_id: ID.uom }), rec(ID.item2, { code: 'ITM-2', name: 'Nut M8', base_uom_id: ID.uom })],
  catalog_counterparty: [rec(ID.cp, { code: 'CP-1', name: 'Acme Ltd' })],
  location_node: [rec(ID.loc, { code: 'RACK-01', name: 'Rack 01' })],
  org_unit: [rec(ID.unit, { code: 'MS', name: 'Main store' })],
  org_employee: [rec(ID.emp, { code: 'E-1', full_name: 'Aigul B.' }), rec(ID.emp2, { code: 'E-2', full_name: 'Marat K.' })],
  catalog_lot: [rec(ID.lot, { code: 'LOT-7', item_id: ID.item1 })],
  catalog_uom: [rec(ID.uom, { code: 'PCS', name: 'Piece' })],
}

type Mode = 'ok' | 'namesFail'
let mode: Mode = 'ok'

/** The fixed server: `record_id` takes uuids; the names lookup can be made to fail. */
function serveMasters(base: (path: string, body: Record<string, unknown>) => Promise<unknown>) {
  const orig = base
  clientMock.post.mockImplementation(async (path: string, body: Record<string, unknown>) => {
    if (path !== '/api/v1/entities/query') return orig(path, body)
    const clause = ((body['filters'] ?? []) as { field: string; value: unknown }[]).find((f) => f.field === 'record_id')
    if (clause) {
      if (mode === 'namesFail') throw { status: 500, message: 'x', code: '500' }
      const values = Array.isArray(clause.value) ? clause.value : [clause.value]
      if (!values.every((v) => isUuid(v))) throw { status: 500, message: 'x', code: '500' }
    }
    return orig(path, body)
  })
}

function stockServer(routes: Record<string, unknown>) {
  fakeMasters(clientMock, MASTERS)
  serveMasters(clientMock.post.getMockImplementation()!)
  clientMock.get.mockImplementation(async (path: string) => routes[path] ?? { rows: [], next_cursor: null })
}

const LEG = { sku: ID.item1, location: ID.loc, org_unit: ID.unit, responsible: ID.emp, lot: ID.lot, unit_ref: ID.uom }
const DOC = stockDoc({
  id: ID.doc, header_id: ID.entry, org_unit_id: ID.unit, location_id: ID.loc, responsible_id: ID.emp, counterparty_id: ID.cp,
  state: 'reversed', number: 'RC-2026-0001', posted_at: '2026-11-04T06:00:00Z', posted_by: ID.user, reversed_at: '2026-11-04T07:00:00Z', reversed_by: ID.user,
  lines: [
    { line_id: U(21), line_no: 1, catalog_item_id: ID.item1, catalog_uom_id: ID.uom, catalog_lot_id: ID.lot, quantity: '3', unit_price: '2', line_value: '6' },
    { line_id: U(22), line_no: 2, catalog_item_id: ID.item2, catalog_uom_id: ID.uom, catalog_lot_id: null, quantity: '5' },
  ],
})

beforeEach(() => {
  mode = 'ok'
  for (const m of Object.values(clientMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

/** Waits until the page text no longer shows the loading ellipsis of a name, then asserts no uuid anywhere. */
async function settled(container: HTMLElement, expected: string | RegExp) {
  await waitFor(() => expect(container).toHaveTextContent(expected))
  await waitFor(() => expect(container.textContent).not.toContain('…'))
  expect(uuidsInDom(container)).toEqual([])
  expect(noUuidInDom(container)).toBe(true)
}

describe('N1 stock register screens', () => {
  it('balances: code - title, no uuid', async () => {
    stockServer({ '/api/v1/modules/stock/balances': { ledger_seq: 4, next_cursor: null, rows: [{ ...LEG, quantity: '12.5' }] } })
    const { container } = renderStock(BAL)
    await settled(container, 'ITM-1 - Bolt M8')
    expect(container).toHaveTextContent('RACK-01 - Rack 01')
    expect(container).toHaveTextContent('MS - Main store')
    expect(container).toHaveTextContent('E-1 - Aigul B.')
    expect(container).toHaveTextContent('LOT-7')
    expect(container).toHaveTextContent('PCS')
  })

  it('balances: the history panel shows names, no uuid', async () => {
    const entry = {
      entry_id: ID.entry, posting_seq: 17, cause: 'receipt', reason_code: null, document_type: 'stock_receipt', document_id: ID.doc,
      document_number: 'RCP-2026-000001', event_time: '2026-11-04T18:00:00Z', legs: [{ ...LEG, leg_no: 1, quantity: '5' }],
    }
    stockServer({
      '/api/v1/modules/stock/balances': { ledger_seq: 4, next_cursor: null, rows: [{ ...LEG, quantity: '12.5' }] },
      '/api/v1/modules/stock/movements': { next_cursor: null, rows: [entry] },
    })
    const { container } = renderStock(BAL)
    await settled(container, 'ITM-1 - Bolt M8')
    fireEvent.click(screen.getAllByTestId('datatable-row')[0])
    await screen.findByTestId('history-doc-link')
    await settled(container, 'ITM-1 - Bolt M8')
  })

  it('movements: a row with its legs open', async () => {
    const entry = {
      entry_id: ID.entry, posting_seq: 17, cause: 'transfer', reason_code: null, document_type: 'stock_transfer', document_id: ID.doc,
      event_time: '2026-11-04T18:00:00Z', legs: [{ ...LEG, leg_no: 1, quantity: '-5' }, { ...LEG, leg_no: 2, quantity: '5' }],
    }
    stockServer({ '/api/v1/modules/stock/movements': { next_cursor: null, rows: [entry] } })
    const { container } = renderStock(MOV)
    fireEvent.click((await screen.findAllByTestId('journal-row'))[0])
    // the journal draws "code - title" as code, separator and title spans
    await settled(container, /ITM-1\W+Bolt M8/)
    expect(container).toHaveTextContent(/RACK-01\W+Rack 01/)
  })

  it('documents list and the document page (header and lines)', async () => {
    stockServer({
      [DOCS]: { next_cursor: null, rows: [{ id: ID.doc, kind: 'receipt', state: 'posted', number: 'RC-2026-0001', org_unit_id: ID.unit, event_time: '2026-11-04T05:00:00Z' }] },
      [`${DOCS}/${ID.doc}`]: DOC,
    })
    const list = renderStock(DOC_LIST)
    await settled(list.container, 'MS - Main store')
    cleanup()
    const page = renderStock(`${DOC_LIST}/${ID.doc}`)
    await settled(page.container, 'ITM-2 - Nut M8')
    expect(page.container).toHaveTextContent('CP-1 - Acme Ltd')
    expect(page.container).toHaveTextContent('LOT-7')
    expect(page.container).toHaveTextContent('Another user')
  })

  it('new document form: select options read "code - title"', async () => {
    stockServer({})
    const { container } = renderStock(`${DOC_LIST}/new`, withPost)
    await screen.findByRole('option', { name: 'MS - Main store' })
    await screen.findByRole('option', { name: 'RACK-01 - Rack 01' })
    await screen.findByRole('option', { name: 'E-1 - Aigul B.' })
    expect(noUuidInDom(container)).toBe(true)
  })

  it('names lookup failing: "Unknown record", still no uuid', async () => {
    mode = 'namesFail'
    stockServer({
      [`${DOCS}/${ID.doc}`]: DOC,
      '/api/v1/modules/stock/balances': { ledger_seq: 4, next_cursor: null, rows: [{ ...LEG, quantity: '12.5' }] },
    })
    const page = renderStock(`${DOC_LIST}/${ID.doc}`)
    await settled(page.container, 'Unknown record')
    cleanup()
    const bal = renderStock(BAL)
    await settled(bal.container, 'Unknown record')
  })
})

describe('N2 count screens', () => {
  const COUNTS = {
    ...MASTERS,
  }
  const ORDER = order({ id: ID.order, org_unit_id: ID.unit, chair_employee_id: ID.emp, member_employee_ids: [ID.emp2], location_ids: [ID.loc], status: 'counted', number: 'CO-2026-0001', sheet_document_id: ID.doc, differences_document_id: U(31), entry_id: ID.entry, posting_state: 'posted' })
  const LINE = line(1, { location_id: ID.loc, catalog_item_id: ID.item1, catalog_lot_id: ID.lot, responsible_employee_id: ID.emp, unit_ref: ID.uom, counted_quantity: '8' })
  const DIFF = {
    number: 'CD-2026-0001', version_no: 1, issued_at: '2026-11-10T10:00:00Z', content_hash: 'h',
    lines: [{ line_no: 1, location_id: ID.loc, catalog_item_id: ID.item1, catalog_lot_id: ID.lot, responsible_employee_id: ID.emp, unit_ref: ID.uom, book_quantity: '10', counted_quantity: '8', difference: '-2', direction: 'shortage' }],
  }

  function countServer() {
    fakeCounts(clientMock, { orders: [ORDER], linePages: [[LINE]], differences: DIFF, masters: COUNTS })
    serveMasters(clientMock.post.getMockImplementation()!)
  }

  it('list, detail and sheet', async () => {
    countServer()
    const list = renderCounts(COUNT_LIST)
    await settled(list.container, 'MS - Main store')
    cleanup()
    const detail = renderCounts(`${COUNT_LIST}/${ID.order}`)
    await settled(detail.container, 'ITM-1 - Bolt M8')
    expect(detail.container).toHaveTextContent('E-2 - Marat K.')
  })

  it('differences sheet and the posting panel', async () => {
    countServer()
    const { container } = renderCounts(`${COUNT_LIST}/${ID.order}`)
    await screen.findByTestId('differences-table')
    await settled(container, 'ITM-1 - Bolt M8')
  })

  it('count screens with the names lookup failing show "Unknown record"', async () => {
    mode = 'namesFail'
    countServer()
    const { container } = renderCounts(`${COUNT_LIST}/${ID.order}`)
    await settled(container, 'Unknown record')
  })
})

describe('N3 kk and ru render without a uuid', () => {
  it.each(['ru', 'kk'] as const)('document page in %s', async (loc) => {
    useUiLocaleStore.getState().setLocaleTransient(loc)
    stockServer({ [`${DOCS}/${ID.doc}`]: DOC })
    const { container } = renderStock(`${DOC_LIST}/${ID.doc}`)
    await settled(container, 'ITM-2 - Nut M8')
  })
})
