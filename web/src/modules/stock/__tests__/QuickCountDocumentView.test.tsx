// @vitest-environment jsdom
/** T-2290 / REQ-854 AC1: the quick count document screen shows book, counted and difference; every ledger cause has a label. */
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { stockMessages } from '../stockMessages'
import { CAUSES, DOCUMENT_TYPES } from '../register/stockRegisterModel'
import { LIST, fakeDocument, fakeMasters, renderStock, stockDoc, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), postWithHeaders: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

describe('document screen of a quick count', () => {
  it('GH 4873: a count equal to the book reads Confirmed on the screen, as in the list', async () => {
    fakeDocument(clientMock, stockDoc({
      kind: 'quick_count', state: 'confirmed', number: 'QCT-2026-000002', event_time: null, note: null,
      lines: [{ line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '10', book_quantity: '10', counted_quantity: '10', difference: '0' }],
    }))
    renderStock(`${LIST}/d1`, withPost)
    expect((await screen.findAllByText(stockMessages.en['stock.doc.state.confirmed']!)).length).toBeGreaterThan(0)
    expect(screen.queryByText('confirmed')).not.toBeInTheDocument()
  })

  it('shows the book quantity, the counted quantity and the difference of the line', async () => {
    fakeDocument(clientMock, stockDoc({
      kind: 'quick_count', state: 'issued', number: 'QCT-2026-000001', event_time: null, note: null,
      lines: [{ line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '7', book_quantity: '10', counted_quantity: '7', difference: '-3' }],
    }))
    renderStock(`${LIST}/d1`, withPost)
    const card = await screen.findByTestId('lines-card')
    const heads = Array.from(card.querySelectorAll('th')).map((h) => h.textContent ?? '')
    expect(heads.some((h) => h.startsWith('Book quantity'))).toBe(true)
    expect(heads.some((h) => h.startsWith('Counted'))).toBe(true)
    expect(heads.some((h) => h.startsWith('Difference'))).toBe(true)
    const row = card.querySelector('tbody tr')!
    expect(row.textContent).toContain('10')
    expect(row.textContent).toContain('7')
    expect(row.textContent).toMatch(/[-−]3/)
  })

  it('labels the document kind and the reason instead of showing the raw codes', async () => {
    fakeDocument(clientMock, stockDoc({
      kind: 'quick_count', state: 'issued', number: 'QCT-2026-000001', event_time: null, note: null, reason_code: 'recount',
      lines: [{ line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '7', book_quantity: '10', counted_quantity: '7', difference: '-3' }],
    }))
    renderStock(`${LIST}/d1`, withPost)
    await screen.findByTestId('lines-card')
    expect(screen.queryByText('quick_count')).toBeNull()
    expect(screen.queryByText('recount')).toBeNull()
    expect(screen.getAllByText('Recount').length).toBeGreaterThan(0)
  })
})

describe('cause labels', () => {
  // The causes the ledger can write are the keys of `causes: %{` in the stock module declaration, plus `reversal`
  // (posted by the reversal path, not declared there).
  const source = readFileSync(resolve(__dirname, '../../../../../lib/letflow/modules/stock/stock.ex'), 'utf8')
  const block = /causes: %\{([\s\S]*?)\n\s{8}\},\n\s+key_bounds/.exec(source)![1]!
  const declared = [...block.matchAll(/^\s+"([a-z_]+)" =>/gm)].map((m) => m[1]!)

  it('reads the declared causes from the module source', () => {
    expect(declared).toEqual(expect.arrayContaining(['opening_negative', 'count_set', 'kind_change_out']))
  })

  it.each(['en', 'ru', 'kk'] as const)('every ledger cause is a filter option with a label in %s', (lang) => {
    for (const cause of [...declared, 'reversal']) {
      expect(CAUSES as readonly string[]).toContain(cause)
      const label = stockMessages[lang][`stock.cause.${cause}`]
      expect(label, `${lang} ${cause}`).toBeTruthy()
      expect(label).not.toBe(cause)
    }
  })

  it.each(['en', 'ru', 'kk'] as const)('the quick count document type is a filter option with a label in %s', (lang) => {
    expect(DOCUMENT_TYPES as readonly string[]).toContain('stock_quick_count')
    const label = stockMessages[lang]['stock.docType.stock_quick_count']
    expect(label).toBeTruthy()
    expect(label).not.toBe('stock_quick_count')
  })
})
