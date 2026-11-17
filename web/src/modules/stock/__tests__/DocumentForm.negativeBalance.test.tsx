// @vitest-environment jsdom
/** REQ-838: a lowering line warns when its exact balance key would go below zero; the warning never blocks an action. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import type { AccessState } from '@/auth/access/types'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { BalanceRow } from '../register/stock.api'
import { DocumentForm } from '../documents/DocumentForm'
import type { StockDocument } from '../documents/documents.api'
import { StockIntlProvider } from '../StockIntlProvider'
import { stockMessages } from '../stockMessages'
import { DOCS, LIST, MASTERS, fakeMasters, rec, renderStock, routeCalls, stockDoc, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const RULES = '/api/v1/modules/stock/posting-rules'
const BALANCES = '/api/v1/modules/stock/balances'
type Locale = 'en' | 'ru' | 'kk'
type Options = { rule?: 'allowed' | 'refused'; rows?: BalanceRow[]; balanceError?: boolean }

const line = (quantity: string, lineNo = 1) => ({
  line_id: `line-${lineNo}`, line_no: lineNo, catalog_item_id: 'i1', catalog_uom: 'ignored', catalog_uom_id: 'm1', catalog_lot_id: null, quantity,
})
const onHand = (quantity = '5'): BalanceRow => ({
  sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: null, unit_ref: 'm1', quantity,
})
const issue = (quantity = '7') => stockDoc({ kind: 'issue', lines: [line(quantity)] })
const twoSide = (kind: 'transfer' | 'hand_over' | 'return') => stockDoc({
  kind,
  org_unit_id: kind === 'return' ? 'u2' : 'u1',
  from_org_unit_id: kind === 'return' ? 'u1' : null,
  from_location_id: 'l1', from_responsible_id: 'e1',
  to_org_unit_id: 'u2', to_location_id: 'l2', to_responsible_id: 'e2',
  lines: [line('4')],
})
const postOnly: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['StockPost'] } }
const calls = (path: string) => clientMock.get.mock.calls.filter(([p]) => p === path)

function answerApi(doc: Record<string, unknown>, options: Options = {}) {
  clientMock.get.mockImplementation(async (path: string) => {
    if (path === `${DOCS}/d1`) return doc
    if (path === RULES) return { negative_balance: options.rule ?? 'allowed' }
    if (path === BALANCES) {
      if (options.balanceError) throw { status: 500, message: 'read failed' }
      return { rows: options.rows ?? [onHand()], next_cursor: null }
    }
    return { rows: [], next_cursor: null }
  })
}

async function openDraft(access: AccessState = withPost, locale: Locale = 'en') {
  useUiLocaleStore.getState().setLocaleTransient(locale)
  renderStock(`${LIST}/d1`, access)
  const messages = stockMessages[locale]
  // Issue stays enabled on the view; entering the warning-bearing edit form must not change the action model.
  fireEvent.click(await screen.findByRole('button', { name: messages['stock.doc.action.edit'] }))
  await screen.findByTestId('document-form')
  return messages
}

beforeEach(() => {
  for (const mock of Object.values(clientMock)) mock.mockReset()
  fakeMasters(clientMock, {
    ...MASTERS,
    org_unit: [rec('u1', { name: 'Main store' }), rec('u2', { name: 'Branch store' })],
    location_node: [rec('l1', { name: 'Shelf A' }), rec('l2', { name: 'Shelf B' })],
    org_employee: [rec('e1', { full_name: 'Aigul B.' }), rec('e2', { full_name: 'Marat K.' })],
  })
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

describe('REQ-838 criterion 1: issue totals, exact threshold and locales', () => {
  it.each(['en', 'ru', 'kk'] as const)('%s: 7 against 5 warns and Save/Issue stay enabled', async (locale) => {
    const doc = issue('7')
    answerApi(doc)
    useUiLocaleStore.getState().setLocaleTransient(locale)
    renderStock(`${LIST}/d1`, withPost)
    const messages = stockMessages[locale]
    expect(await screen.findByRole('button', { name: messages['stock.doc.action.issue'] })).toBeEnabled()
    fireEvent.click(screen.getByRole('button', { name: messages['stock.doc.action.edit'] }))
    await screen.findByTestId('document-form')
    expect(await screen.findByText(messages['stock.doc.negativeBalance'])).toBeInTheDocument()
    expect(screen.getByTestId('negative-balance-warning')).toHaveAttribute('data-line', '1')
    expect(screen.getByRole('button', { name: messages['stock.doc.save'] })).toBeEnabled()
  })

  it('5 against 5 does not warn', async () => {
    const doc = issue('5')
    answerApi(doc)
    await openDraft()
    await waitFor(() => expect(calls(BALANCES)).toHaveLength(1))
    await act(async () => undefined)
    expect(screen.queryByTestId('negative-balance-warning')).not.toBeInTheDocument()
  })

  it('two lines of 3 on one key holding 5 both warn, with one exact-key balance read', async () => {
    const doc = stockDoc({ kind: 'issue', lines: [line('3', 1), line('3', 2)] })
    answerApi(doc)
    await openDraft()
    await waitFor(() => expect(screen.getAllByTestId('negative-balance-warning')).toHaveLength(2))
    expect(screen.getAllByTestId('negative-balance-warning').map((el) => el.getAttribute('data-line'))).toEqual(['1', '2'])
    expect(routeCalls(clientMock, 'balances')).toEqual([{ sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: '', limit: '1' }])
  })
})

describe('REQ-838 criterion 2: every lowering kind and absent keys', () => {
  it.each(['transfer', 'hand_over', 'return'] as const)('%s: 4 from the From key holding 1 warns', async (kind) => {
    const doc = twoSide(kind)
    answerApi(doc, { rows: [onHand('1')] })
    await openDraft()
    expect(await screen.findByText(stockMessages.en['stock.doc.negativeBalance'])).toBeInTheDocument()
    expect(routeCalls(clientMock, 'balances')[0]).toMatchObject({ sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: '' })
  })

  it('write off: 2 from an absent key warns (the absent key is zero)', async () => {
    const doc = stockDoc({ kind: 'write_off', reason_code: 'lost', lines: [line('2')] })
    answerApi(doc, { rows: [] })
    await openDraft()
    expect(await screen.findByText(stockMessages.en['stock.doc.negativeBalance'])).toBeInTheDocument()
  })

  it.each(['receipt', 'opening'] as const)('%s never warns and does not read the rule', async (kind) => {
    const doc = stockDoc({
      kind,
      lines: [{ ...line('7'), location_id: 'l1', responsible_id: 'e1', received_on: '2026-11-01' }],
    })
    answerApi(doc)
    await openDraft()
    await act(async () => undefined)
    expect(screen.queryByTestId('negative-balance-warning')).not.toBeInTheDocument()
    expect(calls(RULES)).toHaveLength(0)
    expect(calls(BALANCES)).toHaveLength(0)
  })
})

describe('REQ-838 criterion 3: refused, no StockRead and failed reads preserve the old form', () => {
  it('refused tenant: no warning and no balance read', async () => {
    const doc = issue('7')
    answerApi(doc, { rule: 'refused' })
    await openDraft()
    await waitFor(() => expect(calls(RULES)).toHaveLength(1))
    await act(async () => undefined)
    expect(screen.queryByTestId('negative-balance-warning')).not.toBeInTheDocument()
    expect(calls(BALANCES)).toHaveLength(0)
  })

  it('without StockRead neither the rule nor a balance is requested', async () => {
    const doc = issue('7')
    answerApi(doc)
    // The routed screen itself requires StockRead; mount its form directly to isolate the additional reads of REQ-838.
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <AccessStateProvider state={postOnly}>
          <StockIntlProvider>
            <DocumentForm doc={doc as unknown as StockDocument} title="Edit draft" onDone={vi.fn()} onCancel={vi.fn()} />
          </StockIntlProvider>
        </AccessStateProvider>
      </QueryClientProvider>,
    )
    await screen.findByTestId('document-form')
    await act(async () => undefined)
    expect(screen.queryByTestId('negative-balance-warning')).not.toBeInTheDocument()
    expect(calls(RULES)).toHaveLength(0)
    expect(calls(BALANCES)).toHaveLength(0)
  })

  it('a failed balance read shows no warning and leaves Save enabled', async () => {
    const doc = issue('7')
    answerApi(doc, { balanceError: true })
    await openDraft()
    await waitFor(() => expect(calls(BALANCES)).toHaveLength(1))
    await act(async () => undefined)
    expect(screen.queryByTestId('negative-balance-warning')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: stockMessages.en['stock.doc.save'] })).toBeEnabled()
  })
})

describe('REQ-838 criterion 4: Qoimeks message texts', () => {
  it('en, ru and kk carry the required text byte for byte', () => {
    expect(stockMessages.en['stock.doc.negativeBalance']).toBe('The balance will become negative')
    expect(stockMessages.ru['stock.doc.negativeBalance']).toBe('Остаток станет отрицательным')
    expect(stockMessages.kk['stock.doc.negativeBalance']).toBe('Қалдық теріс болады')
  })
})
